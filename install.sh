#!/usr/bin/env bash
set -euo pipefail

SDK_VERSION="1.1.0-adapter-runtime"
DEFAULT_SERVER_URL="${ROC_SERVER_URL:-http://127.0.0.1:8090}"
DEFAULT_REPO_URL="${ROC_SDK_REPO_URL:-https://github.com/robocoin-service/roc-robot-sdk.git}"
INSTALL_DIR="${ROC_SDK_INSTALL_DIR:-$HOME/roc-robot-sdk}"
SDK_HOME="${ROC_SDK_HOME:-$HOME/.roc-robot-sdk}"
SERVICE_NAME="${ROC_SDK_SERVICE_NAME:-roc-robot-agent}"
DEVICE_PROFILE="${ROC_DEVICE_PROFILE:-generic}"
ROC_ADAPTERS="${ROC_ADAPTERS:-none}"
TEST_MODE="${ROC_SDK_TEST_MODE:-0}"
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
  ROC_DEVICE_PROFILE     generic | industrial. Default: generic.
  ROC_ADAPTERS           Comma-separated manifest IDs, for example: go2 or mock-wheel.
                         Default: none. Adapters are discovered from adapters/*/adapter.json.
  ROC_SDK_TEST_MODE      Set to 1 for an offline Core installation smoke test.
  ROC_SDK_SOURCE_DIR     Test mode only: copy this working tree instead of cloning.
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

configure_identity_policy() {
  if [ -n "$SOFTWARE_IDENTITY_ENV" ]; then
    log "Software identity override: ROC_ALLOW_SOFTWARE_IDENTITY=$SOFTWARE_IDENTITY_ENV"
    return 0
  fi

  SOFTWARE_IDENTITY_ENV=0
  log "Generic/industrial Core profile: TPM identity is required."
  log "Set ROC_ALLOW_SOFTWARE_IDENTITY=1 to opt in to software identity."
}

install_requested_adapters() {
  if [ "$ROC_ADAPTERS" = "none" ] || [ -z "$ROC_ADAPTERS" ]; then
    log "No hardware adapter selected. Installing generic SDK Core only."
    return 0
  fi

  local adapter adapter_dir install_script
  IFS=',' read -r -a requested_adapters <<< "$ROC_ADAPTERS"
  for adapter in "${requested_adapters[@]}"; do
    adapter="${adapter//[[:space:]]/}"
    [ -n "$adapter" ] || continue
    if [ "$adapter" = "none" ]; then
      log "Adapter 'none' cannot be combined with another adapter ID."
      exit 1
    fi
    python3 "$INSTALL_DIR/roc_adapter_runtime.py" \
      --adapter-root "$INSTALL_DIR/adapters" validate --adapter "$adapter" >/dev/null
    adapter_dir="$INSTALL_DIR/adapters/$adapter"
    install_script="$adapter_dir/install.sh"
    if [ -f "$install_script" ]; then
      chmod +x "$install_script"
      log "Installing optional adapter: $adapter"
      "$install_script" "$SERVER_URL"
    else
      log "Adapter $adapter requires no additional installation."
    fi
  done
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

validate_install_paths() {
  python3 - "$INSTALL_DIR" "$SDK_HOME" "${ROC_SDK_SOURCE_DIR:-}" <<'PY'
import pathlib
import sys


def paths_overlap(first, second):
    return first == second or first in second.parents or second in first.parents


install_dir = pathlib.Path(sys.argv[1]).expanduser().resolve()
sdk_home = pathlib.Path(sys.argv[2]).expanduser().resolve()
home_dir = pathlib.Path.home().resolve()
if install_dir in {pathlib.Path("/"), home_dir}:
    raise SystemExit(f"unsafe ROC_SDK_INSTALL_DIR: {install_dir}")
if paths_overlap(install_dir, sdk_home):
    raise SystemExit("ROC_SDK_INSTALL_DIR and ROC_SDK_HOME must not overlap")
if sys.argv[3]:
    source_dir = pathlib.Path(sys.argv[3]).expanduser().resolve()
    if paths_overlap(install_dir, source_dir):
        raise SystemExit("ROC_SDK_INSTALL_DIR and ROC_SDK_SOURCE_DIR must not overlap")
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
      log "Another update process may be running."
      log "Wait or reboot the robot, then rerun the same install command."
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
        log "TPM commands are optional because software identity is enabled."
        log "Set ROC_INSTALL_TPM_TOOLS=1 to install TPM tools anyway."
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
  log "Binding robot device identity..."
  RUN_SERVICE_AS_ROOT=0
  ROC_ALLOW_SOFTWARE_IDENTITY="$SOFTWARE_IDENTITY_ENV" \
    "$INSTALL_DIR/roc-robot-tpm-sdk.sh" \
    bind "$SDK_BINDING_TOKEN" "$SERVER_URL"
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
    log "systemd is not available. Starting Agent with nohup."
    printf '%s\n' "$robot_id" > "$SDK_HOME/robot-id"
    printf '%s\n' "$SERVER_URL" > "$SDK_HOME/server-url"
    rm -f "$SDK_HOME/output/heartbeat-server-response.json"
    nohup env \
      ROC_SDK_HOME="$SDK_HOME" \
      ROC_SERVER_URL="$SERVER_URL" \
      ROC_ALLOW_SOFTWARE_IDENTITY="$SOFTWARE_IDENTITY_ENV" \
      "$INSTALL_DIR/roc-robot-tpm-sdk.sh" \
      agent "$robot_id" "$SERVER_URL" \
      > "$SDK_HOME/agent.log" 2>&1 &
    log "Agent started in background. Log: $SDK_HOME/agent.log"
    return 0
  fi

  if ! require_cmd sudo; then
    log "sudo is not available. Starting Agent with nohup."
    printf '%s\n' "$robot_id" > "$SDK_HOME/robot-id"
    printf '%s\n' "$SERVER_URL" > "$SDK_HOME/server-url"
    rm -f "$SDK_HOME/output/heartbeat-server-response.json"
    nohup env \
      ROC_SDK_HOME="$SDK_HOME" \
      ROC_SERVER_URL="$SERVER_URL" \
      ROC_ALLOW_SOFTWARE_IDENTITY="$SOFTWARE_IDENTITY_ENV" \
      "$INSTALL_DIR/roc-robot-tpm-sdk.sh" \
      agent "$robot_id" "$SERVER_URL" \
      > "$SDK_HOME/agent.log" 2>&1 &
    log "Agent started in background. Log: $SDK_HOME/agent.log"
    return 0
  fi

  printf '%s\n' "$robot_id" > "$SDK_HOME/robot-id"
  printf '%s\n' "$SERVER_URL" > "$SDK_HOME/server-url"
  rm -f "$SDK_HOME/output/heartbeat-server-response.json"

  log "Installing systemd service: $SERVICE_NAME.service"
  sudo tee "/etc/systemd/system/$SERVICE_NAME.service" >/dev/null <<SERVICE
[Unit]
Description=ROC Robot SDK Agent
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
Environment=ROC_DEVICE_TYPE=${ROC_DEVICE_TYPE:-LINUX_ROBOT_AGENT}
Environment=ROC_NETWORK_INTERFACE=${ROC_NETWORK_INTERFACE:-}
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
log "Requested adapters: $ROC_ADAPTERS"

configure_identity_policy
install_dependencies_if_needed
validate_install_paths
check_system_time
if [ "$TEST_MODE" != "1" ]; then
  wait_for_server_available
  stop_existing_agent
else
  log "Test mode: skipping server availability check and service changes."
fi
mkdir -p "$SDK_HOME"

if [ "$TEST_MODE" = "1" ] && [ -n "${ROC_SDK_SOURCE_DIR:-}" ]; then
  if [ ! -f "$ROC_SDK_SOURCE_DIR/install.sh" ]; then
    log "ROC_SDK_SOURCE_DIR is not an SDK source tree: $ROC_SDK_SOURCE_DIR"
    exit 1
  fi
  log "Test mode: copying current SDK source from $ROC_SDK_SOURCE_DIR"
  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  cp -a "$ROC_SDK_SOURCE_DIR/." "$INSTALL_DIR/"
elif [ -d "$INSTALL_DIR/.git" ]; then
  log "SDK directory exists. Pulling latest version..."
  if ! git -C "$INSTALL_DIR" pull --ff-only; then
    BACKUP_DIR="${INSTALL_DIR}.backup.$(date +%Y%m%d%H%M%S)"
    log "Existing SDK directory has local changes or pull failed."
    log "Backing it up to: $BACKUP_DIR"
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
chmod +x "$INSTALL_DIR/roc_adapter_runtime.py"
find "$INSTALL_DIR/adapters" -type f \( -name '*.py' -o -name 'install.sh' \) \
  -exec chmod +x {} + 2>/dev/null || true

mkdir -p "$SDK_HOME"
install_requested_adapters
python3 "$INSTALL_DIR/roc_adapter_runtime.py" \
  --adapter-root "$INSTALL_DIR/adapters" activate --adapters "$ROC_ADAPTERS" \
  >/dev/null
if [ "$TEST_MODE" = "1" ]; then
  log "Test mode: Core files and optional adapter selection validated; binding and service start skipped."
  exit 0
fi
run_sdk_bind
ROBOT_ID="$(read_robot_id)"
install_systemd_service "$ROBOT_ID"
run_doctor_summary
wait_for_heartbeat_verified "$ROBOT_ID"
log "Install complete. Return to the web page and refresh the robot list."
