#!/usr/bin/env bash
set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_URL="${1:-${ROC_SERVER_URL:-http://127.0.0.1:8090}}"
BRIDGE_SERVICE_NAME="${ROC_GO2_BRIDGE_SERVICE_NAME:-go2-bridge}"

log(){ printf '[ROC GO2 ADAPTER] %s\n' "$1"; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }

detect_network_interface() {
  local iface="${ROC_GO2_NETWORK_INTERFACE:-}"
  if [ -z "$iface" ] && has_cmd ip; then
    iface="$(ip route get 192.168.123.161 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')"
  fi
  printf '%s\n' "${iface:-eth0}"
}

find_unitree_sdk_dir() {
  local candidate
  for candidate in "${ROC_UNITREE_SDK_DIR:-}" "$HOME/Downloads/sdk/unitree_sdk2" "$HOME/unitree_sdk2" /opt/unitree_sdk2; do
    [ -n "$candidate" ] && [ -f "$candidate/include/unitree/robot/go2/sport/sport_client.hpp" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

sdk_dir="$(find_unitree_sdk_dir || true)"
[ -n "$sdk_dir" ] || { log "Unitree SDK2 not found. Go2 adapter was not activated."; exit 1; }
has_cmd cmake && has_cmd g++ || { log "cmake and g++ are required for the Go2 adapter."; exit 1; }

log "Building Go2 adapter with Unitree SDK2: $sdk_dir"
cmake -S "$ADAPTER_DIR/go2_helper" -B "$ADAPTER_DIR/go2_helper/build" -DUNITREE_SDK_DIR="$sdk_dir"
cmake --build "$ADAPTER_DIR/go2_helper/build" --parallel 2
chmod +x "$ADAPTER_DIR/go2_bridge.py"

if has_cmd systemctl && [ -d /run/systemd/system ] && [ -f "/etc/systemd/system/${BRIDGE_SERVICE_NAME}.service" ] && has_cmd sudo; then
  iface="$(detect_network_interface)"
  log "Updating existing $BRIDGE_SERVICE_NAME service for interface $iface"
  sudo sed -i -E "s#--server[[:space:]]+[^[:space:]]+#--server ${SERVER_URL}#g" "/etc/systemd/system/${BRIDGE_SERVICE_NAME}.service" || true
  sudo sed -i -E "s/--network[[:space:]]+[^[:space:]]+/--network ${iface}/g" "/etc/systemd/system/${BRIDGE_SERVICE_NAME}.service" || true
  sudo systemctl daemon-reload
  sudo systemctl restart "$BRIDGE_SERVICE_NAME"
fi

log "Go2 adapter ready. It is an optional device integration, not part of SDK Core."
