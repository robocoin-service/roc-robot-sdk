# SDK readiness review

RoboCoin Global DeRAS handles account, robot registration and task coordination. SDK Core binds a device signing identity and reports signed heartbeats and stage challenge responses. A vendor adapter and the robot's native controller are separate. A verified heartbeat is not verified work or evidence of settlement.

| Reference | Pattern | Applied here |
| --- | --- | --- |
| [LeRobot hardware integration](https://huggingface.co/docs/lerobot/en/integrate_hardware) | Explicit device metadata and hardware contract | Offline adapter manifest validation with no driver execution |
| [ros2_control hardware components](https://control.ros.org/rolling/doc/ros2_control/hardware_interface/doc/writing_new_hardware_component.html) | Separate device lifecycle and hardware implementation | Separate installation, binding, verified heartbeat, and hardware acceptance |
| [Eclipse Paho client](https://eclipse.dev/paho/files/paho.mqtt.python/html/client.html) | Bounded connection behavior and explicit failure states | Time-limited HTTP requests and distinct local diagnostic status |

The public installer now defaults to DeRAS HTTPS instead of a private LAN address. It preserves unrelated install directories, checks the configured origin on refresh, and does not stop services in offline test mode. Binding requires the verified response and exact robot ID; an unverified heartbeat is reported separately from the installation result. The shareable doctor output intentionally omits IDs, paths, addresses, tokens, keys and raw responses. Temporary reports containing the binding secret are removed for new bindings; previous SDK installations may still have local report files and must not share them.

## Validation and remaining scope

- Run `bash tests/test-core-install.sh` and `python3 tests/test-sdk-runtime.py`. The mock API is loopback-only and does not connect to DeRAS or invoke hardware.
- Unitree Go2 is the only bundled vendor adapter. New adapters need access to their hardware, vendor APIs and an approved acceptance procedure. No automatic integration, simulated production identity, or cross-vendor motion support is implied.
- A production Linux/systemd TPM run and real-device testing are separate release checks. A local verified heartbeat in the doctor is not a substitute for current DeRAS status.
- A versioned artifact with checksums and an explicit repository license should be decided by the maintainers. A public source tree alone does not specify redistribution rights.
