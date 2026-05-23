#!/usr/bin/env bash
set -euo pipefail

SDK_VERSION="0.6.0-systemd-agent"
DEFAULT_SERVER_URL="${ROC_SERVER_URL:-http://172.16.18.187:8090}"
DEFAULT_REPO_URL="${ROC_SDK_REPO_URL:-https://github.com/robocoin-service/roc-robot-sdk.git}"
INSTALL_DIR="${ROC_SDK_INSTALL_DIR:-$HOME/roc-robot-sdk}"
SDK_HOME="${ROC_SDK_HOME:-$HOME/.roc-robot-sdk}"
SERVICE_NAME="${ROC_SDK_SERVICE_NAME:-roc-robot-agent}"
RUN_SERVICE_AS_ROOT=0

usage() {
  cat >&2 <<EOF
ROC Robot SDK installer

Usage:
  bash install.sh <sdkBindingToken>

Example:
  bash install.sh abc123

Environment:
  ROC_SDK_REPO_URL       Git repository URL. Default: $DEFAULT_REPO_URL
  ROC_SDK_INSTALL_DIR    Install directory. Default: $INSTALL_DIR
  ROC_SDK_HOME           SDK runtime directory. Default: $SDK_HOME
  ROC_SKIP_DEP_INSTALL   Set to 1 to skip dependency installation.
EOF
}

log() {
  printf '[ROC SDK INSTALL] %s\n' "$1"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

install_dependencies_if_needed() {
  local missing=""
  for cmd in git curl python3 openssl sha256sum base64 lscpu xxd tpm2_getcap tpm2_createprimary tpm2_create tpm2_load tpm2_readpublic tpm2_sign tpm2_evictcontrol tpm2_createek tpm2_getrandom; do
    if ! require_cmd "$cmd"; then
      missing="$missing $cmd"
    fi
  done

  if [ -z "$missing" ]; then
    return 0
  fi

  log "Missing commands:$missing"
  if [ "${ROC_SKIP_DEP_INSTALL:-0}" = "1" ]; then
    log "ROC_SKIP_DEP_INSTALL=1, dependency installation skipped."
    exit 1
  fi

  if require_cmd apt-get; then
    log "Installing required packages with apt-get. Sudo password may be required."
    sudo apt-get update
    sudo apt-get install -y git curl python3 openssl coreutils util-linux xxd tpm2-tools
    return 0
  fi

  log "Cannot install dependencies automatically on this Linux distribution."
  log "Please install: git curl python3 openssl coreutils util-linux xxd tpm2-tools"
  exit 1
}

run_sdk_bind() {
  log "Binding TPM device..."
  if tpm2_getcap properties-fixed >/dev/null 2>&1; then
    RUN_SERVICE_AS_ROOT=0
    "$INSTALL_DIR/roc-robot-tpm-sdk.sh" bind "$SDK_BINDING_TOKEN" "$SERVER_URL"
    return 0
  fi

  if require_cmd sudo; then
    log "Current user cannot access TPM directly. Running SDK binding with sudo."
    log "Sudo password may be required. SDK files remain in: $INSTALL_DIR"
    RUN_SERVICE_AS_ROOT=1
    sudo env ROC_SDK_HOME="$SDK_HOME" "$INSTALL_DIR/roc-robot-tpm-sdk.sh" bind "$SDK_BINDING_TOKEN" "$SERVER_URL"
    return 0
  fi

  log "Cannot access TPM device with current user, and sudo is not available."
  log "Please add the user to TPM/tss group or run the SDK as root."
  exit 1
}

read_robot_id() {
  local robot_id_file="$SDK_HOME/robot-id"
  if [ -f "$robot_id_file" ]; then
    tr -d '[:space:]' < "$robot_id_file"
    return 0
  fi

  python3 -c 'import json, pathlib
p = pathlib.Path("'"$SDK_HOME"'") / "output" / "server-response.json"
try:
    data = json.loads(p.read_text())
    print(data.get("data", {}).get("robotId", ""))
except Exception:
    print("")
'
}

install_systemd_service() {
  local robot_id="$1"
  local current_user
  local service_user
  current_user="$(id -un)"
  service_user="$current_user"
  if [ "$RUN_SERVICE_AS_ROOT" = "1" ]; then
    service_user="root"
  fi
  if [ -z "$robot_id" ]; then
    log "Cannot create service because robotId was not returned by server."
    log "Please check: $SDK_HOME/output/server-response.json"
    exit 1
  fi

  if ! require_cmd systemctl || [ ! -d /run/systemd/system ]; then
    log "systemd is not available. Start Agent manually:"
    log "cd $INSTALL_DIR && ./roc-robot-tpm-sdk.sh agent $robot_id $SERVER_URL"
    return 0
  fi

  if ! require_cmd sudo; then
    log "sudo is required to install systemd service."
    log "Start Agent manually instead:"
    log "cd $INSTALL_DIR && ./roc-robot-tpm-sdk.sh agent $robot_id $SERVER_URL"
    return 0
  fi

  log "Installing systemd service: $SERVICE_NAME.service"
  sudo tee "/etc/systemd/system/$SERVICE_NAME.service" >/dev/null <<SERVICE
[Unit]
Description=RoboCoin DeRAS SDK Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$service_user
WorkingDirectory=$INSTALL_DIR
Environment=ROC_SDK_HOME=$SDK_HOME
Environment=ROC_HEARTBEAT_INTERVAL_SECONDS=${ROC_HEARTBEAT_INTERVAL_SECONDS:-30}
Environment=ROC_AGENT_INTERVAL_SECONDS=${ROC_AGENT_INTERVAL_SECONDS:-3}
ExecStart=$INSTALL_DIR/roc-robot-tpm-sdk.sh service $robot_id $SERVER_URL
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"
  sudo systemctl restart "$SERVICE_NAME"
  log "Service started: $SERVICE_NAME"
  log "Check status: sudo systemctl status $SERVICE_NAME"
  log "View logs: sudo journalctl -u $SERVICE_NAME -f"
}

SDK_BINDING_TOKEN="${1:-}"
SERVER_URL="$DEFAULT_SERVER_URL"

if [ -z "$SDK_BINDING_TOKEN" ] || [ "$SDK_BINDING_TOKEN" = "-h" ] || [ "$SDK_BINDING_TOKEN" = "--help" ]; then
  usage
  exit 1
fi

log "Version: $SDK_VERSION"
log "Server: $SERVER_URL"
log "Install directory: $INSTALL_DIR"
log "SDK home: $SDK_HOME"

install_dependencies_if_needed

if [ -d "$INSTALL_DIR/.git" ]; then
  log "SDK directory exists. Pulling latest version..."
  git -C "$INSTALL_DIR" pull --ff-only
else
  log "Cloning SDK repository..."
  rm -rf "$INSTALL_DIR"
  git clone "$DEFAULT_REPO_URL" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/roc-robot-tpm-sdk.sh"

mkdir -p "$SDK_HOME"
run_sdk_bind
ROBOT_ID="$(read_robot_id)"
install_systemd_service "$ROBOT_ID"
log "Install complete. Return to the web page and refresh the robot list."
