# ROC Robot SDK

ROC Robot SDK is a device-neutral Linux runtime for trusted robot identity and standard job execution. Hardware control lives in optional adapters. Unitree Go2 is the first production adapter, not a dependency of SDK Core.

> Status: developer preview. The Core, adapter protocol, Mock Wheel reference, and Go2 adapter are implemented. Cloud job dispatch and broad multi-vendor hardware certification are outside this release.

## Architecture

```text
Robot identity service
        |
        v
ROC Robot SDK Core
  - TPM or explicitly enabled software identity
  - signed heartbeat and verification reports
  - adapter discovery and validation
  - capability-based job routing
  - state, timeout, cancellation, telemetry, and incidents
        |
        v
Device adapter
  - Go2
  - Mock Wheel
  - third-party adapter
        |
        v
Vendor SDK, ROS node, flight controller, field bus, or simulator
```

## Core installation

A normal installation requires a binding token and a reachable ROC service:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/robocoin-service/roc-robot-sdk/main/install.sh |
  bash -s -- <sdkBindingToken> <serverUrl>
```

Core installs with no hardware adapter unless `ROC_ADAPTERS` is set. TPM identity is required by default. Software RSA identity must be enabled explicitly:

```bash
export ROC_ALLOW_SOFTWARE_IDENTITY=1
```

Use software identity only where its weaker key protection is acceptable.

## Adapter runtime

The runtime scans `adapters/*/adapter.json`, validates manifests, and enables only adapters recorded for the current SDK home.

These commands do not move hardware:

```bash
python3 roc_adapter_runtime.py validate
python3 roc_adapter_runtime.py list --json

export ROC_SDK_HOME=/tmp/roc-sdk-demo
python3 roc_adapter_runtime.py activate --adapters mock-wheel
python3 roc_adapter_runtime.py probe --adapter mock-wheel
python3 roc_adapter_runtime.py snapshot --adapter mock-wheel
```

Run the hardware-free example job:

```bash
python3 roc_adapter_runtime.py \
  run --adapter mock-wheel --job examples/mock-delivery-job.json
```

`run` may move real hardware when a physical adapter is selected. Discovery, validation, `probe`, and `snapshot` are read-only by contract.

Runtime state is stored under `$ROC_SDK_HOME/runtime/`:

- `enabled-adapters.json`: adapters explicitly enabled on this device;
- `state.json`: latest local job state;
- `runtime.lock`: single-job process lock;
- `outbox.jsonl`: durable job state events.

No event endpoint is configured by default. Setting `ROC_ADAPTER_EVENT_URL` enables explicit HTTP event delivery; it does not enable cloud task polling.

## Adapter protocol

Adapters use `roc.adapter.jsonl.v1` over UTF-8 JSON Lines on standard input and output. Current request types are:

- `capabilities.get`
- `telemetry.get`
- `incidents.get`
- `job.start`
- `job.status`
- `job.cancel`

Machine-readable contracts are in `schemas/`. See [ADAPTER-CONTRACT.md](ADAPTER-CONTRACT.md) for implementation and safety requirements.

## Optional Go2 adapter

Go2 installation is explicit:

```bash
export ROC_ADAPTERS=go2
export ROC_ALLOW_SOFTWARE_IDENTITY=1  # only when the Go2 computer has no TPM
curl -fsSL \
  https://raw.githubusercontent.com/robocoin-service/roc-robot-sdk/main/install.sh |
  bash -s -- <sdkBindingToken> <serverUrl>
```

The Go2 adapter builds and owns its Bridge service. It translates standard jobs as follows:

| Standard job | Local Go2 action |
| --- | --- |
| `DELIVERY` | `NAVIGATE_FORWARD_AVOID` |
| `PATROL` / `INSPECTION` | `PATROL_INSPECTION` |
| `STOP` / cancellation | `/api/v1/cancel` |

The existing LiDAR navigator applies bounded speed, obstacle clearance, odometry freshness, stall detection, bypass limits, and stop-on-failure behavior. Keep the remote controller available during physical tests.

## Verification

```bash
python3 -m unittest -v tests.test_adapter_runtime tests.test_source_quality
bash -n install.sh roc-robot-tpm-sdk.sh adapters/go2/install.sh
bash tests/test-adapter-runtime.sh
bash tests/test-adapter-selection.sh
bash tests/test-core-install.sh
```

The Linux tests use Mock Wheel and test mode. They do not contact a cloud service or move a robot.

## Current limitations

- Cloud task polling and capability-based cloud dispatch are not included.
- No ROS 2 or MAVLink reference adapter is included yet.
- Only Go2 has been verified on physical robot hardware.
- Adapter package distribution and upgrades are repository-based in this release.

Do not describe this release as supporting every robot out of the box. It provides a common Linux Core and adapter contract that other robot integrations can implement.
