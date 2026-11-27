#!/usr/bin/env bash
set -euo pipefail

SDK_VERSION="1.1.0"
DEFAULT_SERVER_URL="${ROC_SERVER_URL:-https://deras.robocoin.io}"
MODE="${1:-}"
SDK_HOME="${ROC_SDK_HOME:-$HOME/.roc-robot-sdk}"
SDK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SDK_HOME/tpm"
OUTPUT_DIR="$SDK_HOME/output"

log(){ printf '[ROC SDK] %s\n' "$1"; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
need(){ has_cmd "$1" || { echo "missing command: $1" >&2; exit 1; }; }
jv(){ printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
sha(){ printf '%s' "$1" | sha256sum | awk '{print $1}'; }
pubfp(){ openssl pkey -pubin -in "$1" -outform DER | sha256sum | awk '{print $1}'; }
trim(){ [ -r "$1" ] && tr -d '\r\n' < "$1" 2>/dev/null || true; }
sutrim(){ if [ -r "$1" ]; then trim "$1"; elif has_cmd sudo; then sudo -n sh -c "tr -d '\\r\\n' < '$1'" 2>/dev/null || true; fi; }
cpu(){ lscpu 2>/dev/null | awk -F: -v k="$1" '$1==k { sub(/^[ \t]+/, "", $2); print $2; exit }'; }
tpm_ok(){ for cmd in tpm2_getcap tpm2_createprimary tpm2_create tpm2_load tpm2_readpublic tpm2_sign tpm2_evictcontrol; do has_cmd "$cmd" || return 1; done; tpm2_getcap properties-fixed >/dev/null 2>&1; }
rand(){ openssl rand -hex 16 2>/dev/null || date +%s%N; }
base(){ need openssl; need python3; need curl; need sha256sum; need base64; need lscpu; }

case "$MODE" in
  --version) printf '%s\n' "$SDK_VERSION"; exit 0 ;;
  doctor)
    if [ "${2:-}" = "--json" ]; then
      exec python3 "$SDK_ROOT/sdk-checks.py" status "$SDK_HOME" "$SDK_VERSION" --json
    fi
    exec python3 "$SDK_ROOT/sdk-checks.py" status "$SDK_HOME" "$SDK_VERSION"
    ;;
  check-adapter) exec python3 "$SDK_ROOT/sdk-checks.py" check-adapter "${2:-.}" ;;
  bind|install) SDK_BINDING_TOKEN="${2:-}"; SERVER_URL="${3:-$DEFAULT_SERVER_URL}"; TPM_HANDLE="${4:-0x81010010}"; ROBOT_ID="" ;;
  service|agent) ROBOT_ID="${2:-}"; SERVER_URL="${3:-$DEFAULT_SERVER_URL}"; TPM_HANDLE="${4:-0x81010010}"; SDK_BINDING_TOKEN="" ;;
  stage) SERVER_URL="${2:-$DEFAULT_SERVER_URL}"; VERIFICATION_ID="${3:-}"; ORDER_ID="${4:-}"; TASK_ID="${5:-}"; ROBOT_ID="${6:-}"; STAGE="${7:-}"; NONCE="${8:-}"; CHALLENGE_PAYLOAD="${9:-}"; TPM_HANDLE="${10:-0x81010010}"; SDK_BINDING_TOKEN="" ;;
  -h|--help|"") echo "Usage: bash $0 bind <sdkBindingToken> [serverUrl] | agent <robotId> [serverUrl] | doctor [--json] | check-adapter <directory> | --version"; exit 0 ;;
  *) echo "Unknown SDK command. Run with --help for usage." >&2; exit 1 ;;
esac

umask 077
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
SCRATCH_DIR="$(mktemp -d "$WORK_DIR/session.XXXXXXXX")"
trap 'rm -f "$SCRATCH_DIR/payload.txt" "$SCRATCH_DIR/signature.bin" "$SCRATCH_DIR/device-report.json"; rmdir "$SCRATCH_DIR"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

collect(){
  COMPUTER_NAME="$(hostname 2>/dev/null || echo unknown)"
  CPU_MODEL="$(cpu 'Model name')"; CPU_MODEL="${CPU_MODEL:-unknown}"
  CPU_MANUFACTURER="$(cpu 'Vendor ID')"; CPU_MANUFACTURER="${CPU_MANUFACTURER:-unknown}"
  CPU_CORES="$(cpu 'Core(s) per socket')"; CPU_CORES="${CPU_CORES:-0}"
  CPU_LOGICAL="$(cpu 'CPU(s)')"; CPU_LOGICAL="${CPU_LOGICAL:-0}"
  CPU_MAX_MHZ="$(lscpu 2>/dev/null | awk -F: '$1=="CPU max MHz" { sub(/^[ \t]+/, "", $2); split($2,a,"."); print a[1]; exit }')"; CPU_MAX_MHZ="${CPU_MAX_MHZ:-0}"
  COLLECTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
  DEVICE_MODEL="$(trim /proc/device-tree/model)"
  MACHINE_ID="$(trim /etc/machine-id)"
  ORIN_ECID="$(sutrim /sys/devices/platform/efuse-burn/ecid)"
  ORIN_PUBLIC_KEY="$(sutrim /sys/devices/platform/efuse-burn/public_key)"
  ORIN_BOOT_SECURITY_INFO="$(sutrim /sys/devices/platform/efuse-burn/boot_security_info)"
  ORIN_CUSTOMER_OPTIN_FUSE="$(sutrim /sys/devices/platform/efuse-burn/opt_customer_optin_fuse)"
  ORIN_PUBLIC_KEY_FINGERPRINT=""; [ -n "$ORIN_PUBLIC_KEY" ] && ORIN_PUBLIC_KEY_FINGERPRINT="$(sha "$ORIN_PUBLIC_KEY")"
  GO2_NETWORK_INTERFACE="${ROC_GO2_NETWORK_INTERFACE:-}"
  if [ -z "$GO2_NETWORK_INTERFACE" ] && has_cmd ip; then
    GO2_NETWORK_INTERFACE="$(ip -br addr 2>/dev/null | awk '$3 ~ /^192\.168\.123\./ {print $1; exit}')"
  fi
  if [ -z "$GO2_NETWORK_INTERFACE" ] && has_cmd ip; then
    GO2_NETWORK_INTERFACE="$(ip -br link 2>/dev/null | awk '$1 == "wlan0" && $2 == "UP" {print $1; exit}')"
  fi
  if [ -z "$GO2_NETWORK_INTERFACE" ] && has_cmd ip; then
    GO2_NETWORK_INTERFACE="$(ip route 2>/dev/null | awk '$1 == "default" {print $5; exit}')"
  fi
  GO2_NETWORK_INTERFACE="${GO2_NETWORK_INTERFACE:-eth0}"
  UNITREE_SDK2_PATH=""; UNITREE_PYTHON_SDK_PATH=""
  for p in "$HOME/Downloads/sdk/unitree_sdk2" "$HOME/unitree_sdk2" "/opt/unitree_sdk2"; do [ -d "$p" ] && UNITREE_SDK2_PATH="$p" && break; done
  for p in "$HOME/Downloads/sdk/unitree_sdk2_python" "$HOME/unitree_sdk2_python" "/opt/unitree_sdk2_python"; do [ -d "$p" ] && UNITREE_PYTHON_SDK_PATH="$p" && break; done
  GO2_SDK_DETECTED=false
  if [ -n "$UNITREE_SDK2_PATH" ] || [ -n "$UNITREE_PYTHON_SDK_PATH" ] || (has_cmd ip && ip -br addr 2>/dev/null | grep -q '192\.168\.123\.'); then GO2_SDK_DETECTED=true; fi
  GO2_STATE_READABLE=false; GO2_STATE_SAMPLE=""
  SOFTWARE_IDENTITY_ALLOWED=false
  if [ -n "$ORIN_ECID" ]; then
    PLATFORM_IDENTITY_TYPE="ORIN_GO2_SOFTWARE_RSA"
    SOFTWARE_IDENTITY_ALLOWED=true
  elif [ "$GO2_SDK_DETECTED" = true ]; then
    PLATFORM_IDENTITY_TYPE="GO2_SOFTWARE_RSA"
    SOFTWARE_IDENTITY_ALLOWED=true
  else
    PLATFORM_IDENTITY_TYPE="TPM_REQUIRED"
  fi
  [ "${ROC_ALLOW_SOFTWARE_IDENTITY:-0}" = "1" ] && SOFTWARE_IDENTITY_ALLOWED=true && PLATFORM_IDENTITY_TYPE="SOFTWARE_RSA_OVERRIDE"
}

prepare(){
  base; collect
  if tpm_ok; then
    IDENTITY_MODE="TPM"; SIGNATURE_PRIVATE_KEY_LABEL="TPM_NON_EXPORTABLE"; KEY_PEM="$WORK_DIR/robocoin-signing-public.pem"; TPM_HANDLE_LABEL="$TPM_HANDLE"; TPM_INFO="TPM"
    if ! tpm2_readpublic -c "$TPM_HANDLE" -o "$KEY_PEM" -f pem >/dev/null 2>&1; then
      PRIMARY="$WORK_DIR/primary.ctx"; PUB="$WORK_DIR/key.pub"; PRIV="$WORK_DIR/key.priv"; CTX="$WORK_DIR/key.ctx"
      tpm2_createprimary -C o -g sha256 -G rsa -c "$PRIMARY" >/dev/null
      tpm2_create -C "$PRIMARY" -g sha256 -G rsa -a 'fixedtpm|fixedparent|sensitivedataorigin|userwithauth|sign' -u "$PUB" -r "$PRIV" >/dev/null
      tpm2_load -C "$PRIMARY" -u "$PUB" -r "$PRIV" -c "$CTX" >/dev/null
      tpm2_evictcontrol -C o -c "$CTX" "$TPM_HANDLE" >/dev/null
      tpm2_readpublic -c "$TPM_HANDLE" -o "$KEY_PEM" -f pem >/dev/null
    fi
  else
    if [ "$SOFTWARE_IDENTITY_ALLOWED" != true ]; then
      echo "TPM is required for this industrial computer. Software RSA fallback is only enabled for detected Go2/Orin devices." >&2
      echo "Please install/check tpm2-tools and TPM device access, or set ROC_ALLOW_SOFTWARE_IDENTITY=1 only for a manual test override." >&2
      exit 1
    fi
    IDENTITY_MODE="SOFTWARE_RSA"; SIGNATURE_PRIVATE_KEY_LABEL="SOFTWARE_LOCAL_PRIVATE_KEY"; KEY_PRIV="$WORK_DIR/robocoin-software-signing-private.pem"; KEY_PEM="$WORK_DIR/robocoin-software-signing-public.pem"; TPM_HANDLE_LABEL="SOFTWARE_RSA_LOCAL_KEY"; TPM_INFO="SOFTWARE_RSA"
    [ -s "$KEY_PRIV" ] || { openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEY_PRIV" >/dev/null 2>&1; chmod 600 "$KEY_PRIV" || true; }
    openssl rsa -in "$KEY_PRIV" -pubout -out "$KEY_PEM" >/dev/null 2>&1
  fi
  PUBLIC_KEY_PEM="$(cat "$KEY_PEM")"; PUBLIC_KEY_FINGERPRINT="$(pubfp "$KEY_PEM")"; EK_PUBLIC_KEY_PEM=""; EK_PUBLIC_KEY_FINGERPRINT=""
  PLATFORM_IDENTITY_FINGERPRINT="$(sha "$PLATFORM_IDENTITY_TYPE|$ORIN_ECID|$DEVICE_MODEL|$MACHINE_ID|$GO2_NETWORK_INTERFACE|$PUBLIC_KEY_FINGERPRINT")"
  MACHINE_FINGERPRINT="$(sha "$COMPUTER_NAME|$CPU_MODEL|$CPU_MANUFACTURER|$PLATFORM_IDENTITY_FINGERPRINT|$PUBLIC_KEY_FINGERPRINT")"
}

sign(){
  if [ "$IDENTITY_MODE" = "TPM" ]; then
    tpm2_sign -c "$TPM_HANDLE" -g sha256 -s rsassa -f plain -o "$SCRATCH_DIR/signature.bin" "$SCRATCH_DIR/payload.txt" || return 1
  else
    openssl dgst -sha256 -sign "$KEY_PRIV" -out "$SCRATCH_DIR/signature.bin" "$SCRATCH_DIR/payload.txt" || return 1
  fi
  openssl dgst -sha256 -verify "$KEY_PEM" -signature "$SCRATCH_DIR/signature.bin" "$SCRATCH_DIR/payload.txt" >/dev/null || return 1
  base64 -w 0 "$SCRATCH_DIR/signature.bin" 2>/dev/null || base64 -i "$SCRATCH_DIR/signature.bin" | tr -d '\n'
}

post(){ curl -fsS --connect-timeout 5 --max-time 20 -H 'Content-Type: application/json; charset=utf-8' --data-binary "@$1" "$2" || true; }

detect_go2_bridge_url(){
  local server_host server_ip route_line source_ip bridge_port
  has_cmd ip || return 0
  server_host="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.urlsplit(sys.argv[1]).hostname or "")' "$SERVER_URL" 2>/dev/null || true)"
  [ -n "$server_host" ] || return 0
  server_ip="$server_host"
  case "$server_ip" in
    *[!0-9.]*)
      if has_cmd getent; then
        server_ip="$(getent ahostsv4 "$server_host" 2>/dev/null | awk 'NR == 1 { print $1 }')"
      fi
      ;;
  esac
  [ -n "$server_ip" ] || return 0
  route_line="$(ip -4 route get "$server_ip" 2>/dev/null | head -1 || true)"
  source_ip="$(printf '%s' "$route_line" | awk '{ for (i = 1; i <= NF; i++) if ($i == "src" && i < NF) { print $(i + 1); exit } }')"
  if [ -z "$source_ip" ]; then
    source_ip="$(ip -4 -o addr show scope global 2>/dev/null | awk -v go2="$GO2_NETWORK_INTERFACE" '$2 != go2 { split($4, a, "/"); print a[1]; exit }')"
  fi
  case "$source_ip" in
    ""|127.*|169.254.*) return 0 ;;
  esac
  bridge_port="${ROC_GO2_BRIDGE_PORT:-8080}"
  printf 'http://%s:%s' "$source_ip" "$bridge_port"
}

heartbeat(){
  at="$(date '+%Y-%m-%d %H:%M:%S')"; nonce="$(date +%s%N)-$(rand)"; interval="${ROC_HEARTBEAT_INTERVAL_SECONDS:-30}"
  go2_bridge_url="$(detect_go2_bridge_url)"
  payload="event=HEARTBEAT;robotId=$ROBOT_ID;publicKeyFingerprint=$PUBLIC_KEY_FINGERPRINT;machineFingerprint=$MACHINE_FINGERPRINT;sdkVersion=$SDK_VERSION;go2BridgeUrl=$go2_bridge_url;nonce=$nonce;heartbeatAt=$at"
  printf '%s' "$payload" > "$SCRATCH_DIR/payload.txt" || return 1
  sig="$(sign)" || return 1
  cat > "$OUTPUT_DIR/heartbeat-report.json" <<JSON
{"robotId":$ROBOT_ID,"sdkVersion":$(jv "$SDK_VERSION"),"deviceType":"LINUX_GO2_ADAPTIVE_ROBOT","computerName":$(jv "$COMPUTER_NAME"),"cpuModel":$(jv "$CPU_MODEL"),"machineFingerprint":$(jv "$MACHINE_FINGERPRINT"),"publicKeyFingerprint":$(jv "$PUBLIC_KEY_FINGERPRINT"),"platformIdentityType":$(jv "$PLATFORM_IDENTITY_TYPE"),"platformIdentityFingerprint":$(jv "$PLATFORM_IDENTITY_FINGERPRINT"),"go2NetworkInterface":$(jv "$GO2_NETWORK_INTERFACE"),"go2BridgeUrl":$(jv "$go2_bridge_url"),"go2SdkDetected":$GO2_SDK_DETECTED,"go2StateReadable":$GO2_STATE_READABLE,"heartbeatAt":$(jv "$at"),"heartbeatIntervalSeconds":$interval,"nonce":$(jv "$nonce"),"signatureAlgorithm":"RSASSA-SHA256","signaturePrivateKey":$(jv "$SIGNATURE_PRIVATE_KEY_LABEL"),"signaturePayload":$(jv "$payload"),"signature":$(jv "$sig")}
JSON
  resp="$(post "$OUTPUT_DIR/heartbeat-report.json" "${SERVER_URL%/}/user/sdkAgent/heartbeat")"; printf '%s\n' "$resp" > "$OUTPUT_DIR/heartbeat-server-response.json"
  if python3 "$SDK_ROOT/sdk-checks.py" heartbeat "$OUTPUT_DIR/heartbeat-server-response.json" "$ROBOT_ID"; then
    log "Heartbeat verified at $at"
  else
    log "Heartbeat not verified. Check connectivity and device confirmation in DeRAS."
  fi
}

stage_report(){
  payload="$CHALLENGE_PAYLOAD"
  printf '%s' "$payload" > "$SCRATCH_DIR/payload.txt" || return 1
  sig="$(sign)" || return 1
  cat > "$OUTPUT_DIR/stage-report.json" <<JSON
{"verificationId":$VERIFICATION_ID,"orderId":$ORDER_ID,"taskId":$TASK_ID,"robotId":$ROBOT_ID,"stage":$(jv "$STAGE"),"nonce":$(jv "$NONCE"),"sdkVersion":$(jv "$SDK_VERSION"),"deviceType":"LINUX_GO2_ADAPTIVE_ROBOT","publicKeyFingerprint":$(jv "$PUBLIC_KEY_FINGERPRINT"),"signatureAlgorithm":"RSASSA-SHA256","signaturePrivateKey":$(jv "$SIGNATURE_PRIVATE_KEY_LABEL"),"signaturePayload":$(jv "$payload"),"signature":$(jv "$sig"),"computerName":$(jv "$COMPUTER_NAME"),"cpuModel":$(jv "$CPU_MODEL"),"machineFingerprint":$(jv "$MACHINE_FINGERPRINT"),"platformIdentityType":$(jv "$PLATFORM_IDENTITY_TYPE"),"platformIdentityFingerprint":$(jv "$PLATFORM_IDENTITY_FINGERPRINT"),"go2NetworkInterface":$(jv "$GO2_NETWORK_INTERFACE"),"go2SdkDetected":$GO2_SDK_DETECTED,"go2StateReadable":$GO2_STATE_READABLE,"collectedAt":$(jv "$COLLECTED_AT")}
JSON
}

load_challenge(){
  IFS= read -r -d '' VERIFICATION_ID &&
    IFS= read -r -d '' ORDER_ID &&
    IFS= read -r -d '' TASK_ID &&
    IFS= read -r -d '' STAGE &&
    IFS= read -r -d '' NONCE &&
    IFS= read -r -d '' CHALLENGE_PAYLOAD
}

submit_stage(){
  stage_report || { log "Stage challenge could not be signed."; return 1; }
  local resp
  resp="$(post "$OUTPUT_DIR/stage-report.json" "${SERVER_URL%/}/user/sdkStageReport")"
  printf '%s\n' "$resp" > "$OUTPUT_DIR/stage-server-response.json" || return 1
  if python3 "$SDK_ROOT/sdk-checks.py" stage "$OUTPUT_DIR/stage-server-response.json" "$VERIFICATION_ID"; then
    log "Stage signature verified by DeRAS."
    return 0
  fi
  log "DeRAS did not confirm the stage signature."
  return 1
}

case "$MODE" in
  bind|install) [ -n "$SDK_BINDING_TOKEN" ] || { echo "DeRAS binding token is required." >&2; exit 1; } ;;
  service|agent|stage) [[ "$ROBOT_ID" =~ ^[1-9][0-9]*$ ]] || { echo "A valid robot ID is required." >&2; exit 1; } ;;
esac
prepare

if [ "$MODE" = "service" ] || [ "$MODE" = "agent" ]; then
  log "Starting agent robotId=$ROBOT_ID identity=$IDENTITY_MODE publicKeyFingerprint=$PUBLIC_KEY_FINGERPRINT"
  last=0
  while true; do
    now="$(date +%s)"; interval="${ROC_HEARTBEAT_INTERVAL_SECONDS:-30}"
    [ $((now-last)) -ge "$interval" ] && heartbeat && last="$now"
    pending="$(curl -fsS --connect-timeout 5 --max-time 10 "${SERVER_URL%/}/user/sdkAgent/pendingChallenge?robotId=$ROBOT_ID&publicKeyFingerprint=$PUBLIC_KEY_FINGERPRINT" || true)"
    if load_challenge < <(printf '%s' "$pending" | python3 "$SDK_ROOT/sdk-checks.py" challenge "$ROBOT_ID"); then
      submit_stage || true
    fi
    sleep "${ROC_AGENT_INTERVAL_SECONDS:-3}"
  done
fi

if [ "$MODE" = "stage" ]; then
  [[ "$VERIFICATION_ID" =~ ^[1-9][0-9]*$ && "$ORDER_ID" =~ ^[1-9][0-9]*$ && "$TASK_ID" =~ ^[1-9][0-9]*$ && -n "$STAGE" && -n "$NONCE" && -n "$CHALLENGE_PAYLOAD" ]] || {
    echo "Stage verification ID, order ID, task ID, stage, nonce and challenge payload are required." >&2
    exit 1
  }
  submit_stage
  exit 0
fi

[ "$MODE" = "bind" ] || [ "$MODE" = "install" ] || exit 0
[ -n "$SDK_BINDING_TOKEN" ] || { echo "sdkBindingToken is required" >&2; exit 1; }
nonce="$(date +%s%N)-$(rand)"
payload="robotId=;ownerUserId=;sdkBindingToken=$SDK_BINDING_TOKEN;computerName=$COMPUTER_NAME;cpuModel=$CPU_MODEL;cpuManufacturer=$CPU_MANUFACTURER;cpuCores=$CPU_CORES;cpuLogicalProcessors=$CPU_LOGICAL;machineFingerprint=$MACHINE_FINGERPRINT;tpmManufacturer=$TPM_INFO;tpmPersistentHandle=$TPM_HANDLE_LABEL;publicKeyFingerprint=$PUBLIC_KEY_FINGERPRINT;ekPublicKeyFingerprint=$EK_PUBLIC_KEY_FINGERPRINT;platformIdentityType=$PLATFORM_IDENTITY_TYPE;platformIdentityFingerprint=$PLATFORM_IDENTITY_FINGERPRINT;go2NetworkInterface=$GO2_NETWORK_INTERFACE;challengeNonce=$nonce;collectedAt=$COLLECTED_AT"
printf '%s' "$payload" > "$SCRATCH_DIR/payload.txt"; sig="$(sign)"
cat > "$SCRATCH_DIR/device-report.json" <<JSON
{"robotId":null,"ownerUserId":null,"sdkBindingToken":$(jv "$SDK_BINDING_TOKEN"),"sdkVersion":$(jv "$SDK_VERSION"),"deviceType":"LINUX_GO2_ADAPTIVE_ROBOT","computerName":$(jv "$COMPUTER_NAME"),"cpuModel":$(jv "$CPU_MODEL"),"cpuManufacturer":$(jv "$CPU_MANUFACTURER"),"cpuProcessorId":$(jv "$CPU_MANUFACTURER-$CPU_MODEL"),"cpuCores":$CPU_CORES,"cpuLogicalProcessors":$CPU_LOGICAL,"cpuMaxClockMhz":$CPU_MAX_MHZ,"machineFingerprint":$(jv "$MACHINE_FINGERPRINT"),"platformIdentityType":$(jv "$PLATFORM_IDENTITY_TYPE"),"platformIdentityFingerprint":$(jv "$PLATFORM_IDENTITY_FINGERPRINT"),"deviceModel":$(jv "$DEVICE_MODEL"),"machineId":$(jv "$MACHINE_ID"),"orinEcid":$(jv "$ORIN_ECID"),"orinPublicKey":$(jv "$ORIN_PUBLIC_KEY"),"orinPublicKeyFingerprint":$(jv "$ORIN_PUBLIC_KEY_FINGERPRINT"),"orinBootSecurityInfo":$(jv "$ORIN_BOOT_SECURITY_INFO"),"orinCustomerOptinFuse":$(jv "$ORIN_CUSTOMER_OPTIN_FUSE"),"go2NetworkInterface":$(jv "$GO2_NETWORK_INTERFACE"),"unitreeSdk2Path":$(jv "$UNITREE_SDK2_PATH"),"unitreePythonSdkPath":$(jv "$UNITREE_PYTHON_SDK_PATH"),"go2SdkDetected":$GO2_SDK_DETECTED,"go2StateReadable":$GO2_STATE_READABLE,"go2StateSample":$(jv "$GO2_STATE_SAMPLE"),"tpmManufacturer":$(jv "$TPM_INFO"),"tpmPersistentHandle":$(jv "$TPM_HANDLE_LABEL"),"publicKeyPem":$(jv "$PUBLIC_KEY_PEM"),"publicKeyFingerprint":$(jv "$PUBLIC_KEY_FINGERPRINT"),"ekPublicKeyPem":$(jv "$EK_PUBLIC_KEY_PEM"),"ekPublicKeyFingerprint":$(jv "$EK_PUBLIC_KEY_FINGERPRINT"),"challengeNonce":$(jv "$nonce"),"signatureAlgorithm":"RSASSA-SHA256","signaturePrivateKey":$(jv "$SIGNATURE_PRIVATE_KEY_LABEL"),"signaturePayload":$(jv "$payload"),"signature":$(jv "$sig"),"collectedAt":$(jv "$COLLECTED_AT")}
JSON
log "Identity mode: $IDENTITY_MODE"; log "Public key fingerprint: $PUBLIC_KEY_FINGERPRINT"; log "Platform identity: $PLATFORM_IDENTITY_TYPE / $PLATFORM_IDENTITY_FINGERPRINT"
resp="$(post "$SCRATCH_DIR/device-report.json" "${SERVER_URL%/}/user/robotSdkReport")"
if ! robot="$(printf '%s' "$resp" | python3 "$SDK_ROOT/sdk-checks.py" bind)"; then
  log "DeRAS did not return a verified binding. Check the robot record and the token expiry before retrying."
  exit 1
fi
printf '%s\n' "$robot" > "$SDK_HOME/robot-id"
printf '%s\n' "$SERVER_URL" > "$SDK_HOME/server-url"
rm -f "$OUTPUT_DIR/heartbeat-server-response.json"
log "DeRAS confirmed the signed device binding."
