#!/usr/bin/env bash
set -euo pipefail

SDK_VERSION="0.6.0-systemd-agent"
DEFAULT_SERVER_URL="${ROC_SERVER_URL:-http://172.16.18.187:8090}"
if [ "$#" -lt 1 ]; then
  printf 'Usage:\n' >&2
  printf '  One-step: %s bind <sdkBindingToken> [serverUrl] [tpmHandle]\n' "$0" >&2
  printf '  Register: %s register <robotId> <ownerUserId> <serverUrl> <sdkBindingToken> [tpmHandle]\n' "$0" >&2
  printf '  Legacy:   %s <robotId> <ownerUserId> <serverUrl> <sdkBindingToken> [tpmHandle]\n' "$0" >&2
  printf '  Stage:    %s stage <serverUrl> <verificationId> <orderId> <taskId> <robotId> <stage> <nonce> <challengePayload> [tpmHandle]\n' "$0" >&2
  printf '  Agent:    %s agent <robotId> [serverUrl] [tpmHandle]\n' "$0" >&2
  printf '  Service:  %s service <robotId> [serverUrl] [tpmHandle]\n' "$0" >&2
  exit 1
fi

MODE="$1"
if [ "$MODE" = "bind" ] || [ "$MODE" = "install" ]; then
  if [ "$#" -lt 2 ]; then
    printf 'Usage: %s bind <sdkBindingToken> [serverUrl] [tpmHandle]\n' "$0" >&2
    exit 1
  fi
  SDK_BINDING_TOKEN="$2"
  SERVER_URL="${3:-$DEFAULT_SERVER_URL}"
  TPM_HANDLE="${4:-0x81010010}"
  ROBOT_ID=""
  OWNER_USER_ID=""
  AUTO_START_AGENT=1
elif [ "$MODE" = "register" ]; then
  if [ "$#" -lt 5 ]; then
    printf 'Usage: %s register <robotId> <ownerUserId> <serverUrl> <sdkBindingToken> [tpmHandle]\n' "$0" >&2
    exit 1
  fi
  ROBOT_ID="$2"
  OWNER_USER_ID="$3"
  SERVER_URL="$4"
  SDK_BINDING_TOKEN="$5"
  TPM_HANDLE="${6:-0x81010010}"
  AUTO_START_AGENT="${ROC_AUTO_START_AGENT:-0}"
elif [ "$MODE" = "stage" ]; then
  if [ "$#" -lt 9 ]; then
    printf 'Usage: %s stage <serverUrl> <verificationId> <orderId> <taskId> <robotId> <stage> <nonce> <challengePayload> [tpmHandle]\n' "$0" >&2
    exit 1
  fi
  SERVER_URL="$2"
  VERIFICATION_ID="$3"
  ORDER_ID="$4"
  TASK_ID="$5"
  ROBOT_ID="$6"
  STAGE="$7"
  NONCE="$8"
  CHALLENGE_PAYLOAD="$9"
  TPM_HANDLE="${10:-0x81010010}"
  OWNER_USER_ID=""
  SDK_BINDING_TOKEN=""
  AUTO_START_AGENT=0
elif [ "$MODE" = "agent" ] || [ "$MODE" = "service" ]; then
  if [ "$#" -lt 2 ]; then
    printf 'Usage: %s %s <robotId> [serverUrl] [tpmHandle]\n' "$0" "$MODE" >&2
    exit 1
  fi
  ROBOT_ID="$2"
  SERVER_URL="${3:-$DEFAULT_SERVER_URL}"
  TPM_HANDLE="${4:-0x81010010}"
  OWNER_USER_ID=""
  SDK_BINDING_TOKEN=""
  AUTO_START_AGENT=0
else
  if [ "$#" -lt 4 ]; then
    printf 'Usage: %s bind <sdkBindingToken> [serverUrl] [tpmHandle]\n' "$0" >&2
    printf 'Legacy usage: %s <robotId> <ownerUserId> <serverUrl> <sdkBindingToken> [tpmHandle]\n' "$0" >&2
    exit 1
  fi
  MODE="register"
  ROBOT_ID="$1"
  OWNER_USER_ID="$2"
  SERVER_URL="$3"
  SDK_BINDING_TOKEN="$4"
  TPM_HANDLE="${5:-0x81010010}"
  AUTO_START_AGENT="${ROC_AUTO_START_AGENT:-0}"
fi

SDK_HOME="${ROC_SDK_HOME:-$HOME/.roc-robot-sdk}"
WORK_DIR="$SDK_HOME/tpm"
OUTPUT_DIR="$SDK_HOME/output"

log() {
  printf '[ROC TPM SDK] %s\n' "$1"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '[ROC TPM SDK] missing command: %s\n' "$1" >&2
    exit 1
  fi
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

json_value() {
  printf '%s' "$1" | json_escape
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

sha256_public_key_pem() {
  openssl pkey -pubin -in "$1" -outform DER | sha256sum | awk '{print $1}'
}

sha256_text() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

read_cpu_value() {
  local key="$1"
  lscpu | awk -F: -v k="$key" '$1==k { sub(/^[ \t]+/, "", $2); print $2; exit }'
}

require_cmd tpm2_getcap
require_cmd tpm2_createprimary
require_cmd tpm2_create
require_cmd tpm2_load
require_cmd tpm2_readpublic
require_cmd tpm2_sign
require_cmd tpm2_evictcontrol
require_cmd tpm2_createek
require_cmd tpm2_getrandom
require_cmd openssl
require_cmd python3
require_cmd curl
require_cmd sha256sum
require_cmd base64
require_cmd lscpu
require_cmd xxd
if [ "$MODE" = "agent" ]; then
  require_cmd sed
fi

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

PRIMARY_CTX="$WORK_DIR/primary.ctx"
KEY_PUB="$WORK_DIR/robocoin-signing-key.pub"
KEY_PRIV="$WORK_DIR/robocoin-signing-key.priv"
KEY_CTX="$WORK_DIR/robocoin-signing-key.ctx"
KEY_PEM="$WORK_DIR/robocoin-signing-public.pem"
EK_CTX="$WORK_DIR/ek.ctx"
EK_PUB="$WORK_DIR/ek.pub"
EK_PEM="$WORK_DIR/ek.pem"
PAYLOAD_FILE="$WORK_DIR/challenge-payload.txt"
SIG_FILE="$WORK_DIR/challenge.sig"
REPORT_JSON="$OUTPUT_DIR/device-report.json"
REPORT_TXT="$OUTPUT_DIR/device-report.txt"
STAGE_REPORT_JSON="$OUTPUT_DIR/stage-report.json"
HEARTBEAT_REPORT_JSON="$OUTPUT_DIR/heartbeat-report.json"

log "Checking TPM 2.0 device..."
tpm2_getcap properties-fixed >/dev/null

log "Preparing RoboCoin TPM signing key at handle $TPM_HANDLE..."
if tpm2_readpublic -c "$TPM_HANDLE" -o "$KEY_PEM" -f pem >/dev/null 2>&1; then
  log "Existing persistent TPM signing key found."
else
  log "No persistent RoboCoin key found. Creating a new TPM signing key..."
  rm -f "$PRIMARY_CTX" "$KEY_PUB" "$KEY_PRIV" "$KEY_CTX" "$KEY_PEM"
  tpm2_createprimary -C o -g sha256 -G rsa -c "$PRIMARY_CTX" >/dev/null
  tpm2_create \
    -C "$PRIMARY_CTX" \
    -g sha256 \
    -G rsa \
    -a 'fixedtpm|fixedparent|sensitivedataorigin|userwithauth|sign' \
    -u "$KEY_PUB" \
    -r "$KEY_PRIV" >/dev/null
  tpm2_load -C "$PRIMARY_CTX" -u "$KEY_PUB" -r "$KEY_PRIV" -c "$KEY_CTX" >/dev/null
  tpm2_evictcontrol -C o -c "$KEY_CTX" "$TPM_HANDLE" >/dev/null
  tpm2_readpublic -c "$TPM_HANDLE" -o "$KEY_PEM" -f pem >/dev/null
fi

log "Reading TPM endorsement public key..."
tpm2_createek -c "$EK_CTX" -G rsa -u "$EK_PUB" >/dev/null
tpm2_readpublic -c "$EK_CTX" -o "$EK_PEM" -f pem >/dev/null

COMPUTER_NAME="$(hostname)"
CPU_MODEL="$(read_cpu_value 'Model name')"
CPU_MANUFACTURER="$(read_cpu_value 'Vendor ID')"
CPU_CORES="$(read_cpu_value 'Core(s) per socket')"
CPU_LOGICAL="$(read_cpu_value 'CPU(s)')"
CPU_MAX_MHZ="$(lscpu | awk -F: '$1=="CPU max MHz" { sub(/^[ \t]+/, "", $2); split($2, a, "."); print a[1]; exit }')"
CPU_MODEL="${CPU_MODEL:-unknown}"
CPU_MANUFACTURER="${CPU_MANUFACTURER:-unknown}"
CPU_CORES="${CPU_CORES:-0}"
CPU_LOGICAL="${CPU_LOGICAL:-0}"
CPU_MAX_MHZ="${CPU_MAX_MHZ:-0}"
TPM_MANUFACTURER="$(tpm2_getcap properties-fixed | awk '/TPM2_PT_MANUFACTURER:/ { found=1; next } found && /value:/ { gsub(/"/, "", $2); print $2; exit }')"
TPM_VENDOR="$(tpm2_getcap properties-fixed | awk '/TPM2_PT_VENDOR_STRING_1:/ { found=1; next } found && /value:/ { gsub(/"/, "", $2); print $2; exit }')"
TPM_INFO="${TPM_MANUFACTURER:-unknown}/${TPM_VENDOR:-unknown}"
COLLECTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
CHALLENGE_NONCE="$(date +%s%N)-$(tpm2_getrandom 16 | xxd -p -c 256)"
PUBLIC_KEY_FINGERPRINT="$(sha256_public_key_pem "$KEY_PEM")"
EK_PUBLIC_KEY_FINGERPRINT="$(sha256_public_key_pem "$EK_PEM")"
MACHINE_FINGERPRINT="$(sha256_text "$COMPUTER_NAME|$CPU_MODEL|$CPU_MANUFACTURER|$PUBLIC_KEY_FINGERPRINT|$EK_PUBLIC_KEY_FINGERPRINT")"

sign_and_submit_stage() {
  local verification_id="$1"
  local order_id="$2"
  local task_id="$3"
  local stage="$4"
  local nonce="$5"
  local challenge_payload="$6"
  SIGNATURE_PAYLOAD="$challenge_payload"
  printf '%s' "$SIGNATURE_PAYLOAD" > "$PAYLOAD_FILE"
  log "Signing DeRAS stage challenge: $stage / verification $verification_id"
  tpm2_sign -c "$TPM_HANDLE" -g sha256 -s rsassa -f plain -o "$SIG_FILE" "$PAYLOAD_FILE"
  openssl dgst -sha256 -verify "$KEY_PEM" -signature "$SIG_FILE" "$PAYLOAD_FILE" >/dev/null
  SIGNATURE_B64="$(base64 -w 0 "$SIG_FILE")"

  cat > "$STAGE_REPORT_JSON" <<JSON
{
  "verificationId": $verification_id,
  "orderId": $order_id,
  "taskId": $task_id,
  "robotId": $ROBOT_ID,
  "stage": $(json_value "$stage"),
  "nonce": $(json_value "$nonce"),
  "sdkVersion": "$(printf '%s' "$SDK_VERSION")",
  "publicKeyFingerprint": $(json_value "$PUBLIC_KEY_FINGERPRINT"),
  "signatureAlgorithm": "RSASSA-SHA256",
  "signaturePrivateKey": "TPM_NON_EXPORTABLE",
  "signaturePayload": $(json_value "$SIGNATURE_PAYLOAD"),
  "signature": $(json_value "$SIGNATURE_B64"),
  "computerName": $(json_value "$COMPUTER_NAME"),
  "cpuModel": $(json_value "$CPU_MODEL"),
  "machineFingerprint": $(json_value "$MACHINE_FINGERPRINT"),
  "collectedAt": $(json_value "$COLLECTED_AT")
}
JSON

  API_URL="${SERVER_URL%/}/user/sdkStageReport"
  log "Submitting stage report to server: $API_URL"
  HTTP_RESPONSE="$(curl -sS -H 'Content-Type: application/json; charset=utf-8' --data-binary "@$STAGE_REPORT_JSON" "$API_URL" || true)"
  printf '%s\n' "$HTTP_RESPONSE" | tee "$OUTPUT_DIR/stage-server-response.json"
}

send_heartbeat() {
  local heartbeat_at
  local nonce
  local interval
  local payload
  heartbeat_at="$(date '+%Y-%m-%d %H:%M:%S')"
  nonce="$(date +%s%N)-$(tpm2_getrandom 16 | xxd -p -c 256)"
  interval="${ROC_HEARTBEAT_INTERVAL_SECONDS:-30}"
  payload="event=HEARTBEAT;robotId=$ROBOT_ID;publicKeyFingerprint=$PUBLIC_KEY_FINGERPRINT;machineFingerprint=$MACHINE_FINGERPRINT;sdkVersion=$SDK_VERSION;nonce=$nonce;heartbeatAt=$heartbeat_at"
  printf '%s' "$payload" > "$PAYLOAD_FILE"
  tpm2_sign -c "$TPM_HANDLE" -g sha256 -s rsassa -f plain -o "$SIG_FILE" "$PAYLOAD_FILE"
  openssl dgst -sha256 -verify "$KEY_PEM" -signature "$SIG_FILE" "$PAYLOAD_FILE" >/dev/null
  SIGNATURE_B64="$(base64 -w 0 "$SIG_FILE")"

  cat > "$HEARTBEAT_REPORT_JSON" <<JSON
{
  "robotId": $ROBOT_ID,
  "sdkVersion": "$(printf '%s' "$SDK_VERSION")",
  "deviceType": "LINUX_TPM_ROBOT",
  "computerName": $(json_value "$COMPUTER_NAME"),
  "cpuModel": $(json_value "$CPU_MODEL"),
  "machineFingerprint": $(json_value "$MACHINE_FINGERPRINT"),
  "publicKeyFingerprint": $(json_value "$PUBLIC_KEY_FINGERPRINT"),
  "heartbeatAt": $(json_value "$heartbeat_at"),
  "heartbeatIntervalSeconds": $interval,
  "nonce": $(json_value "$nonce"),
  "signatureAlgorithm": "RSASSA-SHA256",
  "signaturePrivateKey": "TPM_NON_EXPORTABLE",
  "signaturePayload": $(json_value "$payload"),
  "signature": $(json_value "$SIGNATURE_B64")
}
JSON

  API_URL="${SERVER_URL%/}/user/sdkAgent/heartbeat"
  HTTP_RESPONSE="$(curl -sS -H 'Content-Type: application/json; charset=utf-8' --data-binary "@$HEARTBEAT_REPORT_JSON" "$API_URL" || true)"
  printf '%s\n' "$HTTP_RESPONSE" > "$OUTPUT_DIR/heartbeat-server-response.json"
  if printf '%s' "$HTTP_RESPONSE" | grep -q '"code":200'; then
    log "Heartbeat verified at $heartbeat_at"
  else
    log "Heartbeat submit failed: $HTTP_RESPONSE"
  fi
}

if [ "$MODE" = "agent" ] || [ "$MODE" = "service" ]; then
  log "Starting DeRAS SDK agent for robot $ROBOT_ID"
  log "TPM public key fingerprint: $PUBLIC_KEY_FINGERPRINT"
  log "Server: $SERVER_URL"
  log "Heartbeat interval: ${ROC_HEARTBEAT_INTERVAL_SECONDS:-30}s"
  if [ "$MODE" = "agent" ]; then
    log "Press Ctrl+C to stop."
  else
    log "Running as systemd service."
  fi
  LAST_HEARTBEAT_TS=0
  while true; do
    NOW_TS="$(date +%s)"
    HEARTBEAT_INTERVAL="${ROC_HEARTBEAT_INTERVAL_SECONDS:-30}"
    if [ $((NOW_TS - LAST_HEARTBEAT_TS)) -ge "$HEARTBEAT_INTERVAL" ]; then
      send_heartbeat
      LAST_HEARTBEAT_TS="$NOW_TS"
    fi
    PENDING_URL="${SERVER_URL%/}/user/sdkAgent/pendingChallenge?robotId=$ROBOT_ID&publicKeyFingerprint=$PUBLIC_KEY_FINGERPRINT"
    PENDING_JSON="$(curl -sS "$PENDING_URL" || true)"
    HAS_CHALLENGE="$(printf '%s' "$PENDING_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(d.get("data",{}).get("hasChallenge", False)).lower())' 2>/dev/null || printf 'false')"
    if [ "$HAS_CHALLENGE" = "true" ]; then
      CHALLENGE_TMP="$WORK_DIR/pending-challenge.json"
      printf '%s' "$PENDING_JSON" > "$CHALLENGE_TMP"
      VERIFICATION_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["verificationId"])' < "$CHALLENGE_TMP")"
      ORDER_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["orderId"])' < "$CHALLENGE_TMP")"
      TASK_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["taskId"])' < "$CHALLENGE_TMP")"
      STAGE="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["stage"])' < "$CHALLENGE_TMP")"
      NONCE="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["nonce"])' < "$CHALLENGE_TMP")"
      CHALLENGE_PAYLOAD="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["challengePayload"])' < "$CHALLENGE_TMP")"
      sign_and_submit_stage "$VERIFICATION_ID" "$ORDER_ID" "$TASK_ID" "$STAGE" "$NONCE" "$CHALLENGE_PAYLOAD"
    fi
    sleep "${ROC_AGENT_INTERVAL_SECONDS:-3}"
  done
fi

if [ "$MODE" = "stage" ]; then
  log "Stage: $STAGE"
  log "TPM public key fingerprint: $PUBLIC_KEY_FINGERPRINT"
  sign_and_submit_stage "$VERIFICATION_ID" "$ORDER_ID" "$TASK_ID" "$STAGE" "$NONCE" "$CHALLENGE_PAYLOAD"
  log "Local stage report saved: $STAGE_REPORT_JSON"
  log "Done."
  exit 0
fi

SIGNATURE_PAYLOAD="robotId=$ROBOT_ID;ownerUserId=$OWNER_USER_ID;sdkBindingToken=$SDK_BINDING_TOKEN;computerName=$COMPUTER_NAME;cpuModel=$CPU_MODEL;cpuManufacturer=$CPU_MANUFACTURER;cpuCores=$CPU_CORES;cpuLogicalProcessors=$CPU_LOGICAL;machineFingerprint=$MACHINE_FINGERPRINT;tpmManufacturer=$TPM_INFO;tpmPersistentHandle=$TPM_HANDLE;publicKeyFingerprint=$PUBLIC_KEY_FINGERPRINT;ekPublicKeyFingerprint=$EK_PUBLIC_KEY_FINGERPRINT;challengeNonce=$CHALLENGE_NONCE;collectedAt=$COLLECTED_AT"
printf '%s' "$SIGNATURE_PAYLOAD" > "$PAYLOAD_FILE"

log "Signing challenge with TPM private key..."
tpm2_sign -c "$TPM_HANDLE" -g sha256 -s rsassa -f plain -o "$SIG_FILE" "$PAYLOAD_FILE"
openssl dgst -sha256 -verify "$KEY_PEM" -signature "$SIG_FILE" "$PAYLOAD_FILE" >/dev/null
SIGNATURE_B64="$(base64 -w 0 "$SIG_FILE")"
PUBLIC_KEY_PEM="$(cat "$KEY_PEM")"
EK_PUBLIC_KEY_PEM="$(cat "$EK_PEM")"

cat > "$REPORT_JSON" <<JSON
{
  "robotId": $(if [ -n "$ROBOT_ID" ]; then printf '%s' "$ROBOT_ID"; else printf 'null'; fi),
  "ownerUserId": $(if [ -n "$OWNER_USER_ID" ]; then printf '%s' "$OWNER_USER_ID"; else printf 'null'; fi),
  "sdkBindingToken": $(json_value "$SDK_BINDING_TOKEN"),
  "sdkVersion": "$(printf '%s' "$SDK_VERSION")",
  "deviceType": "LINUX_TPM_ROBOT",
  "computerName": $(json_value "$COMPUTER_NAME"),
  "cpuModel": $(json_value "$CPU_MODEL"),
  "cpuManufacturer": $(json_value "$CPU_MANUFACTURER"),
  "cpuProcessorId": $(json_value "$CPU_MANUFACTURER-$CPU_MODEL"),
  "cpuCores": $CPU_CORES,
  "cpuLogicalProcessors": $CPU_LOGICAL,
  "cpuMaxClockMhz": $CPU_MAX_MHZ,
  "machineFingerprint": $(json_value "$MACHINE_FINGERPRINT"),
  "tpmManufacturer": $(json_value "$TPM_INFO"),
  "tpmPersistentHandle": $(json_value "$TPM_HANDLE"),
  "publicKeyPem": $(json_value "$PUBLIC_KEY_PEM"),
  "publicKeyFingerprint": $(json_value "$PUBLIC_KEY_FINGERPRINT"),
  "ekPublicKeyPem": $(json_value "$EK_PUBLIC_KEY_PEM"),
  "ekPublicKeyFingerprint": $(json_value "$EK_PUBLIC_KEY_FINGERPRINT"),
  "challengeNonce": $(json_value "$CHALLENGE_NONCE"),
  "signatureAlgorithm": "RSASSA-SHA256",
  "signaturePrivateKey": "TPM_NON_EXPORTABLE",
  "signaturePayload": $(json_value "$SIGNATURE_PAYLOAD"),
  "signature": $(json_value "$SIGNATURE_B64"),
  "collectedAt": $(json_value "$COLLECTED_AT")
}
JSON

cat > "$REPORT_TXT" <<TXT
ROC Robot TPM SDK
SDK Version: $SDK_VERSION
Robot ID: $ROBOT_ID
Owner User ID: $OWNER_USER_ID
SDK Binding Token: $SDK_BINDING_TOKEN
Computer Name: $COMPUTER_NAME
CPU Model: $CPU_MODEL
CPU Manufacturer: $CPU_MANUFACTURER
CPU Cores: $CPU_CORES
CPU Logical Processors: $CPU_LOGICAL
TPM Manufacturer: $TPM_INFO
TPM Persistent Handle: $TPM_HANDLE
Public Key Fingerprint: $PUBLIC_KEY_FINGERPRINT
EK Public Key Fingerprint: $EK_PUBLIC_KEY_FINGERPRINT
Machine Fingerprint: $MACHINE_FINGERPRINT
Signature Algorithm: RSASSA-SHA256
Signature Private Key: TPM_NON_EXPORTABLE
Signature Payload: $SIGNATURE_PAYLOAD
Signature Base64: $SIGNATURE_B64
Collected At: $COLLECTED_AT
TXT

log "CPU model: $CPU_MODEL"
log "TPM public key fingerprint: $PUBLIC_KEY_FINGERPRINT"
log "Signature algorithm: RSASSA-SHA256"
log "Local report saved: $REPORT_JSON"

API_URL="${SERVER_URL%/}/user/robotSdkReport"
log "Submitting report to server: $API_URL"
HTTP_RESPONSE="$(curl -sS -H 'Content-Type: application/json; charset=utf-8' --data-binary "@$REPORT_JSON" "$API_URL" || true)"
printf '%s\n' "$HTTP_RESPONSE" | tee "$OUTPUT_DIR/server-response.json"
SERVER_CODE="$(printf '%s' "$HTTP_RESPONSE" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("code",""))' 2>/dev/null || printf '')"
BOUND_ROBOT_ID="$(printf '%s' "$HTTP_RESPONSE" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("data",{}).get("robotId",""))' 2>/dev/null || printf '')"
REPORT_ID="$(printf '%s' "$HTTP_RESPONSE" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("data",{}).get("reportId",""))' 2>/dev/null || printf '')"

if [ "$SERVER_CODE" != "200" ]; then
  log "Server did not confirm SDK binding. Please check $OUTPUT_DIR/server-response.json"
  exit 1
fi

if [ -n "$BOUND_ROBOT_ID" ]; then
  printf '%s\n' "$BOUND_ROBOT_ID" > "$SDK_HOME/robot-id"
  ROBOT_ID="$BOUND_ROBOT_ID"
fi

if [ "$AUTO_START_AGENT" = "1" ]; then
  if [ -z "$ROBOT_ID" ]; then
    log "Binding submitted, but robotId was not returned by server. Please check $OUTPUT_DIR/server-response.json"
    log "Done."
    exit 0
  fi
  log "Binding finished. robotId=$ROBOT_ID reportId=${REPORT_ID:-unknown}"
  log "Binding finished. The installer will start the background service."
  log "Done."
  exit 0
fi

log "Done."
