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
ROC_SDK_INSTALL_DIR="$SANDBOX/install" \
ROC_SDK_HOME="$SANDBOX/home" \
ROC_SKIP_DEP_INSTALL=1 \
ROC_SDK_TEST_MODE=1 \
ROC_ALLOW_SOFTWARE_IDENTITY=1 \
ROC_ADAPTERS=none \
bash "$REPO_ROOT/install.sh" test-token http://127.0.0.1:9

test -x "$SANDBOX/install/roc-robot-tpm-sdk.sh"
test -f "$SANDBOX/install/ADAPTER-CONTRACT.md"
test -f "$SANDBOX/install/adapters/go2/adapter.json"
printf 'Core installation smoke test passed.\n'
