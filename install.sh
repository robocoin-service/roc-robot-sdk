#!/usr/bin/env bash
set -euo pipefail

SDK_VERSION="0.4.0-github-bind-agent"
DEFAULT_SERVER_URL="${ROC_SERVER_URL:-http://172.16.18.187:8090}"
DEFAULT_REPO_URL="${ROC_SDK_REPO_URL:-https://github.com/robocoin-service/roc-robot-sdk.git}"
INSTALL_DIR="${ROC_SDK_INSTALL_DIR:-$HOME/roc-robot-sdk}"

usage() {
  cat >&2 <<EOF
ROC Robot SDK installer

Usage:
  bash install.sh <sdkBindingToken>

Example:
  ROC_SERVER_URL=http://172.16.18.187:8090 bash install.sh abc123

Environment:
  ROC_SDK_REPO_URL       Git repository URL. Default: $DEFAULT_REPO_URL
  ROC_SDK_INSTALL_DIR    Install directory. Default: $INSTALL_DIR
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
  for cmd in git curl python3 openssl sha256sum base64 lscpu tpm2_getcap tpm2_createprimary tpm2_create tpm2_load tpm2_readpublic tpm2_sign tpm2_evictcontrol tpm2_createek; do
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
    sudo apt-get install -y git curl python3 openssl coreutils util-linux tpm2-tools
    return 0
  fi

  log "Cannot install dependencies automatically on this Linux distribution."
  log "Please install: git curl python3 openssl coreutils util-linux tpm2-tools"
  exit 1
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

log "Binding TPM device and starting DeRAS Agent..."
if tpm2_getcap properties-fixed >/dev/null 2>&1; then
  exec "$INSTALL_DIR/roc-robot-tpm-sdk.sh" bind "$SDK_BINDING_TOKEN" "$SERVER_URL"
fi

if require_cmd sudo; then
  log "Current user cannot access TPM directly. Running SDK with sudo."
  log "Sudo password may be required. SDK files remain in: $INSTALL_DIR"
  exec sudo env ROC_SDK_HOME="$HOME/.roc-robot-sdk" "$INSTALL_DIR/roc-robot-tpm-sdk.sh" bind "$SDK_BINDING_TOKEN" "$SERVER_URL"
fi

log "Cannot access TPM device with current user, and sudo is not available."
log "Please add the user to TPM/tss group or run the SDK as root."
exit 1
