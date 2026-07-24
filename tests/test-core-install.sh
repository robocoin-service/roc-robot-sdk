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

overlap_root="$SANDBOX/overlap"
overlap_source="$overlap_root/source"
mkdir -p "$overlap_source"
cp "$REPO_ROOT/install.sh" "$overlap_source/install.sh"
printf 'preserve\n' > "$overlap_root/sentinel"
if ROC_SDK_TEST_MODE=1 \
  ROC_SKIP_DEP_INSTALL=1 \
  ROC_ALLOW_SOFTWARE_IDENTITY=1 \
  ROC_SDK_SOURCE_DIR="$overlap_source" \
  ROC_SDK_INSTALL_DIR="$overlap_root" \
  ROC_SDK_HOME="$SANDBOX/overlap-home" \
  bash "$REPO_ROOT/install.sh" test-token http://127.0.0.1:9 >/dev/null 2>&1; then
  echo "Overlapping install and source directories were accepted" >&2
  exit 1
fi
if [ ! -f "$overlap_root/sentinel" ]; then
  echo "Install path validation did not preserve the source parent directory" >&2
  exit 1
fi

PATH="$SANDBOX/bin:$PATH" ROC_SDK_REPO_URL="$REPO_ROOT" \
ROC_SDK_SOURCE_DIR="$REPO_ROOT" \
ROC_SDK_INSTALL_DIR="$SANDBOX/install" \
ROC_SDK_HOME="$SANDBOX/home" \
ROC_SKIP_DEP_INSTALL=1 \
ROC_SDK_TEST_MODE=1 \
ROC_ALLOW_SOFTWARE_IDENTITY=1 \
ROC_ADAPTERS=none \
bash "$REPO_ROOT/install.sh" test-token http://127.0.0.1:9

test -x "$SANDBOX/install/roc-robot-tpm-sdk.sh"
test -f "$SANDBOX/install/ADAPTER-CONTRACT.md"
test -x "$SANDBOX/install/roc_adapter_runtime.py"
test -f "$SANDBOX/install/adapters/go2/adapter.json"
test -f "$SANDBOX/install/adapters/mock-wheel/adapter.json"
python3 "$SANDBOX/install/roc_adapter_runtime.py" validate --adapter mock-wheel >/dev/null
ROC_SDK_HOME="$SANDBOX/home" \
  python3 "$SANDBOX/install/roc_adapter_runtime.py" capabilities > "$SANDBOX/capabilities.json"
python3 - "$SANDBOX/capabilities.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    assert json.load(handle)["adapters"] == []
PY
printf 'Core installation smoke test passed.\n'
