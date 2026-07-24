#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d)"
cleanup(){ rm -rf "$SANDBOX"; }
trap cleanup EXIT
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/lscpu" <<'EOF'
#!/usr/bin/env sh
printf 'Model name: mock Linux VM\n'
printf 'Vendor ID: mock\n'
printf 'CPU(s): 1\n'
EOF
chmod +x "$SANDBOX/bin/lscpu"

PATH="$SANDBOX/bin:$PATH" ROC_SDK_REPO_URL="$REPO_ROOT" \
ROC_SDK_SOURCE_DIR="$REPO_ROOT" \
ROC_SDK_INSTALL_DIR="$SANDBOX/install" \
ROC_SDK_HOME="$SANDBOX/home" \
ROC_SKIP_DEP_INSTALL=1 \
ROC_SDK_TEST_MODE=1 \
ROC_ALLOW_SOFTWARE_IDENTITY=1 \
ROC_ADAPTERS=mock-wheel \
bash "$REPO_ROOT/install.sh" test-token http://127.0.0.1:9

python3 "$SANDBOX/install/roc_adapter_runtime.py" validate --adapter mock-wheel >/dev/null
ROC_SDK_HOME="$SANDBOX/home" \
  python3 "$SANDBOX/install/roc_adapter_runtime.py" capabilities > "$SANDBOX/capabilities.json"
python3 - "$SANDBOX/capabilities.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    adapter_ids = [item["id"] for item in json.load(handle)["adapters"]]
assert adapter_ids == ["mock-wheel"], adapter_ids
PY
printf 'Generic adapter selection test passed.\n'
