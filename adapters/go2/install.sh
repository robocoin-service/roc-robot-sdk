#!/usr/bin/env bash
set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_URL="${1:-${ROC_SERVER_URL:-http://127.0.0.1:8090}}"
BRIDGE_SERVICE_NAME="${ROC_GO2_BRIDGE_SERVICE_NAME:-go2-bridge}"

log() {
  printf '[ROC GO2 ADAPTER] %s\n' "$1"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

detect_network_interface() {
  local interface="${ROC_GO2_NETWORK_INTERFACE:-}"
  if [ -z "$interface" ] && has_cmd ip; then
    interface="$(
      ip route get 192.168.123.161 2>/dev/null |
        awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
    )"
  fi
  printf '%s\n' "${interface:-eth0}"
}

find_unitree_sdk_dir() {
  local candidate
  for candidate in \
    "${ROC_UNITREE_SDK_DIR:-}" \
    "$HOME/Downloads/sdk/unitree_sdk2" \
    "$HOME/unitree_sdk2" \
    /opt/unitree_sdk2; do
    if [ -n "$candidate" ] &&
      [ -f "$candidate/include/unitree/robot/go2/sport/sport_client.hpp" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

install_bridge_service() {
  local interface="$1"
  local current_user
  local python_bin
  current_user="$(id -un)"
  python_bin="$(command -v python3)"

  if has_cmd systemctl && [ -d /run/systemd/system ] && has_cmd sudo; then
    log "Installing $BRIDGE_SERVICE_NAME service for interface $interface"
    sudo tee "/etc/systemd/system/${BRIDGE_SERVICE_NAME}.service" >/dev/null <<SERVICE
[Unit]
Description=ROC Unitree Go2 Adapter Bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$current_user
WorkingDirectory=$ADAPTER_DIR
ExecStart=$python_bin $ADAPTER_DIR/go2_bridge.py --server $SERVER_URL --network $interface
Restart=always
RestartSec=3
KillSignal=SIGTERM
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
SERVICE
    sudo systemctl daemon-reload
    sudo systemctl enable "$BRIDGE_SERVICE_NAME"
    sudo systemctl restart "$BRIDGE_SERVICE_NAME"
    return
  fi

  log "systemd or sudo is unavailable; starting Bridge with nohup"
  nohup "$python_bin" "$ADAPTER_DIR/go2_bridge.py" \
    --server "$SERVER_URL" --network "$interface" \
    > "$ADAPTER_DIR/go2-bridge.log" 2>&1 &
}

sdk_dir="$(find_unitree_sdk_dir || true)"
if [ -z "$sdk_dir" ]; then
  log "Unitree SDK2 not found. Go2 Adapter was not activated."
  exit 1
fi
if ! has_cmd cmake || ! has_cmd g++; then
  log "cmake and g++ are required for the Go2 Adapter."
  exit 1
fi

log "Building Go2 Adapter with Unitree SDK2: $sdk_dir"
cmake \
  -S "$ADAPTER_DIR/go2_helper" \
  -B "$ADAPTER_DIR/go2_helper/build" \
  -DUNITREE_SDK_DIR="$sdk_dir"
cmake --build "$ADAPTER_DIR/go2_helper/build" --parallel 2
chmod +x "$ADAPTER_DIR/go2_bridge.py" "$ADAPTER_DIR/runtime_adapter.py"
install_bridge_service "$(detect_network_interface)"

log "Go2 Adapter ready. SDK Core remains device-neutral."
