#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d)"
cleanup(){ rm -rf "$SANDBOX"; }
trap cleanup EXIT

python3 "$REPO_ROOT/roc_adapter_runtime.py" validate >/dev/null
ROC_SDK_HOME="$SANDBOX/home" python3 "$REPO_ROOT/roc_adapter_runtime.py" \
  activate --adapters go2,mock-wheel >/dev/null
ROC_SDK_HOME="$SANDBOX/home" python3 "$REPO_ROOT/roc_adapter_runtime.py" \
  probe --adapter mock-wheel >/dev/null
ROC_SDK_HOME="$SANDBOX/home" python3 "$REPO_ROOT/roc_adapter_runtime.py" \
  probe --adapter go2 >/dev/null

ROC_SDK_HOME="$SANDBOX/home" python3 "$REPO_ROOT/roc_adapter_runtime.py" \
  run --adapter mock-wheel --job "$REPO_ROOT/examples/mock-delivery-job.json" \
  --timeout 3 --poll-interval 0.02 > "$SANDBOX/result.json"
grep -q '"state": "SUCCEEDED"' "$SANDBOX/result.json"
test -s "$SANDBOX/home/runtime/outbox.jsonl"

if printf '%s\n' '{"id":"bad","type":"DELIVERY","requiredCapabilities":["arm.gripper"]}' | \
  ROC_SDK_HOME="$SANDBOX/reject" python3 "$REPO_ROOT/roc_adapter_runtime.py" \
  run --adapter mock-wheel --job - --timeout 1 >/dev/null 2>&1; then
  printf 'Expected unsupported capability to be rejected.\n' >&2
  exit 1
fi

printf 'Adapter runtime integration test passed.\n'
