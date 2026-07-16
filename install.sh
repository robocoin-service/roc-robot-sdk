#!/usr/bin/env bash
set -euo pipefail

SDK_VERSION="0.16.0-continuous-patrol"
DEFAULT_SERVER_URL="${ROC_SERVER_URL:-http://172.16.18.187:8090}"
DEFAULT_REPO_URL="${ROC_SDK_REPO_URL:-https://github.com/robocoin-service/roc-robot-sdk.git}"
INSTALL_DIR="${ROC_SDK_INSTALL_DIR:-$HOME/roc-robot-sdk}"
SDK_HOME="${ROC_SDK_HOME:-$HOME/.roc-robot-sdk}"
SERVICE_NAME="${ROC_SDK_SERVICE_NAME:-roc-robot-agent}"
DEVICE_PROFILE="${ROC_DEVICE_PROFILE:-auto}"
BRIDGE_SERVICE_NAME="${ROC_GO2_BRIDGE_SERVICE_NAME:-go2-bridge}"
RUN_SERVICE_AS_ROOT=0
SOFTWARE_IDENTITY_ENV="${ROC_ALLOW_SOFTWARE_IDENTITY:-}"

usage() {
  cat >&2 <<EOF
ROC Robot SDK installer

Usage:
  bash install.sh <sdkBindingToken> [serverUrl]

Example:
  bash install.sh abc123

Environment:
  ROC_SDK_REPO_URL       Git repository URL. Default: $DEFAULT_REPO_URL
  ROC_SDK_INSTALL_DIR    Install directory. Default: $INSTALL_DIR
  ROC_SDK_HOME           SDK runtime directory. Default: $SDK_HOME
  ROC_SKIP_DEP_INSTALL   Set to 1 to skip dependency installation.
  ROC_DEVICE_PROFILE     auto | go2 | industrial. Default: auto.
  ROC_ALLOW_SOFTWARE_IDENTITY
                         Set to 1 to allow software RSA fallback explicitly.
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

sudo_cmd() {
  if [ "$(id -u)" = "0" ]; then
    "$@"
  else
    sudo "$@"
  fi
}

detect_go2_or_orin() {
  case "$DEVICE_PROFILE" in
    go2|GO2|unitree|UNITREE)
      return 0
      ;;
    industrial|INDUSTRIAL|ipc|IPC)
      return 1
      ;;
  esac

  if [ -r /proc/device-tree/model ] && tr -d '\000' </proc/device-tree/model | grep -Eiq 'unitree|go2|orin|jetson|nvidia'; then
    return 0
  fi
  if [ -d "$HOME/unitree_sdk2" ] || [ -d "$HOME/Downloads/sdk/unitree_sdk2" ] || [ -d /opt/unitree_sdk2 ]; then
    return 0
  fi
  if require_cmd ip && ip -br addr 2>/dev/null | grep -q '192\.168\.123\.'; then
    return 0
  fi
  if [ -n "$(find /sys/devices/platform -maxdepth 3 \( -name ecid -o -name public_key \) 2>/dev/null | head -n 1)" ]; then
    return 0
  fi
  return 1
}

configure_identity_policy() {
  if [ -n "$SOFTWARE_IDENTITY_ENV" ]; then
    log "Software identity override: ROC_ALLOW_SOFTWARE_IDENTITY=$SOFTWARE_IDENTITY_ENV"
    return 0
  fi

  if detect_go2_or_orin; then
    SOFTWARE_IDENTITY_ENV=1
    log "Detected Go2/Orin-like device. Software RSA identity fallback is enabled."
  else
    SOFTWARE_IDENTITY_ENV=0
    log "Industrial profile detected. TPM identity is required unless ROC_ALLOW_SOFTWARE_IDENTITY=1 is set."
  fi
}

parse_server_host_port() {
  python3 - "$SERVER_URL" <<'PY'
import sys
from urllib.parse import urlparse

u = urlparse(sys.argv[1])
scheme = u.scheme or "http"
host = u.hostname or ""
port = u.port or (443 if scheme == "https" else 80)
print(f"{host} {port}")
PY
}

check_system_time() {
  local year
  year="$(date +%Y 2>/dev/null || echo 1970)"
  if [ "$year" -lt 2024 ]; then
    log "System time looks wrong: $(date 2>/dev/null || true)"
    log "This often means the robot booted without RTC/NTP. Heartbeat logs and signature audit may be confusing."
    if [ "${ROC_STRICT_TIME_CHECK:-0}" = "1" ]; then
      log "ROC_STRICT_TIME_CHECK=1, stopping install until system time is fixed."
      exit 1
    fi
  fi
}

wait_for_server_available() {
  local host port waited timeout
  read -r host port <<EOF_SERVER
$(parse_server_host_port)
EOF_SERVER
  timeout="${ROC_SERVER_WAIT_SECONDS:-60}"
  waited=0

  if [ -z "$host" ]; then
    log "Cannot parse server URL: $SERVER_URL"
    exit 1
  fi

  log "Checking server connectivity: $host:$port"
  while [ "$waited" -le "$timeout" ]; do
    if python3 - "$host" "$port" <<'PY'
import socket, sys
host = sys.argv[1]
port = int(sys.argv[2])
try:
    with socket.create_connection((host, port), timeout=3):
        pass
except Exception:
    sys.exit(1)
PY
    then
      log "Server TCP connectivity OK: $host:$port"
      curl -fsS --connect-timeout 3 --max-time 5 "${SERVER_URL%/}/" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
    log "Waiting for server ${host}:${port}... (${waited}/${timeout}s)"
  done

  log "Server is unreachable: $SERVER_URL"
  log "Check robot network, PC IP, backend port, firewall, or pass the correct serverUrl as the second argument."
  exit 1
}

wait_for_apt_locks() {
  if ! require_cmd fuser; then
    return 0
  fi
  local waited=0
  local max_wait="${ROC_APT_LOCK_WAIT_SECONDS:-300}"
  local locks="/var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock"
  while fuser $locks >/dev/null 2>&1; do
    if [ "$waited" -ge "$max_wait" ]; then
      log "APT/dpkg is still locked after ${max_wait}s."
      log "Another update process may be running. Please wait or reboot the robot, then rerun the same one-line command."
      exit 1
    fi
    log "APT/dpkg is busy. Waiting 10s... (${waited}/${max_wait}s)"
    sleep 10
    waited=$((waited + 10))
  done
}

repair_dpkg_if_needed() {
  if ! require_cmd dpkg; then
    return 0
  fi
  log "Checking dpkg package state..."
  wait_for_apt_locks
  if ! dpkg --audit >/tmp/roc-sdk-dpkg-audit.$$ 2>&1; then
    true
  fi
  if [ -s /tmp/roc-sdk-dpkg-audit.$$ ]; then
    log "dpkg has unfinished configuration. Running: sudo dpkg --configure -a"
    sudo_cmd dpkg --configure -a
  fi
  rm -f /tmp/roc-sdk-dpkg-audit.$$
}

apt_get_resilient() {
  local attempt=1
  local max_attempts=3
  while [ "$attempt" -le "$max_attempts" ]; do
    wait_for_apt_locks
    repair_dpkg_if_needed
    if sudo_cmd apt-get "$@"; then
      return 0
    fi
    log "apt-get $* failed on attempt ${attempt}/${max_attempts}."
    repair_dpkg_if_needed
    attempt=$((attempt + 1))
    sleep 5
  done
  log "Dependency installation failed after retries."
  log "You can try rebooting the robot and running the same one-line command again."
  exit 1
}

install_dependencies_if_needed() {
  local missing=""
  local missing_tpm=""
  for cmd in git curl python3 openssl sha256sum base64 lscpu; do
    if ! require_cmd "$cmd"; then
      missing="$missing $cmd"
    fi
  done
  for cmd in tpm2_getcap tpm2_createprimary tpm2_create tpm2_load tpm2_readpublic tpm2_sign tpm2_evictcontrol; do
    if ! require_cmd "$cmd"; then
      missing_tpm="$missing_tpm $cmd"
    fi
  done

  log "Missing base commands:${missing:- none}"
  log "Missing TPM commands:${missing_tpm:- none}"
  if [ -z "$missing" ] && [ -z "$missing_tpm" ]; then
    return 0
  fi

  if [ "${ROC_SKIP_DEP_INSTALL:-0}" = "1" ]; then
    log "ROC_SKIP_DEP_INSTALL=1, dependency installation skipped."
    if [ -n "$missing" ]; then
      exit 1
    fi
    if [ -n "$missing_tpm" ] && [ "$SOFTWARE_IDENTITY_ENV" != "1" ]; then
      exit 1
    fi
    return 0
  fi

  if require_cmd apt-get; then
    if [ -n "$missing" ]; then
      log "Installing required base packages with apt-get. Sudo password may be required."
      apt_get_resilient update
      apt_get_resilient install -y git curl python3 openssl ca-certificates coreutils util-linux iproute2 procps psmisc
    fi
    if [ -n "$missing_tpm" ]; then
      if [ "$SOFTWARE_IDENTITY_ENV" = "1" ] && [ "${ROC_INSTALL_TPM_TOOLS:-0}" != "1" ]; then
        log "TPM commands are optional on detected Go2/software identity devices. Set ROC_INSTALL_TPM_TOOLS=1 to install them anyway."
      else
        log "Installing TPM tools for industrial identity."
        [ -z "$missing" ] && apt_get_resilient update
        apt_get_resilient install -y tpm2-tools
      fi
    fi
    return 0
  fi

  log "Cannot install dependencies automatically on this Linux distribution."
  log "Please install: git curl python3 openssl coreutils util-linux"
  exit 1
}

run_sdk_bind() {
  log "Binding adaptive device identity..."
  RUN_SERVICE_AS_ROOT=0
  ROC_ALLOW_SOFTWARE_IDENTITY="$SOFTWARE_IDENTITY_ENV" "$INSTALL_DIR/roc-robot-tpm-sdk.sh" bind "$SDK_BINDING_TOKEN" "$SERVER_URL"
}

stop_existing_agent() {
  log "Stopping existing SDK agent/service if present..."
  if require_cmd systemctl && [ -d /run/systemd/system ] && require_cmd sudo; then
    sudo systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    sudo systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  if require_cmd pkill; then
    pkill -f 'roc-robot-tpm-sdk\.sh service' >/dev/null 2>&1 || true
    pkill -f 'roc-robot-tpm-sdk\.sh agent' >/dev/null 2>&1 || true
  fi
}

detect_go2_network_interface() {
  local iface="${ROC_GO2_NETWORK_INTERFACE:-}"
  if [ -z "$iface" ] && require_cmd ip; then
    iface="$(ip route get 192.168.123.161 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
  fi
  if [ -z "$iface" ] && require_cmd ip; then
    iface="$(ip -br addr 2>/dev/null | awk '$3 ~ /^192\.168\.123\./ {print $1; exit}')"
  fi
  if [ -z "$iface" ] && require_cmd ip; then
    iface="$(ip -br link 2>/dev/null | awk '$1 == "wlan0" && $2 == "UP" {print $1; exit}')"
  fi
  if [ -z "$iface" ] && require_cmd ip; then
    iface="$(ip route 2>/dev/null | awk '$1 == "default" {print $5; exit}')"
  fi
  printf '%s\n' "${iface:-eth0}"
}

find_unitree_sdk_dir() {
  local candidate
  for candidate in \
    "${ROC_UNITREE_SDK_DIR:-}" \
    "$HOME/Downloads/sdk/unitree_sdk2" \
    "$HOME/unitree_sdk2" \
    /opt/unitree_sdk2; do
    if [ -n "$candidate" ] && [ -f "$candidate/include/unitree/robot/go2/sport/sport_client.hpp" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

build_go2_action_helper_if_possible() {
  if ! detect_go2_or_orin || [ ! -f "$INSTALL_DIR/go2_helper/CMakeLists.txt" ]; then
    return 0
  fi

  local sdk_dir
  sdk_dir="$(find_unitree_sdk_dir || true)"
  if [ -z "$sdk_dir" ]; then
    log "Warning: Unitree SDK2 was not found; Go2 physical action helper was not built."
    return 0
  fi

  if ! require_cmd cmake || ! require_cmd g++; then
    if require_cmd apt-get && [ "${ROC_SKIP_DEP_INSTALL:-0}" != "1" ]; then
      log "Installing Go2 action helper build dependencies."
      apt_get_resilient update
      apt_get_resilient install -y cmake g++ make
    else
      log "Warning: cmake/g++ missing; Go2 physical action helper was not built."
      return 0
    fi
  fi

  log "Building verified Go2 C++ action helper with SDK: $sdk_dir"
  cmake -S "$INSTALL_DIR/go2_helper" -B "$INSTALL_DIR/go2_helper/build" -DUNITREE_SDK_DIR="$sdk_dir"
  cmake --build "$INSTALL_DIR/go2_helper/build" --parallel 2
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

backup_go2_bridge_if_present() {
  mkdir -p "$SDK_HOME"
  if [ -f "$INSTALL_DIR/go2_bridge.py" ]; then
    cp "$INSTALL_DIR/go2_bridge.py" "$SDK_HOME/go2_bridge.py.pre-install-backup"
    log "Existing Go2 bridge backed up before SDK refresh."
  fi
}

restore_go2_bridge_if_needed() {
  if [ -f "$INSTALL_DIR/go2_bridge.py" ]; then
    chmod +x "$INSTALL_DIR/go2_bridge.py" || true
    log "Using the current Go2 bridge from the SDK repository."
    return 0
  fi
  if [ -f "$SDK_HOME/go2_bridge.py.pre-install-backup" ]; then
    cp "$SDK_HOME/go2_bridge.py.pre-install-backup" "$INSTALL_DIR/go2_bridge.py"
    chmod +x "$INSTALL_DIR/go2_bridge.py" || true
    log "Go2 bridge restored from backup because the repository copy is missing."
    return 0
  fi
  return 1
}

repair_go2_bridge_service_if_present() {
  if ! require_cmd systemctl || [ ! -d /run/systemd/system ]; then
    return 0
  fi
  if [ ! -f "/etc/systemd/system/${BRIDGE_SERVICE_NAME}.service" ] && ! systemctl list-unit-files "${BRIDGE_SERVICE_NAME}.service" >/dev/null 2>&1; then
    return 0
  fi
  log "Detected existing Go2 bridge service; ensuring bridge file and service health."
  local go2_network_interface
  go2_network_interface="$(detect_go2_network_interface)"
  log "Go2 bridge network interface: $go2_network_interface"
  if require_cmd sudo && [ -f "/etc/systemd/system/${BRIDGE_SERVICE_NAME}.service" ]; then
    sudo sed -i -E "s/--network[[:space:]]+[^[:space:]]+/--network ${go2_network_interface}/g" "/etc/systemd/system/${BRIDGE_SERVICE_NAME}.service" || true
  fi
  if ! restore_go2_bridge_if_needed; then
    log "Warning: ${BRIDGE_SERVICE_NAME}.service exists but go2_bridge.py is missing. Install the Go2 integration package to restore physical action support."
    return 0
  fi
  if require_cmd sudo; then
    sudo systemctl daemon-reload || true
    sudo systemctl restart "$BRIDGE_SERVICE_NAME" || true
    for i in 1 2 3 4 5; do
      if curl -fsS --connect-timeout 2 http://127.0.0.1:8080/api/v1/status >/dev/null 2>&1; then
        log "Go2 bridge health check OK."
        return 0
      fi
      sleep 2
    done
    log "Warning: Go2 bridge health check failed after restart. Recent logs:"
    sudo journalctl -u "$BRIDGE_SERVICE_NAME" -n 80 --no-pager || true
  fi
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
    log "systemd is not available. Starting Agent with nohup."
    printf '%s\n' "$robot_id" > "$SDK_HOME/robot-id"
    printf '%s\n' "$SERVER_URL" > "$SDK_HOME/server-url"
    rm -f "$SDK_HOME/output/heartbeat-server-response.json"
    nohup env ROC_SDK_HOME="$SDK_HOME" ROC_SERVER_URL="$SERVER_URL" ROC_ALLOW_SOFTWARE_IDENTITY="$SOFTWARE_IDENTITY_ENV" "$INSTALL_DIR/roc-robot-tpm-sdk.sh" agent "$robot_id" "$SERVER_URL" > "$SDK_HOME/agent.log" 2>&1 &
    log "Agent started in background. Log: $SDK_HOME/agent.log"
    return 0
  fi

  if ! require_cmd sudo; then
    log "sudo is not available. Starting Agent with nohup."
    printf '%s\n' "$robot_id" > "$SDK_HOME/robot-id"
    printf '%s\n' "$SERVER_URL" > "$SDK_HOME/server-url"
    rm -f "$SDK_HOME/output/heartbeat-server-response.json"
    nohup env ROC_SDK_HOME="$SDK_HOME" ROC_SERVER_URL="$SERVER_URL" ROC_ALLOW_SOFTWARE_IDENTITY="$SOFTWARE_IDENTITY_ENV" "$INSTALL_DIR/roc-robot-tpm-sdk.sh" agent "$robot_id" "$SERVER_URL" > "$SDK_HOME/agent.log" 2>&1 &
    log "Agent started in background. Log: $SDK_HOME/agent.log"
    return 0
  fi

  printf '%s\n' "$robot_id" > "$SDK_HOME/robot-id"
  printf '%s\n' "$SERVER_URL" > "$SDK_HOME/server-url"
  rm -f "$SDK_HOME/output/heartbeat-server-response.json"

  log "Installing systemd service: $SERVICE_NAME.service"
  sudo tee "/etc/systemd/system/$SERVICE_NAME.service" >/dev/null <<SERVICE
[Unit]
Description=RoboCoin DeRAS SDK Agent
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=12

[Service]
Type=simple
User=$service_user
WorkingDirectory=$INSTALL_DIR
Environment=ROC_SDK_HOME=$SDK_HOME
Environment=ROC_SERVER_URL=$SERVER_URL
Environment=ROC_ALLOW_SOFTWARE_IDENTITY=$SOFTWARE_IDENTITY_ENV
Environment=ROC_HEARTBEAT_INTERVAL_SECONDS=${ROC_HEARTBEAT_INTERVAL_SECONDS:-30}
Environment=ROC_AGENT_INTERVAL_SECONDS=${ROC_AGENT_INTERVAL_SECONDS:-3}
ExecStart=$INSTALL_DIR/roc-robot-tpm-sdk.sh service $robot_id $SERVER_URL
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=15
StandardOutput=journal
StandardError=journal

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

run_doctor_summary() {
  log "Running SDK doctor..."
  if [ "$RUN_SERVICE_AS_ROOT" = "1" ] && require_cmd sudo; then
    sudo env ROC_SDK_HOME="$SDK_HOME" "$INSTALL_DIR/roc-robot-tpm-sdk.sh" doctor "$SERVER_URL" || true
    return 0
  fi
  "$INSTALL_DIR/roc-robot-tpm-sdk.sh" doctor "$SERVER_URL" || true
}

wait_for_heartbeat_verified() {
  local robot_id="$1"
  local timeout="${ROC_INSTALL_HEARTBEAT_WAIT_SECONDS:-90}"
  local waited=0
  local response_file="$SDK_HOME/output/heartbeat-server-response.json"

  log "Waiting for verified heartbeat robotId=$robot_id (${timeout}s timeout)..."
  while [ "$waited" -le "$timeout" ]; do
    if [ -f "$response_file" ] &&
      grep -q '"code":200' "$response_file" 2>/dev/null &&
      grep -Eq "\"robotId\"[[:space:]]*:[[:space:]]*$robot_id" "$response_file" 2>/dev/null; then
      log "Heartbeat verified by server."
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done

  log "Heartbeat was not verified within ${timeout}s."
  log "Last heartbeat response:"
  if [ -f "$response_file" ]; then
    sed -n '1,5p' "$response_file"
  else
    log "No heartbeat response file found at $response_file"
  fi
  if require_cmd systemctl && [ -d /run/systemd/system ] && require_cmd sudo; then
    sudo systemctl --no-pager --full status "$SERVICE_NAME" || true
  fi
  exit 1
}

SDK_BINDING_TOKEN="${1:-}"
SERVER_URL="${2:-$DEFAULT_SERVER_URL}"

if [ -z "$SDK_BINDING_TOKEN" ] || [ "$SDK_BINDING_TOKEN" = "-h" ] || [ "$SDK_BINDING_TOKEN" = "--help" ]; then
  usage
  exit 1
fi

log "Version: $SDK_VERSION"
log "Server: $SERVER_URL"
log "Install directory: $INSTALL_DIR"
log "SDK home: $SDK_HOME"
log "Device profile: $DEVICE_PROFILE"

configure_identity_policy
install_dependencies_if_needed
check_system_time
wait_for_server_available
stop_existing_agent
mkdir -p "$SDK_HOME"
backup_go2_bridge_if_present

if [ -d "$INSTALL_DIR/.git" ]; then
  log "SDK directory exists. Pulling latest version..."
  if ! git -C "$INSTALL_DIR" pull --ff-only; then
    BACKUP_DIR="${INSTALL_DIR}.backup.$(date +%Y%m%d%H%M%S)"
    log "Existing SDK directory has local changes or pull failed. Backing it up to: $BACKUP_DIR"
    mv "$INSTALL_DIR" "$BACKUP_DIR"
    log "Cloning SDK repository again..."
    git clone "$DEFAULT_REPO_URL" "$INSTALL_DIR"
  fi
else
  log "Cloning SDK repository..."
  rm -rf "$INSTALL_DIR"
  git clone "$DEFAULT_REPO_URL" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/roc-robot-tpm-sdk.sh"
restore_go2_bridge_if_needed || true
build_go2_action_helper_if_possible

mkdir -p "$SDK_HOME"
run_sdk_bind
ROBOT_ID="$(read_robot_id)"
install_systemd_service "$ROBOT_ID"
repair_go2_bridge_service_if_present
run_doctor_summary
wait_for_heartbeat_verified "$ROBOT_ID"
log "Install complete. Return to the web page and refresh the robot list."
