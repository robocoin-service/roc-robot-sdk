# ROC Robot Adapter Contract

ROC Robot SDK Core is device-neutral. A hardware adapter translates a standard job into a vendor SDK, driver, ROS node, MAVLink endpoint, or other local controller.

## Required adapter behaviour

Every adapter supplies `adapter.json` with its ID, capabilities, prerequisites and entrypoint. It must support capability registration, job start, safe cancellation, job status, incident reporting and telemetry reporting.

Core-level jobs use device-neutral names such as `PATROL`, `INSPECTION`, `DELIVERY`, `CAPTURE_MEDIA` and `STOP`. The job declares `requiredCapabilities`, parameters and a `safetyPolicy`. An adapter must reject a job it cannot safely execute.

## Compatibility rule

Adapters install only when explicitly selected, for example `ROC_ADAPTERS=go2`. Installing Core without an adapter must work on a normal Linux VM without Go2, Unitree SDK2, ROS or vendor hardware.
