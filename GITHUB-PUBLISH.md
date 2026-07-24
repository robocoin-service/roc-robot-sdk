# GitHub Release Checklist

Target repository:

```text
https://github.com/robocoin-service/roc-robot-sdk
```

## Required source

A release must include:

```text
.github/workflows/ci.yml
adapters/
examples/
schemas/
tests/
ADAPTER-CONTRACT.md
install.sh
roc-robot-tpm-sdk.sh
roc_adapter_runtime.py
README.md
README-TPM-LINUX.md
```

Do not publish generated build directories, Python bytecode, local runtime state, credentials, binding tokens, SSH keys, or robot logs.

## Pre-push checks

Run from the repository root:

```bash
python3 -m unittest -v tests.test_adapter_runtime tests.test_source_quality
python3 -m py_compile \
  roc_adapter_runtime.py \
  adapters/mock-wheel/adapter.py \
  adapters/go2/runtime_adapter.py \
  adapters/go2/go2_bridge.py
bash -n install.sh roc-robot-tpm-sdk.sh adapters/go2/install.sh
bash tests/test-adapter-runtime.sh
bash tests/test-adapter-selection.sh
bash tests/test-core-install.sh
git diff --check
git status --short
```

The test suite must not require a robot, contact the production service, or start physical motion.

## Review requirements

Before merging to `main`:

- verify that Core contains no vendor-specific detection or private network defaults;
- verify that every manifest passes runtime validation;
- verify Mock Wheel start, status, timeout, failure cancellation, and normal cancellation;
- verify Go2 capability handshake without motion;
- inspect the complete diff for secrets and generated files;
- confirm the documented version matches the installer and manifests;
- choose and add the intended open-source license.

## Recommended Git workflow

Create a release branch, push it to GitHub, and review it through a pull request. Tag only after CI and review pass. Do not force-push or publish directly from an unreviewed working tree.

## Install URL after release

```text
https://raw.githubusercontent.com/robocoin-service/roc-robot-sdk/main/install.sh
```

The public repository contains no binding secret. Binding remains controlled by the platform-issued token and the device signing key.
