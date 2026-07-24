import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path

import roc_adapter_runtime as runtime
from adapters.go2 import runtime_adapter as go2_adapter


REPO_ROOT = Path(__file__).resolve().parents[1]
ADAPTER_ROOT = REPO_ROOT / "adapters"


def job(job_id="job-1", duration=0.05, required=None):
    return {
        "schemaVersion": runtime.JOB_SCHEMA_VERSION,
        "id": job_id,
        "type": "DELIVERY",
        "requiredCapabilities": required or ["motion.linear"],
        "parameters": {"durationSeconds": duration},
        "safetyPolicy": {"cancelOnTimeout": True},
    }


class ManifestTests(unittest.TestCase):
    def test_discovers_go2_and_mock_adapter(self):
        manifests = runtime.discover_adapters([ADAPTER_ROOT])
        self.assertEqual({"go2", "mock-wheel"}, set(manifests))
        self.assertEqual(runtime.PROTOCOL, manifests["go2"].protocol)

    def test_rejects_invalid_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            adapter_dir = Path(temporary) / "bad"
            adapter_dir.mkdir()
            (adapter_dir / "adapter.py").write_text("pass\n", encoding="utf-8")
            (adapter_dir / "adapter.json").write_text(
                json.dumps(
                    {
                        "manifestVersion": 1,
                        "id": "BAD ID",
                        "displayName": "Bad",
                        "version": "1",
                        "protocol": runtime.PROTOCOL,
                        "capabilities": ["status.robot"],
                        "jobTypes": ["INSPECTION"],
                        "entrypoint": ["python3", "adapter.py"],
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaises(runtime.RuntimeFailure):
                runtime.discover_adapters([Path(temporary)])


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.manifests = runtime.discover_adapters([ADAPTER_ROOT])

    def test_all_adapters_complete_safe_capability_handshake(self):
        for manifest in self.manifests.values():
            result = runtime.probe_adapter(manifest)
            self.assertTrue(result["ok"])
            self.assertEqual(manifest.capabilities, result["capabilities"])

    def test_mock_adapter_exposes_telemetry_and_incidents(self):
        snapshot = runtime.snapshot_adapter(self.manifests["mock-wheel"])
        self.assertEqual("mock-wheel", snapshot["id"])
        self.assertEqual(100, snapshot["telemetry"]["batteryPercent"])
        self.assertTrue(snapshot["telemetry"]["simulated"])
        self.assertEqual([], snapshot["incidents"])

    def test_go2_rejects_undeclared_capability_before_bridge_call(self):
        process = runtime.AdapterProcess(self.manifests["go2"])
        try:
            with self.assertRaises(runtime.RuntimeFailure):
                process.request(
                    "job.start",
                    job={
                        "id": "unsafe-1",
                        "type": "DELIVERY",
                        "requiredCapabilities": ["arm.gripper"],
                        "parameters": {},
                        "safetyPolicy": {},
                    },
                )
        finally:
            process.close()

    def test_go2_rejects_conflicting_job_before_bridge_call(self):
        previous_job = go2_adapter.current_job
        go2_adapter.current_job = {
            "id": "active-job",
            "state": "RUNNING",
        }
        try:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                go2_adapter.handle(
                    {
                        "protocol": go2_adapter.PROTOCOL,
                        "requestId": "busy-request",
                        "type": "job.start",
                        "job": {
                            "id": "second-job",
                            "type": "DELIVERY",
                            "requiredCapabilities": ["motion.linear"],
                            "parameters": {},
                            "safetyPolicy": {},
                        },
                    }
                )
            response = json.loads(output.getvalue())
            self.assertFalse(response["ok"])
            self.assertEqual("Another job is already running", response["error"])
        finally:
            go2_adapter.current_job = previous_job

    def test_go2_rejects_nonfinite_distance_before_bridge_call(self):
        process = runtime.AdapterProcess(self.manifests["go2"])
        try:
            with self.assertRaisesRegex(runtime.RuntimeFailure, "must be finite"):
                process.request(
                    "job.start",
                    job={
                        "id": "invalid-distance",
                        "type": "DELIVERY",
                        "requiredCapabilities": [
                            "motion.linear",
                            "navigation.obstacle-avoidance",
                        ],
                        "parameters": {"distanceMeters": "nan"},
                        "safetyPolicy": {},
                    },
                )
        finally:
            process.close()

    def test_activation_registry_limits_runtime_candidates(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            empty = runtime.activate_adapters(home, self.manifests, "none")
            self.assertEqual([], empty["adapters"])
            self.assertEqual({}, runtime.enabled_manifests(home, self.manifests))
            enabled = runtime.activate_adapters(home, self.manifests, "mock-wheel")
            self.assertEqual(["mock-wheel"], enabled["adapters"])
            self.assertEqual(
                {"mock-wheel"},
                set(runtime.enabled_manifests(home, self.manifests)),
            )
            with self.assertRaises(runtime.RuntimeFailure):
                runtime.activate_adapters(home, self.manifests, "go2,none")

    def test_manifest_validation_does_not_require_a_valid_activation_registry(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            runtime.write_json_atomic(
                home / "runtime" / "enabled-adapters.json",
                {"protocol": "unsupported", "adapters": ["missing-adapter"]},
            )
            previous_home = os.environ.get("ROC_SDK_HOME")
            os.environ["ROC_SDK_HOME"] = str(home)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    result = runtime.main(
                        [
                            "--adapter-root",
                            str(ADAPTER_ROOT),
                            "validate",
                        ]
                    )
                self.assertEqual(0, result)
            finally:
                if previous_home is None:
                    os.environ.pop("ROC_SDK_HOME", None)
                else:
                    os.environ["ROC_SDK_HOME"] = previous_home

    def test_runtime_rejects_nonfinite_timing_values(self):
        for value in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(value=value):
                with contextlib.redirect_stderr(io.StringIO()):
                    result = runtime.main(
                        [
                            "--adapter-root",
                            str(ADAPTER_ROOT),
                            "run",
                            "--adapter",
                            "mock-wheel",
                            "--job",
                            str(REPO_ROOT / "examples" / "mock-delivery-job.json"),
                            f"--timeout={value}",
                        ]
                    )
                self.assertEqual(2, result)

    def test_mock_adapter_rejects_nonfinite_duration(self):
        process = runtime.AdapterProcess(self.manifests["mock-wheel"])
        try:
            with self.assertRaisesRegex(runtime.RuntimeFailure, "must be finite"):
                process.request(
                    "job.start",
                    job={
                        "id": "invalid-duration",
                        "type": "DELIVERY",
                        "requiredCapabilities": ["motion.linear"],
                        "parameters": {"durationSeconds": "nan"},
                        "safetyPolicy": {},
                    },
                )
        finally:
            process.close()

    def test_mock_job_succeeds_and_records_state_transitions(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            outbox = runtime.EventOutbox(home / "runtime" / "outbox.jsonl")
            result = runtime.JobRuntime(home, outbox).run(
                self.manifests, job(), "mock-wheel", 2.0, 0.01
            )
            self.assertEqual("SUCCEEDED", result["state"])
            records = [
                json.loads(line)
                for line in outbox.path.read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual(
                ["RECEIVED", "VALIDATED", "STARTING", "RUNNING", "SUCCEEDED"],
                [record["state"] for record in records],
            )

    def test_completed_idempotent_job_is_not_executed_twice(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            outbox = runtime.EventOutbox(home / "runtime" / "outbox.jsonl")
            first = runtime.JobRuntime(home, outbox).run(
                self.manifests, job("idempotent-1"), "mock-wheel", 2.0, 0.01
            )
            event_count = len(outbox.path.read_text(encoding="utf-8").splitlines())
            second = runtime.JobRuntime(home, outbox).run(
                self.manifests, job("idempotent-1"), "mock-wheel", 2.0, 0.01
            )
            self.assertEqual(first, second)
            self.assertEqual(
                event_count,
                len(outbox.path.read_text(encoding="utf-8").splitlines()),
            )

    def test_mock_job_can_be_cancelled(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            runner = runtime.JobRuntime(
                home, runtime.EventOutbox(home / "runtime" / "outbox.jsonl")
            )
            runner.cancel_requested.set()
            result = runner.run(
                self.manifests, job("cancel-1", duration=2), "mock-wheel", 3.0, 0.01
            )
            self.assertEqual("CANCELLED", result["state"])

    def test_mock_job_times_out_and_is_cancelled_at_adapter(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            runner = runtime.JobRuntime(
                home, runtime.EventOutbox(home / "runtime" / "outbox.jsonl")
            )
            result = runner.run(
                self.manifests, job("timeout-1", duration=2), "mock-wheel", 0.03, 0.01
            )
            self.assertEqual("TIMED_OUT", result["state"])

    def test_missing_capability_is_rejected_before_adapter_start(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            runner = runtime.JobRuntime(
                home, runtime.EventOutbox(home / "runtime" / "outbox.jsonl")
            )
            with self.assertRaises(runtime.RuntimeFailure):
                runner.run(
                    self.manifests,
                    job("reject-1", required=["arm.gripper"]),
                    "mock-wheel",
                    1.0,
                    0.01,
                )

    def test_cancel_rejects_a_reused_non_runtime_pid(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            runtime_dir = home / "runtime"
            runtime_dir.mkdir()
            runtime.write_json_atomic(
                runtime_dir / "state.json",
                {
                    "jobId": "stale-job",
                    "state": "RUNNING",
                    "pid": os.getpid(),
                },
            )
            (runtime_dir / "runtime.lock").write_text(
                str(os.getpid()), encoding="ascii"
            )
            with self.assertRaisesRegex(
                runtime.RuntimeFailure,
                "supported only on Linux|not an active ROC adapter runtime",
            ):
                runtime.cancel_active_job(home, "stale-job")

    def test_runtime_attempts_cancel_after_status_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            adapter_dir = root / "failing-wheel"
            adapter_dir.mkdir()
            marker = root / "cancelled"
            adapter_source = f'''\
import json
import sys
from pathlib import Path

PROTOCOL = "{runtime.PROTOCOL}"
MARKER = Path({str(marker)!r})

for line in sys.stdin:
    request = json.loads(line)
    message_type = request["type"]
    response = {{
        "protocol": PROTOCOL,
        "requestId": request["requestId"],
        "ok": True,
    }}
    if message_type == "capabilities.get":
        response.update(
            capabilities=["job.cancel", "motion.linear"],
            jobTypes=["DELIVERY"],
        )
    elif message_type == "job.start":
        response["state"] = "RUNNING"
    elif message_type == "job.status":
        response.update(ok=False, error="simulated status failure")
    elif message_type == "job.cancel":
        MARKER.write_text("cancelled", encoding="utf-8")
        response["state"] = "CANCELLED"
    print(json.dumps(response), flush=True)
'''
            (adapter_dir / "adapter.py").write_text(
                adapter_source, encoding="utf-8"
            )
            (adapter_dir / "adapter.json").write_text(
                json.dumps(
                    {
                        "manifestVersion": 1,
                        "id": "failing-wheel",
                        "displayName": "Failing Wheel Adapter",
                        "version": "1.0.0",
                        "platform": "linux",
                        "protocol": runtime.PROTOCOL,
                        "capabilities": ["job.cancel", "motion.linear"],
                        "jobTypes": ["DELIVERY"],
                        "requires": [],
                        "entrypoint": ["python3", "adapter.py"],
                    }
                ),
                encoding="utf-8",
            )
            manifests = runtime.discover_adapters([root])
            home = root / "home"
            runner = runtime.JobRuntime(
                home, runtime.EventOutbox(home / "runtime" / "outbox.jsonl")
            )
            with self.assertRaisesRegex(
                runtime.RuntimeFailure, "simulated status failure"
            ):
                runner.run(
                    manifests,
                    job("status-failure"),
                    "failing-wheel",
                    1.0,
                    0.01,
                )
            self.assertTrue(marker.exists())
            state = runtime.read_json(home / "runtime" / "state.json")
            self.assertEqual("FAILED", state["state"])
            self.assertEqual(
                {"attempted": True, "succeeded": True, "adapterState": "CANCELLED"},
                state["detail"]["safetyCancel"],
            )


class SourceQualityTests(unittest.TestCase):
    def test_core_agent_is_vendor_neutral(self):
        source = (REPO_ROOT / "roc-robot-tpm-sdk.sh").read_text(encoding="utf-8")
        for vendor_token in ("GO2", "UNITREE", "ORIN", "172.16." + "18.187"):
            self.assertNotIn(vendor_token, source.upper())

    def test_go2_bridge_defaults_to_loopback(self):
        source = (ADAPTER_ROOT / "go2" / "go2_bridge.py").read_text(
            encoding="utf-8"
        )
        self.assertIn("default='127.0.0.1'", source)
        self.assertNotIn("default='0.0.0.0'", source)


if __name__ == "__main__":
    unittest.main()
