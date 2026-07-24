#!/usr/bin/env bash
set -euo pipefail

SDK_VERSION="1.1.0-adapter-runtime"
DEFAULT_SERVER_URL="${ROC_SERVER_URL:-http://127.0.0.1:8090}"
MODE="${1:-}"
SDK_HOME="${ROC_SDK_HOME:-$HOME/.roc-robot-sdk}"
SERVICE_NAME="${ROC_SDK_SERVICE_NAME:-roc-robot-agent}"
WORK_DIR="$SDK_HOME/tpm"
OUTPUT_DIR="$SDK_HOME/output"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

log() {
  printf '[ROC SDK] %s\n' "$1"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

need() {
  if ! has_cmd "$1"; then
    echo "missing command: $1" >&2
    exit 1
  fi
}

jv() {
  printf '%s' "$1" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

sha() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

pubfp() {
  openssl pkey -pubin -in "$1" -outform DER | sha256sum | awk '{print $1}'
}

trim() {
  if [ -r "$1" ]; then
    tr -d '\r\n' < "$1" 2>/dev/null || true
  fi
}

cpu() {
  lscpu 2>/dev/null |
    awk -F: -v key="$1" '$1 == key { sub(/^[ \t]+/, "", $2); print $2; exit }'
}

tpm_ok() {
  local command
  for command in \
    tpm2_getcap tpm2_createprimary tpm2_create tpm2_load \
    tpm2_readpublic tpm2_sign tpm2_evictcontrol; do
    has_cmd "$command" || return 1
  done
  tpm2_getcap properties-fixed >/dev/null 2>&1
}

rand() {
  openssl rand -hex 16 2>/dev/null || date +%s%N
}

base() {
  local command
  for command in openssl python3 curl sha256sum base64 lscpu; do
    need "$command"
  done
}

read_enabled_adapters() {
  local registry="$SDK_HOME/runtime/enabled-adapters.json"
  if [ ! -f "$registry" ]; then
    printf '[]'
    return
  fi
  python3 - "$registry" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
adapters = value.get("adapters", [])
if not isinstance(adapters, list) or any(not isinstance(item, str) for item in adapters):
    raise SystemExit("invalid enabled adapter registry")
print(json.dumps(adapters, separators=(",", ":")))
PY
}

json_data_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)["data"][sys.argv[2]]
if isinstance(value, bool):
    print(str(value).lower())
else:
    print(value)
PY
}

case "$MODE" in
  bind|install)
    SDK_BINDING_TOKEN="${2:-}"
    SERVER_URL="${3:-$DEFAULT_SERVER_URL}"
    TPM_HANDLE="${4:-0x81010010}"
    ROBOT_ID=""
    ;;
  service|agent)
    ROBOT_ID="${2:-}"
    SERVER_URL="${3:-$DEFAULT_SERVER_URL}"
    TPM_HANDLE="${4:-0x81010010}"
    SDK_BINDING_TOKEN=""
    ;;
  stage)
    SERVER_URL="${2:-$DEFAULT_SERVER_URL}"
    VERIFICATION_ID="${3:-}"
    ORDER_ID="${4:-}"
    TASK_ID="${5:-}"
    ROBOT_ID="${6:-}"
    STAGE="${7:-}"
    NONCE="${8:-}"
    CHALLENGE_PAYLOAD="${9:-}"
    TPM_HANDLE="${10:-0x81010010}"
    SDK_BINDING_TOKEN=""
    ;;
  doctor)
    SERVER_URL="${2:-$DEFAULT_SERVER_URL}"
    TPM_HANDLE="${3:-0x81010010}"
    ROBOT_ID=""
    SDK_BINDING_TOKEN=""
    ;;
  *)
    echo "Usage:" >&2
    echo "  $0 bind <sdkBindingToken> [serverUrl]" >&2
    echo "  $0 service <robotId> [serverUrl]" >&2
    echo "  $0 agent <robotId> [serverUrl]" >&2
    echo "  $0 doctor [serverUrl]" >&2
    exit 1
    ;;
esac

if [ "$MODE" = "doctor" ] && [ -z "${2:-}" ] && [ -f "$SDK_HOME/server-url" ]; then
  SERVER_URL="$(trim "$SDK_HOME/server-url")"
fi

collect() {
  COMPUTER_NAME="$(hostname 2>/dev/null || echo unknown)"
  CPU_MODEL="$(cpu 'Model name')"
  CPU_MODEL="${CPU_MODEL:-unknown}"
  CPU_MANUFACTURER="$(cpu 'Vendor ID')"
  CPU_MANUFACTURER="${CPU_MANUFACTURER:-unknown}"
  CPU_CORES="$(cpu 'Core(s) per socket')"
  CPU_CORES="${CPU_CORES:-0}"
  CPU_LOGICAL="$(cpu 'CPU(s)')"
  CPU_LOGICAL="${CPU_LOGICAL:-0}"
  CPU_MAX_MHZ="$(
    lscpu 2>/dev/null |
      awk -F: '$1 == "CPU max MHz" { sub(/^[ \t]+/, "", $2); split($2, a, "."); print a[1]; exit }'
  )"
  CPU_MAX_MHZ="${CPU_MAX_MHZ:-0}"
  COLLECTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
  DEVICE_MODEL="${ROC_DEVICE_MODEL:-$(trim /proc/device-tree/model)}"
  if [ -z "$DEVICE_MODEL" ]; then
    DEVICE_MODEL="$(trim /sys/class/dmi/id/product_name)"
  fi
  DEVICE_MODEL="${DEVICE_MODEL:-unknown}"
  MACHINE_ID="$(trim /etc/machine-id)"
  DEVICE_TYPE="${ROC_DEVICE_TYPE:-LINUX_ROBOT_AGENT}"
  NETWORK_INTERFACE="${ROC_NETWORK_INTERFACE:-}"
  if [ -z "$NETWORK_INTERFACE" ] && has_cmd ip; then
    NETWORK_INTERFACE="$(ip route 2>/dev/null | awk '$1 == "default" { print $5; exit }')"
  fi
  if [ -z "$NETWORK_INTERFACE" ] && has_cmd ip; then
    NETWORK_INTERFACE="$(ip -br addr 2>/dev/null | awk '$2 == "UP" { print $1; exit }')"
  fi
  NETWORK_INTERFACE="${NETWORK_INTERFACE:-unknown}"
  ENABLED_ADAPTERS_JSON="$(read_enabled_adapters)"
  SOFTWARE_IDENTITY_ALLOWED=false
  PLATFORM_IDENTITY_TYPE="TPM_REQUIRED"
  if [ "${ROC_ALLOW_SOFTWARE_IDENTITY:-0}" = "1" ]; then
    SOFTWARE_IDENTITY_ALLOWED=true
    PLATFORM_IDENTITY_TYPE="SOFTWARE_RSA_OVERRIDE"
  fi
}

prepare() {
  base
  collect
  if tpm_ok; then
    IDENTITY_MODE="TPM"
    PLATFORM_IDENTITY_TYPE="TPM2"
    SIGNATURE_PRIVATE_KEY_LABEL="TPM_NON_EXPORTABLE"
    KEY_PEM="$WORK_DIR/robocoin-signing-public.pem"
    TPM_HANDLE_LABEL="$TPM_HANDLE"
    TPM_INFO="TPM"
    if ! tpm2_readpublic -c "$TPM_HANDLE" -o "$KEY_PEM" -f pem >/dev/null 2>&1; then
      PRIMARY="$WORK_DIR/primary.ctx"
      PUB="$WORK_DIR/key.pub"
      PRIV="$WORK_DIR/key.priv"
      CTX="$WORK_DIR/key.ctx"
      tpm2_createprimary -C o -g sha256 -G rsa -c "$PRIMARY" >/dev/null
      tpm2_create \
        -C "$PRIMARY" -g sha256 -G rsa \
        -a 'fixedtpm|fixedparent|sensitivedataorigin|userwithauth|sign' \
        -u "$PUB" -r "$PRIV" >/dev/null
      tpm2_load -C "$PRIMARY" -u "$PUB" -r "$PRIV" -c "$CTX" >/dev/null
      tpm2_evictcontrol -C o -c "$CTX" "$TPM_HANDLE" >/dev/null
      tpm2_readpublic -c "$TPM_HANDLE" -o "$KEY_PEM" -f pem >/dev/null
    fi
  else
    if [ "$SOFTWARE_IDENTITY_ALLOWED" != true ]; then
      echo "TPM identity is required on this device." >&2
      echo "Set ROC_ALLOW_SOFTWARE_IDENTITY=1 only when software identity is acceptable." >&2
      exit 1
    fi
    IDENTITY_MODE="SOFTWARE_RSA"
    SIGNATURE_PRIVATE_KEY_LABEL="SOFTWARE_LOCAL_PRIVATE_KEY"
    KEY_PRIV="$WORK_DIR/robocoin-software-signing-private.pem"
    KEY_PEM="$WORK_DIR/robocoin-software-signing-public.pem"
    TPM_HANDLE_LABEL="SOFTWARE_RSA_LOCAL_KEY"
    TPM_INFO="SOFTWARE_RSA"
    if [ ! -s "$KEY_PRIV" ]; then
      openssl genpkey \
        -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
        -out "$KEY_PRIV" >/dev/null 2>&1
      chmod 600 "$KEY_PRIV"
    fi
    openssl rsa -in "$KEY_PRIV" -pubout -out "$KEY_PEM" >/dev/null 2>&1
  fi
  PUBLIC_KEY_PEM="$(cat "$KEY_PEM")"
  PUBLIC_KEY_FINGERPRINT="$(pubfp "$KEY_PEM")"
  EK_PUBLIC_KEY_PEM=""
  EK_PUBLIC_KEY_FINGERPRINT=""
  PLATFORM_IDENTITY_FINGERPRINT="$(
    sha "$PLATFORM_IDENTITY_TYPE|$DEVICE_MODEL|$MACHINE_ID|$NETWORK_INTERFACE|$PUBLIC_KEY_FINGERPRINT"
  )"
  MACHINE_FINGERPRINT="$(
    sha "$COMPUTER_NAME|$CPU_MODEL|$CPU_MANUFACTURER|$PLATFORM_IDENTITY_FINGERPRINT|$PUBLIC_KEY_FINGERPRINT"
  )"
}

sign() {
  if [ "$IDENTITY_MODE" = "TPM" ]; then
    tpm2_sign \
      -c "$TPM_HANDLE" -g sha256 -s rsassa -f plain \
      -o "$WORK_DIR/signature.bin" "$WORK_DIR/payload.txt"
  else
    openssl dgst \
      -sha256 -sign "$KEY_PRIV" \
      -out "$WORK_DIR/signature.bin" "$WORK_DIR/payload.txt"
  fi
  openssl dgst \
    -sha256 -verify "$KEY_PEM" \
    -signature "$WORK_DIR/signature.bin" "$WORK_DIR/payload.txt" >/dev/null
  base64 -w 0 "$WORK_DIR/signature.bin" 2>/dev/null ||
    base64 "$WORK_DIR/signature.bin" | tr -d '\n'
}

post() {
  curl -sS \
    -H 'Content-Type: application/json; charset=utf-8' \
    --data-binary "@$1" "$2" || true
}

heartbeat() {
  local at nonce interval payload sig resp
  at="$(date '+%Y-%m-%d %H:%M:%S')"
  nonce="$(date +%s%N)-$(rand)"
  interval="${ROC_HEARTBEAT_INTERVAL_SECONDS:-30}"
  payload="event=HEARTBEAT;robotId=$ROBOT_ID"
  payload+=";publicKeyFingerprint=$PUBLIC_KEY_FINGERPRINT"
  payload+=";machineFingerprint=$MACHINE_FINGERPRINT"
  payload+=";sdkVersion=$SDK_VERSION;deviceType=$DEVICE_TYPE"
  payload+=";enabledAdapters=$ENABLED_ADAPTERS_JSON"
  payload+=";nonce=$nonce;heartbeatAt=$at"
  printf '%s' "$payload" > "$WORK_DIR/payload.txt"
  sig="$(sign)"
  cat > "$OUTPUT_DIR/heartbeat-report.json" <<JSON
{
  "robotId": $ROBOT_ID,
  "sdkVersion": $(jv "$SDK_VERSION"),
  "deviceType": $(jv "$DEVICE_TYPE"),
  "computerName": $(jv "$COMPUTER_NAME"),
  "cpuModel": $(jv "$CPU_MODEL"),
  "machineFingerprint": $(jv "$MACHINE_FINGERPRINT"),
  "publicKeyFingerprint": $(jv "$PUBLIC_KEY_FINGERPRINT"),
  "platformIdentityType": $(jv "$PLATFORM_IDENTITY_TYPE"),
  "platformIdentityFingerprint": $(jv "$PLATFORM_IDENTITY_FINGERPRINT"),
  "networkInterface": $(jv "$NETWORK_INTERFACE"),
  "enabledAdapters": $ENABLED_ADAPTERS_JSON,
  "heartbeatAt": $(jv "$at"),
  "heartbeatIntervalSeconds": $interval,
  "nonce": $(jv "$nonce"),
  "signatureAlgorithm": "RSASSA-SHA256",
  "signaturePrivateKey": $(jv "$SIGNATURE_PRIVATE_KEY_LABEL"),
  "signaturePayload": $(jv "$payload"),
  "signature": $(jv "$sig")
}
JSON
  resp="$(post "$OUTPUT_DIR/heartbeat-report.json" "${SERVER_URL%/}/user/sdkAgent/heartbeat")"
  printf '%s\n' "$resp" > "$OUTPUT_DIR/heartbeat-server-response.json"
  if printf '%s' "$resp" | grep -q '"code":200'; then
    log "Heartbeat verified at $at"
  else
    log "Heartbeat failed: $resp"
  fi
}

stage_report() {
  local payload sig
  payload="$CHALLENGE_PAYLOAD"
  printf '%s' "$payload" > "$WORK_DIR/payload.txt"
  sig="$(sign)"
  cat > "$OUTPUT_DIR/stage-report.json" <<JSON
{
  "verificationId": $VERIFICATION_ID,
  "orderId": $ORDER_ID,
  "taskId": $TASK_ID,
  "robotId": $ROBOT_ID,
  "stage": $(jv "$STAGE"),
  "nonce": $(jv "$NONCE"),
  "sdkVersion": $(jv "$SDK_VERSION"),
  "deviceType": $(jv "$DEVICE_TYPE"),
  "publicKeyFingerprint": $(jv "$PUBLIC_KEY_FINGERPRINT"),
  "signatureAlgorithm": "RSASSA-SHA256",
  "signaturePrivateKey": $(jv "$SIGNATURE_PRIVATE_KEY_LABEL"),
  "signaturePayload": $(jv "$payload"),
  "signature": $(jv "$sig"),
  "computerName": $(jv "$COMPUTER_NAME"),
  "cpuModel": $(jv "$CPU_MODEL"),
  "machineFingerprint": $(jv "$MACHINE_FINGERPRINT"),
  "platformIdentityType": $(jv "$PLATFORM_IDENTITY_TYPE"),
  "platformIdentityFingerprint": $(jv "$PLATFORM_IDENTITY_FINGERPRINT"),
  "networkInterface": $(jv "$NETWORK_INTERFACE"),
  "enabledAdapters": $ENABLED_ADAPTERS_JSON,
  "collectedAt": $(jv "$COLLECTED_AT")
}
JSON
}

doctor_summary() {
  echo "[ROC SDK DOCTOR] Version: $SDK_VERSION"
  echo "[ROC SDK DOCTOR] SDK home: $SDK_HOME"
  echo "[ROC SDK DOCTOR] Server URL: $SERVER_URL"
  echo "[ROC SDK DOCTOR] Enabled adapters: $(read_enabled_adapters)"
  if [ -f "$SDK_HOME/robot-id" ]; then
    echo "[ROC SDK DOCTOR] Robot ID: $(cat "$SDK_HOME/robot-id")"
  else
    echo "[ROC SDK DOCTOR] Robot ID: missing"
  fi
  echo "[ROC SDK DOCTOR] Time: $(date 2>/dev/null || true)"
  echo "[ROC SDK DOCTOR] Hostname: $(hostname 2>/dev/null || echo unknown)"
  echo "[ROC SDK DOCTOR] Kernel: $(uname -a 2>/dev/null || true)"

  if has_cmd ip; then
    echo "[ROC SDK DOCTOR] Network interfaces:"
    ip -br addr 2>/dev/null || true
    echo "[ROC SDK DOCTOR] Default route:"
    ip route show default 2>/dev/null || true
  fi

  echo "[ROC SDK DOCTOR] SDK processes:"
  ps -ef 2>/dev/null | grep 'roc-robot-tpm-sdk.sh' | grep -v grep || true

  if has_cmd systemctl && [ -d /run/systemd/system ]; then
    echo "[ROC SDK DOCTOR] Service status: $SERVICE_NAME"
    systemctl --no-pager --full status "$SERVICE_NAME" 2>/dev/null |
      sed -n '1,18p' || true
  fi

  echo "[ROC SDK DOCTOR] Identity files:"
  ls -l "$WORK_DIR"/*signing*.pem "$WORK_DIR"/robocoin-signing-public.pem \
    2>/dev/null || true

  echo "[ROC SDK DOCTOR] Last bind response:"
  [ -f "$OUTPUT_DIR/server-response.json" ] &&
    cat "$OUTPUT_DIR/server-response.json" || true
  echo
  echo "[ROC SDK DOCTOR] Last heartbeat response:"
  [ -f "$OUTPUT_DIR/heartbeat-server-response.json" ] &&
    cat "$OUTPUT_DIR/heartbeat-server-response.json" || true
  echo
  echo "[ROC SDK DOCTOR] Last stage response:"
  [ -f "$OUTPUT_DIR/stage-server-response.json" ] &&
    cat "$OUTPUT_DIR/stage-server-response.json" || true
  echo

  if [ -f "$SDK_HOME/agent.log" ]; then
    echo "[ROC SDK DOCTOR] Last agent.log lines:"
    tail -40 "$SDK_HOME/agent.log" || true
  fi
}

if [ "$MODE" = "doctor" ]; then
  doctor_summary
  exit 0
fi
prepare

if [ "$MODE" = "service" ] || [ "$MODE" = "agent" ]; then
  log "Starting agent robotId=$ROBOT_ID identity=$IDENTITY_MODE publicKeyFingerprint=$PUBLIC_KEY_FINGERPRINT"
  last=0
  while true; do
    now="$(date +%s)"
    interval="${ROC_HEARTBEAT_INTERVAL_SECONDS:-30}"
    if [ $((now - last)) -ge "$interval" ]; then
      heartbeat
      last="$now"
    fi
    pending_url="${SERVER_URL%/}/user/sdkAgent/pendingChallenge"
    pending_url+="?robotId=$ROBOT_ID"
    pending_url+="&publicKeyFingerprint=$PUBLIC_KEY_FINGERPRINT"
    pending="$(curl -sS "$pending_url" || true)"
    tmp="$WORK_DIR/pending.json"
    printf '%s' "$pending" > "$tmp"
    has="$(json_data_field "$tmp" hasChallenge 2>/dev/null || echo false)"
    if [ "$has" = "true" ]; then
      VERIFICATION_ID="$(json_data_field "$tmp" verificationId)"
      ORDER_ID="$(json_data_field "$tmp" orderId)"
      TASK_ID="$(json_data_field "$tmp" taskId)"
      STAGE="$(json_data_field "$tmp" stage)"
      NONCE="$(json_data_field "$tmp" nonce)"
      CHALLENGE_PAYLOAD="$(json_data_field "$tmp" challengePayload)"
      stage_report
      post "$OUTPUT_DIR/stage-report.json" "${SERVER_URL%/}/user/sdkStageReport" |
        tee "$OUTPUT_DIR/stage-server-response.json"
    fi
    sleep "${ROC_AGENT_INTERVAL_SECONDS:-3}"
  done
fi

if [ "$MODE" = "stage" ]; then
  stage_report
  post "$OUTPUT_DIR/stage-report.json" "${SERVER_URL%/}/user/sdkStageReport" |
    tee "$OUTPUT_DIR/stage-server-response.json"
  exit 0
fi

[ "$MODE" = "bind" ] || [ "$MODE" = "install" ] || exit 0
if [ -z "$SDK_BINDING_TOKEN" ]; then
  echo "sdkBindingToken is required" >&2
  exit 1
fi
nonce="$(date +%s%N)-$(rand)"
payload="robotId=;ownerUserId=;sdkBindingToken=$SDK_BINDING_TOKEN"
payload+=";computerName=$COMPUTER_NAME;cpuModel=$CPU_MODEL"
payload+=";cpuManufacturer=$CPU_MANUFACTURER;cpuCores=$CPU_CORES"
payload+=";cpuLogicalProcessors=$CPU_LOGICAL"
payload+=";machineFingerprint=$MACHINE_FINGERPRINT"
payload+=";tpmManufacturer=$TPM_INFO;tpmPersistentHandle=$TPM_HANDLE_LABEL"
payload+=";publicKeyFingerprint=$PUBLIC_KEY_FINGERPRINT"
payload+=";ekPublicKeyFingerprint=$EK_PUBLIC_KEY_FINGERPRINT"
payload+=";platformIdentityType=$PLATFORM_IDENTITY_TYPE"
payload+=";platformIdentityFingerprint=$PLATFORM_IDENTITY_FINGERPRINT"
payload+=";deviceType=$DEVICE_TYPE;networkInterface=$NETWORK_INTERFACE"
payload+=";enabledAdapters=$ENABLED_ADAPTERS_JSON"
payload+=";challengeNonce=$nonce;collectedAt=$COLLECTED_AT"
printf '%s' "$payload" > "$WORK_DIR/payload.txt"
sig="$(sign)"
cat > "$OUTPUT_DIR/device-report.json" <<JSON
{
  "robotId": null,
  "ownerUserId": null,
  "sdkBindingToken": $(jv "$SDK_BINDING_TOKEN"),
  "sdkVersion": $(jv "$SDK_VERSION"),
  "deviceType": $(jv "$DEVICE_TYPE"),
  "computerName": $(jv "$COMPUTER_NAME"),
  "cpuModel": $(jv "$CPU_MODEL"),
  "cpuManufacturer": $(jv "$CPU_MANUFACTURER"),
  "cpuProcessorId": $(jv "$CPU_MANUFACTURER-$CPU_MODEL"),
  "cpuCores": $CPU_CORES,
  "cpuLogicalProcessors": $CPU_LOGICAL,
  "cpuMaxClockMhz": $CPU_MAX_MHZ,
  "machineFingerprint": $(jv "$MACHINE_FINGERPRINT"),
  "platformIdentityType": $(jv "$PLATFORM_IDENTITY_TYPE"),
  "platformIdentityFingerprint": $(jv "$PLATFORM_IDENTITY_FINGERPRINT"),
  "deviceModel": $(jv "$DEVICE_MODEL"),
  "machineId": $(jv "$MACHINE_ID"),
  "networkInterface": $(jv "$NETWORK_INTERFACE"),
  "enabledAdapters": $ENABLED_ADAPTERS_JSON,
  "tpmManufacturer": $(jv "$TPM_INFO"),
  "tpmPersistentHandle": $(jv "$TPM_HANDLE_LABEL"),
  "publicKeyPem": $(jv "$PUBLIC_KEY_PEM"),
  "publicKeyFingerprint": $(jv "$PUBLIC_KEY_FINGERPRINT"),
  "ekPublicKeyPem": $(jv "$EK_PUBLIC_KEY_PEM"),
  "ekPublicKeyFingerprint": $(jv "$EK_PUBLIC_KEY_FINGERPRINT"),
  "challengeNonce": $(jv "$nonce"),
  "signatureAlgorithm": "RSASSA-SHA256",
  "signaturePrivateKey": $(jv "$SIGNATURE_PRIVATE_KEY_LABEL"),
  "signaturePayload": $(jv "$payload"),
  "signature": $(jv "$sig"),
  "collectedAt": $(jv "$COLLECTED_AT")
}
JSON
log "Identity mode: $IDENTITY_MODE"
log "Public key fingerprint: $PUBLIC_KEY_FINGERPRINT"
log "Platform identity: $PLATFORM_IDENTITY_TYPE / $PLATFORM_IDENTITY_FINGERPRINT"
resp="$(post "$OUTPUT_DIR/device-report.json" "${SERVER_URL%/}/user/robotSdkReport")"
printf '%s\n' "$resp" | tee "$OUTPUT_DIR/server-response.json"
code="$(
  printf '%s' "$resp" |
    python3 -c 'import json, sys; print(json.load(sys.stdin).get("code", ""))' \
      2>/dev/null || true
)"
robot="$(
  printf '%s' "$resp" |
    python3 -c 'import json, sys; print(json.load(sys.stdin).get("data", {}).get("robotId", ""))' \
      2>/dev/null || true
)"
if [ -n "$robot" ]; then
  printf '%s\n' "$robot" > "$SDK_HOME/robot-id"
fi
[ "$code" = "200" ]
