# ROC Robot Adapter Contract

ROC Robot SDK Core is device-neutral. An adapter translates standard jobs into a vendor SDK, ROS node, MAVLink endpoint, field bus, simulator, or another local controller. Supporting a new robot must not require a fork of Core.

## Versioned contracts

Machine-readable JSON Schemas are provided for:

- `schemas/adapter-manifest.schema.json`
- `schemas/job.schema.json`
- `schemas/job-event.schema.json`

The process protocol identifier is `roc.adapter.jsonl.v1`. Standard jobs use `roc.job.v1`.

## Manifest

Core discovers `adapters/*/adapter.json`. A minimal manifest is:

```json
{
  "$schema": "../../schemas/adapter-manifest.schema.json",
  "manifestVersion": 1,
  "id": "mock-wheel",
  "displayName": "Mock Differential-Drive Robot",
  "version": "1.0.0",
  "platform": "linux",
  "protocol": "roc.adapter.jsonl.v1",
  "capabilities": ["job.cancel", "motion.linear", "status.robot"],
  "jobTypes": ["DELIVERY", "STOP"],
  "requires": [],
  "entrypoint": ["python3", "adapter.py"]
}
```

Rules:

- `id` is a stable lowercase identifier containing letters, digits, `.`, `_`, or `-`.
- The adapter directory name must match `id`.
- `entrypoint` must resolve inside the adapter directory.
- `capabilities` must include only behavior the adapter can safely execute.
- `jobTypes` contains device-neutral jobs, not vendor action names.
- `requires` documents prerequisites; an optional adapter `install.sh` may install or validate them.
- Installation is explicit through `ROC_ADAPTERS`.

## Transport

An adapter is a long-running child process. It reads one UTF-8 JSON object per line from standard input and writes one response object per line to standard output. Logs must go to standard error.

Every request contains:

```json
{
  "protocol": "roc.adapter.jsonl.v1",
  "requestId": "unique-request-id",
  "type": "capabilities.get",
  "sentAt": "2026-07-24T00:00:00Z"
}
```

Every response echoes `protocol` and `requestId`, and contains `ok: true` or `ok: false`. Failed responses include a stable, human-readable `error`.

## Read-only requests

`capabilities.get` returns adapter identity, capabilities, and job types. It must not initialize motion.

`telemetry.get` returns a `telemetry` object. Common fields include battery percentage, pose, motion state, and controller readiness. Unsupported values may be omitted or set to `null`.

`incidents.get` returns an `incidents` array. Each incident should include a stable code, severity, and message. Both requests must be safe during discovery and diagnostics.

## Job requests

A standard job contains a schema version, stable ID, idempotency key, required capabilities, parameters, and safety policy:

```json
{
  "schemaVersion": "roc.job.v1",
  "id": "delivery-42",
  "idempotencyKey": "delivery-42",
  "type": "DELIVERY",
  "requiredCapabilities": ["motion.linear"],
  "parameters": {"distanceMeters": 5},
  "safetyPolicy": {"cancelOnTimeout": true}
}
```

Job messages are:

```json
{"type": "job.start", "job": {}}
{"type": "job.status", "jobId": "delivery-42"}
{"type": "job.cancel", "jobId": "delivery-42", "reason": "operator request"}
```

Adapters return `RUNNING`, `SUCCEEDED`, `FAILED`, or `CANCELLED`. Core adds `RECEIVED`, `VALIDATED`, `STARTING`, `CANCELLING`, `TIMED_OUT`, and `REJECTED`.

## Capability selection

Core selects an enabled adapter only when:

1. the adapter declares the requested job type;
2. all required capabilities appear in both the manifest and live handshake.

Vendor action names stay inside the adapter. For example, Go2 may map `DELIVERY` to `NAVIGATE_FORWARD_AVOID`; Core never routes on that vendor action name.

## Safety requirements

An adapter must:

- reject unsupported jobs and capabilities before touching hardware;
- implement idempotent, bounded cancellation that leaves hardware stopped or safe;
- serialize conflicting jobs or return a busy error;
- clamp or reject unsafe parameters;
- report controller and sensor failures;
- avoid motion during validation, handshake, telemetry, and incident requests;
- stop active hardware when standard input closes or the process terminates.

Core permits one active local job per SDK home. If an error occurs after start is attempted, Core makes a best-effort `job.cancel` request before recording `FAILED`. Cancellation success or failure is included in the state detail.

## Local verification

```bash
python3 roc_adapter_runtime.py validate
export ROC_SDK_HOME=/tmp/roc-sdk-demo
python3 roc_adapter_runtime.py activate --adapters mock-wheel
python3 roc_adapter_runtime.py probe --adapter mock-wheel
python3 roc_adapter_runtime.py snapshot --adapter mock-wheel
python3 roc_adapter_runtime.py \
  run --adapter mock-wheel --job examples/mock-delivery-job.json
```

Mock Wheel is the hardware-free conformance example. Go2 uses the same protocol through `runtime_adapter.py` and its local Bridge.
