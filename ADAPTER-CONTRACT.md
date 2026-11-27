# ROC Robot Adapter Contract

ROC Robot SDK Core is device-neutral. A hardware adapter translates a standard job into a vendor SDK, driver, ROS node, MAVLink endpoint, or other local controller.

## Required adapter behaviour

Every adapter supplies `adapter.json` with `id`, `displayName`, `version`, `platform` (`linux`), `capabilities`, `requires`, and `entrypoint`. Use a lowercase slug for the ID and a relative, existing entrypoint inside the adapter directory. Declare only validated capabilities and document missing prerequisites.

Run `bash roc-robot-tpm-sdk.sh check-adapter path/to/adapter` from the SDK checkout. This validates metadata only. It must not be treated as a test of identification, motion, cancellation, networking, or safety.

Vendor integrations are responsible for capability registration, job start, safe cancellation, job status, incident reporting and telemetry. Core does not load arbitrary adapters or provide a generic transport for these operations.

A cross-vendor integration should define its own supported job types, required capabilities, parameters and safety policy. Reject any job the adapter cannot execute safely. Treat this as an integration requirement, not a Core API.

## Compatibility rule

Adapters install only when explicitly selected, for example `ROC_ADAPTERS=go2`. Installing Core without an adapter must work on a normal Linux VM without Go2, Unitree SDK2, ROS or vendor hardware.
