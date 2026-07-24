#!/usr/bin/env python3
"""Device-neutral adapter discovery and single-job runtime for ROC Robot SDK."""

from __future__ import annotations

import argparse
import json
import math
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional


PROTOCOL = "roc.adapter.jsonl.v1"
MANIFEST_VERSION = 1
JOB_SCHEMA_VERSION = "roc.job.v1"
TERMINAL_STATES = {"SUCCEEDED", "FAILED", "CANCELLED", "TIMED_OUT", "REJECTED"}
ACTIVE_STATES = {"RECEIVED", "VALIDATED", "STARTING", "RUNNING", "CANCELLING"}
ADAPTER_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")


class RuntimeFailure(Exception):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def read_json(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeFailure(f"Cannot read JSON from {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise RuntimeFailure(f"JSON object required in {path}")
    return value


def write_json_atomic(path: Path, value: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    os.replace(temporary, path)


def string_list(value: Any, field: str, manifest_path: Path) -> List[str]:
    if not isinstance(value, list) or not value:
        raise RuntimeFailure(f"{field} must be a non-empty string array in {manifest_path}")
    normalized: List[str] = []
    for item in value:
        if not isinstance(item, str) or not item.strip():
            raise RuntimeFailure(f"{field} contains an invalid value in {manifest_path}")
        if item.strip() not in normalized:
            normalized.append(item.strip())
    return normalized


@dataclass(frozen=True)
class AdapterManifest:
    adapter_id: str
    display_name: str
    version: str
    protocol: str
    capabilities: List[str]
    job_types: List[str]
    requires: List[str]
    entrypoint: List[str]
    directory: Path
    path: Path

    def public_record(self) -> Dict[str, Any]:
        return {
            "id": self.adapter_id,
            "displayName": self.display_name,
            "version": self.version,
            "protocol": self.protocol,
            "capabilities": self.capabilities,
            "jobTypes": self.job_types,
            "requires": self.requires,
            "path": str(self.path),
        }


def validate_manifest(path: Path) -> AdapterManifest:
    raw = read_json(path)
    if raw.get("manifestVersion") != MANIFEST_VERSION:
        raise RuntimeFailure(f"manifestVersion must be {MANIFEST_VERSION} in {path}")
    adapter_id = raw.get("id")
    if not isinstance(adapter_id, str) or not ADAPTER_ID_RE.fullmatch(adapter_id):
        raise RuntimeFailure(f"Invalid adapter id in {path}: {adapter_id!r}")
    display_name = raw.get("displayName")
    version = raw.get("version")
    protocol = raw.get("protocol")
    if not isinstance(display_name, str) or not display_name.strip():
        raise RuntimeFailure(f"displayName is required in {path}")
    if not isinstance(version, str) or not version.strip():
        raise RuntimeFailure(f"version is required in {path}")
    if protocol != PROTOCOL:
        raise RuntimeFailure(f"protocol must be {PROTOCOL!r} in {path}")
    if raw.get("platform") != "linux":
        raise RuntimeFailure(f"platform must be 'linux' in {path}")
    capabilities = string_list(raw.get("capabilities"), "capabilities", path)
    job_types = [item.upper() for item in string_list(raw.get("jobTypes"), "jobTypes", path)]
    requires_value = raw.get("requires", [])
    if not isinstance(requires_value, list) or any(
        not isinstance(item, str) or not item.strip() for item in requires_value
    ):
        raise RuntimeFailure(f"requires must be a string array in {path}")
    requires = list(dict.fromkeys(item.strip() for item in requires_value))
    entrypoint_value = raw.get("entrypoint")
    if isinstance(entrypoint_value, str) and entrypoint_value.strip():
        entrypoint = [entrypoint_value.strip()]
    elif isinstance(entrypoint_value, list) and entrypoint_value and all(
        isinstance(item, str) and item.strip() for item in entrypoint_value
    ):
        entrypoint = [item.strip() for item in entrypoint_value]
    else:
        raise RuntimeFailure(f"entrypoint must be a string or string array in {path}")
    directory = path.parent.resolve()
    if directory.name != adapter_id:
        raise RuntimeFailure(
            f"Adapter directory name must match id {adapter_id!r}: {directory}"
        )
    for token in entrypoint:
        candidate = (directory / token).resolve()
        if candidate.exists():
            try:
                candidate.relative_to(directory)
            except ValueError as exc:
                raise RuntimeFailure(f"entrypoint escapes adapter directory in {path}") from exc
    entrypoint_file = (directory / entrypoint[-1]).resolve()
    if not entrypoint_file.is_file():
        raise RuntimeFailure(f"Adapter entrypoint does not exist: {entrypoint_file}")
    try:
        entrypoint_file.relative_to(directory)
    except ValueError as exc:
        raise RuntimeFailure(f"entrypoint escapes adapter directory in {path}") from exc
    return AdapterManifest(
        adapter_id=adapter_id,
        display_name=display_name.strip(),
        version=version.strip(),
        protocol=protocol,
        capabilities=capabilities,
        job_types=job_types,
        requires=requires,
        entrypoint=entrypoint,
        directory=directory,
        path=path.resolve(),
    )


def default_adapter_roots() -> List[Path]:
    roots = [Path(__file__).resolve().parent / "adapters"]
    for raw_root in os.environ.get("ROC_ADAPTER_PATH", "").split(os.pathsep):
        if raw_root.strip():
            roots.append(Path(raw_root).expanduser())
    return roots


def discover_adapters(roots: Iterable[Path]) -> Dict[str, AdapterManifest]:
    discovered: Dict[str, AdapterManifest] = {}
    seen_paths = set()
    for root in roots:
        resolved_root = root.expanduser().resolve()
        if resolved_root in seen_paths or not resolved_root.is_dir():
            continue
        seen_paths.add(resolved_root)
        for manifest_path in sorted(resolved_root.glob("*/adapter.json")):
            manifest = validate_manifest(manifest_path)
            if manifest.adapter_id in discovered:
                raise RuntimeFailure(
                    f"Duplicate adapter id {manifest.adapter_id!r}: "
                    f"{discovered[manifest.adapter_id].path} and {manifest.path}"
                )
            discovered[manifest.adapter_id] = manifest
    return discovered


def adapter_command(manifest: AdapterManifest) -> List[str]:
    command = list(manifest.entrypoint)
    if command[0] in {"python", "python3"}:
        command[0] = sys.executable
    for index, token in enumerate(command):
        candidate = (manifest.directory / token).resolve()
        if candidate.is_file():
            command[index] = str(candidate)
    if len(command) == 1 and command[0].lower().endswith(".py"):
        command.insert(0, sys.executable)
    return command


class AdapterProcess:
    def __init__(self, manifest: AdapterManifest):
        self.manifest = manifest
        self.process: Optional[subprocess.Popen[str]] = None
        self.responses: "queue.Queue[Any]" = queue.Queue()
        self.stderr_lines: List[str] = []

    def start(self) -> None:
        env = dict(os.environ)
        env["ROC_ADAPTER_ID"] = self.manifest.adapter_id
        env["ROC_ADAPTER_PROTOCOL"] = PROTOCOL
        try:
            self.process = subprocess.Popen(
                adapter_command(self.manifest),
                cwd=str(self.manifest.directory),
                env=env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                bufsize=1,
            )
        except OSError as exc:
            raise RuntimeFailure(f"Cannot start adapter {self.manifest.adapter_id}: {exc}") from exc
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        assert self.process and self.process.stdout
        for line in self.process.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self.responses.put(json.loads(line))
            except json.JSONDecodeError:
                self.responses.put(RuntimeFailure(f"Adapter emitted invalid JSON: {line[:200]}"))
        self.responses.put(None)

    def _read_stderr(self) -> None:
        assert self.process and self.process.stderr
        for line in self.process.stderr:
            self.stderr_lines.append(line.rstrip())
            if len(self.stderr_lines) > 50:
                del self.stderr_lines[:-50]

    def request(self, message_type: str, timeout: float = 10.0, **payload: Any) -> Dict[str, Any]:
        if not self.process:
            self.start()
        assert self.process and self.process.stdin
        request_id = uuid.uuid4().hex
        message = {
            "protocol": PROTOCOL,
            "requestId": request_id,
            "type": message_type,
            "sentAt": utc_now(),
            **payload,
        }
        try:
            self.process.stdin.write(json.dumps(message, ensure_ascii=False) + "\n")
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            raise RuntimeFailure(self._process_error("Adapter input closed", exc)) from exc
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeFailure(self._process_error(f"Adapter request {message_type!r} timed out"))
            try:
                response = self.responses.get(timeout=remaining)
            except queue.Empty as exc:
                raise RuntimeFailure(self._process_error(f"Adapter request {message_type!r} timed out")) from exc
            if isinstance(response, Exception):
                raise response
            if response is None:
                raise RuntimeFailure(self._process_error("Adapter process exited"))
            if not isinstance(response, dict):
                raise RuntimeFailure("Adapter response must be a JSON object")
            if response.get("requestId") != request_id:
                continue
            if response.get("protocol") != PROTOCOL:
                raise RuntimeFailure("Adapter response uses an unsupported protocol")
            if response.get("ok") is not True:
                raise RuntimeFailure(str(response.get("error") or "Adapter rejected request"))
            return response

    def _process_error(self, message: str, exc: Optional[Exception] = None) -> str:
        details = "\n".join(self.stderr_lines[-10:])
        suffix = f": {exc}" if exc else ""
        return f"{message}{suffix}" + (f"; adapter stderr: {details}" if details else "")

    def close(self) -> None:
        if not self.process:
            return
        if self.process.poll() is None:
            if self.process.stdin and not self.process.stdin.closed:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=2)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            if stream and not stream.closed:
                stream.close()


class EventOutbox:
    def __init__(self, path: Path, endpoint: str = ""):
        self.path = path
        self.endpoint = endpoint.strip()
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def emit(self, event: Dict[str, Any]) -> None:
        record = dict(event)
        record["eventId"] = record.get("eventId") or uuid.uuid4().hex
        record["occurredAt"] = record.get("occurredAt") or utc_now()
        record["delivered"] = self._deliver(record) if self.endpoint else False
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")

    def _deliver(self, record: Dict[str, Any]) -> bool:
        request = urllib.request.Request(
            self.endpoint,
            data=json.dumps(record, ensure_ascii=False).encode("utf-8"),
            headers={"Content-Type": "application/json; charset=utf-8"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return 200 <= response.status < 300
        except (OSError, urllib.error.URLError):
            return False

    def flush(self) -> Dict[str, int]:
        if not self.endpoint:
            raise RuntimeFailure("ROC_ADAPTER_EVENT_URL is required to flush the outbox")
        if not self.path.exists():
            return {"total": 0, "delivered": 0, "pending": 0}
        records: List[Dict[str, Any]] = []
        for line_number, line in enumerate(
            self.path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as exc:
                raise RuntimeFailure(f"Invalid outbox record at line {line_number}: {exc}") from exc
            if not record.get("delivered"):
                record["delivered"] = self._deliver(record)
            records.append(record)
        temporary = self.path.with_name(f".{self.path.name}.{os.getpid()}.tmp")
        with temporary.open("w", encoding="utf-8") as handle:
            for record in records:
                handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        os.replace(temporary, self.path)
        delivered = sum(1 for record in records if record.get("delivered"))
        return {
            "total": len(records),
            "delivered": delivered,
            "pending": len(records) - delivered,
        }


def validate_job(job: Dict[str, Any]) -> Dict[str, Any]:
    allowed_fields = {
        "$schema",
        "schemaVersion",
        "id",
        "idempotencyKey",
        "type",
        "requiredCapabilities",
        "parameters",
        "safetyPolicy",
    }
    unknown_fields = sorted(set(job) - allowed_fields)
    if unknown_fields:
        raise RuntimeFailure(f"Unknown job fields: {unknown_fields}")
    if job.get("schemaVersion") != JOB_SCHEMA_VERSION:
        raise RuntimeFailure(f"schemaVersion must be {JOB_SCHEMA_VERSION!r}")
    job_id = job.get("id")
    job_type = job.get("type")
    if not isinstance(job_id, str) or not job_id.strip():
        raise RuntimeFailure("Job id is required")
    if not isinstance(job_type, str) or not job_type.strip():
        raise RuntimeFailure("Job type is required")
    idempotency_key = job.get("idempotencyKey", job_id)
    if not isinstance(idempotency_key, str) or not idempotency_key.strip():
        raise RuntimeFailure("idempotencyKey must be a non-empty string")
    if len(idempotency_key) > 256:
        raise RuntimeFailure("idempotencyKey must not exceed 256 characters")
    required = job.get("requiredCapabilities", [])
    if not isinstance(required, list) or any(
        not isinstance(item, str) or not item.strip() for item in required
    ):
        raise RuntimeFailure("requiredCapabilities must be a string array")
    parameters = job.get("parameters", {})
    safety_policy = job.get("safetyPolicy", {})
    if not isinstance(parameters, dict):
        raise RuntimeFailure("parameters must be an object")
    if not isinstance(safety_policy, dict):
        raise RuntimeFailure("safetyPolicy must be an object")
    normalized = dict(job)
    normalized["schemaVersion"] = JOB_SCHEMA_VERSION
    normalized["id"] = job_id.strip()
    normalized["idempotencyKey"] = idempotency_key.strip()
    normalized["type"] = job_type.strip().upper()
    normalized["requiredCapabilities"] = list(
        dict.fromkeys(item.strip() for item in required)
    )
    normalized["parameters"] = parameters
    normalized["safetyPolicy"] = safety_policy
    return normalized


def select_adapter(
    manifests: Dict[str, AdapterManifest], job: Dict[str, Any], adapter_id: str
) -> AdapterManifest:
    required = set(job["requiredCapabilities"])
    job_type = job["type"]
    if adapter_id != "auto":
        manifest = manifests.get(adapter_id)
        if not manifest:
            raise RuntimeFailure(f"Adapter not found: {adapter_id}")
        candidates = [manifest]
    else:
        candidates = [manifests[key] for key in sorted(manifests)]
    for manifest in candidates:
        if job_type in manifest.job_types and required.issubset(manifest.capabilities):
            return manifest
    detail = f"type={job_type} requiredCapabilities={sorted(required)}"
    if adapter_id == "auto":
        raise RuntimeFailure(f"No installed adapter can execute job: {detail}")
    raise RuntimeFailure(f"Adapter {adapter_id!r} cannot execute job: {detail}")


class JobRuntime:
    def __init__(self, sdk_home: Path, outbox: EventOutbox):
        self.runtime_dir = sdk_home / "runtime"
        self.state_path = self.runtime_dir / "state.json"
        self.lock_path = self.runtime_dir / "runtime.lock"
        self.outbox = outbox
        self.cancel_requested = threading.Event()
        self.job: Dict[str, Any] = {}
        self.manifest: Optional[AdapterManifest] = None
        self.adapter: Optional[AdapterProcess] = None
        self.old_signal_handlers: Dict[int, Any] = {}

    @staticmethod
    def _pid_is_active(pid: int) -> bool:
        if pid <= 0:
            return False
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def _acquire_lock(self) -> None:
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        for _ in range(2):
            try:
                descriptor = os.open(
                    self.lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600
                )
                with os.fdopen(descriptor, "w", encoding="ascii") as handle:
                    handle.write(str(os.getpid()))
                return
            except FileExistsError:
                try:
                    owner = int(self.lock_path.read_text(encoding="ascii").strip())
                except (OSError, ValueError):
                    owner = -1
                if self._pid_is_active(owner):
                    raise RuntimeFailure(f"Another adapter runtime is active with pid {owner}")
                try:
                    self.lock_path.unlink()
                except FileNotFoundError:
                    pass
        raise RuntimeFailure("Cannot acquire adapter runtime lock")

    def _release_lock(self) -> None:
        try:
            owner = int(self.lock_path.read_text(encoding="ascii").strip())
            if owner == os.getpid():
                self.lock_path.unlink()
        except (OSError, ValueError):
            pass

    def _handle_signal(self, _signum: int, _frame: Any) -> None:
        self.cancel_requested.set()

    def _install_signal_handlers(self) -> None:
        for signum in (signal.SIGINT, signal.SIGTERM):
            self.old_signal_handlers[signum] = signal.getsignal(signum)
            signal.signal(signum, self._handle_signal)

    def _restore_signal_handlers(self) -> None:
        for signum, handler in self.old_signal_handlers.items():
            signal.signal(signum, handler)
        self.old_signal_handlers.clear()

    def _transition(self, state: str, detail: Optional[Dict[str, Any]] = None) -> None:
        record = {
            "protocol": PROTOCOL,
            "jobId": self.job.get("id"),
            "jobType": self.job.get("type"),
            "idempotencyKey": self.job.get("idempotencyKey"),
            "adapterId": self.manifest.adapter_id if self.manifest else None,
            "state": state,
            "pid": os.getpid(),
            "updatedAt": utc_now(),
            "detail": detail or {},
        }
        write_json_atomic(self.state_path, record)
        self.outbox.emit(
            {
                "type": "job.state.changed",
                "jobId": record["jobId"],
                "jobType": record["jobType"],
                "idempotencyKey": record["idempotencyKey"],
                "adapterId": record["adapterId"],
                "state": state,
                "detail": record["detail"],
            }
        )

    def run(
        self,
        manifests: Dict[str, AdapterManifest],
        raw_job: Dict[str, Any],
        adapter_id: str,
        timeout: float,
        poll_interval: float,
    ) -> Dict[str, Any]:
        self.job = validate_job(raw_job)
        if self.state_path.exists():
            previous = read_json(self.state_path)
            same_request = (
                previous.get("idempotencyKey") == self.job["idempotencyKey"]
            )
            if same_request and previous.get("state") in TERMINAL_STATES:
                return previous
        self._acquire_lock()
        self._install_signal_handlers()
        last_state = "RECEIVED"
        start_attempted = False
        try:
            self._transition(last_state)
            self.manifest = select_adapter(manifests, self.job, adapter_id)
            last_state = "VALIDATED"
            self._transition(last_state)
            self.adapter = AdapterProcess(self.manifest)
            capabilities = self.adapter.request("capabilities.get", timeout=10)
            reported = capabilities.get("capabilities")
            if not isinstance(reported, list):
                raise RuntimeFailure("Adapter capabilities response is invalid")
            missing = set(self.job["requiredCapabilities"]) - set(reported)
            if missing:
                raise RuntimeFailure(f"Adapter did not report required capabilities: {sorted(missing)}")
            last_state = "STARTING"
            self._transition(last_state)
            start_attempted = True
            response = self.adapter.request("job.start", job=self.job, timeout=10)
            last_state = str(response.get("state") or "RUNNING").upper()
            if last_state not in TERMINAL_STATES | {"RUNNING"}:
                raise RuntimeFailure(f"Adapter returned invalid job state: {last_state}")
            self._transition(last_state, response.get("data"))
            deadline = time.monotonic() + timeout
            while last_state not in TERMINAL_STATES:
                if self.cancel_requested.is_set():
                    self._transition("CANCELLING", {"reason": "runtime signal"})
                    response = self.adapter.request(
                        "job.cancel", jobId=self.job["id"], reason="runtime signal", timeout=10
                    )
                    last_state = str(response.get("state") or "CANCELLED").upper()
                    if last_state not in TERMINAL_STATES:
                        last_state = "CANCELLED"
                    self._transition(last_state, response.get("data"))
                    break
                if time.monotonic() >= deadline:
                    try:
                        self.adapter.request(
                            "job.cancel", jobId=self.job["id"], reason="runtime timeout", timeout=5
                        )
                    finally:
                        last_state = "TIMED_OUT"
                        self._transition(last_state, {"timeoutSeconds": timeout})
                    break
                self.cancel_requested.wait(max(0.05, poll_interval))
                if self.cancel_requested.is_set():
                    continue
                response = self.adapter.request("job.status", jobId=self.job["id"], timeout=10)
                new_state = str(response.get("state") or "RUNNING").upper()
                if new_state not in TERMINAL_STATES | {"RUNNING"}:
                    raise RuntimeFailure(f"Adapter returned invalid job state: {new_state}")
                if new_state != last_state:
                    last_state = new_state
                    self._transition(last_state, response.get("data"))
            return read_json(self.state_path)
        except Exception as exc:
            cancel_detail: Dict[str, Any] = {"attempted": False}
            if start_attempted and self.adapter and last_state not in TERMINAL_STATES:
                cancel_detail["attempted"] = True
                try:
                    cancel_response = self.adapter.request(
                        "job.cancel",
                        jobId=self.job["id"],
                        reason="runtime failure",
                        timeout=5,
                    )
                    cancel_detail["succeeded"] = True
                    cancel_detail["adapterState"] = str(
                        cancel_response.get("state") or "CANCELLED"
                    ).upper()
                except Exception as cancel_exc:
                    cancel_detail["succeeded"] = False
                    cancel_detail["error"] = str(cancel_exc)
            if last_state not in TERMINAL_STATES:
                try:
                    self._transition(
                        "FAILED",
                        {"error": str(exc), "safetyCancel": cancel_detail},
                    )
                except Exception:
                    pass
            if isinstance(exc, RuntimeFailure):
                raise
            raise RuntimeFailure(str(exc)) from exc
        finally:
            if self.adapter:
                self.adapter.close()
            self._restore_signal_handlers()
            self._release_lock()


def sdk_home_from_environment() -> Path:
    return Path(
        os.environ.get("ROC_SDK_HOME", str(Path.home() / ".roc-robot-sdk"))
    ).expanduser()


def activate_adapters(
    sdk_home: Path, manifests: Dict[str, AdapterManifest], configured: str
) -> Dict[str, Any]:
    values = [] if configured.strip() in {"", "none"} else configured.split(",")
    adapter_ids: List[str] = []
    for raw_value in values:
        adapter_id = raw_value.strip()
        if not adapter_id:
            continue
        if adapter_id == "none":
            raise RuntimeFailure("Adapter 'none' cannot be combined with another adapter ID")
        if adapter_id not in manifests:
            raise RuntimeFailure(f"Adapter not found: {adapter_id}")
        if adapter_id not in adapter_ids:
            adapter_ids.append(adapter_id)
    record = {
        "protocol": PROTOCOL,
        "updatedAt": utc_now(),
        "adapters": adapter_ids,
    }
    write_json_atomic(sdk_home / "runtime" / "enabled-adapters.json", record)
    return record


def enabled_manifests(
    sdk_home: Path, manifests: Dict[str, AdapterManifest]
) -> Dict[str, AdapterManifest]:
    registry_path = sdk_home / "runtime" / "enabled-adapters.json"
    if not registry_path.exists():
        if os.environ.get("ROC_ENABLE_UNREGISTERED_ADAPTERS") == "1":
            return manifests
        return {}
    registry = read_json(registry_path)
    if registry.get("protocol") != PROTOCOL:
        raise RuntimeFailure(f"Enabled adapter registry uses an unsupported protocol: {registry_path}")
    adapter_ids = registry.get("adapters")
    if not isinstance(adapter_ids, list) or any(
        not isinstance(adapter_id, str) for adapter_id in adapter_ids
    ):
        raise RuntimeFailure(f"Enabled adapter registry is invalid: {registry_path}")
    missing = sorted(set(adapter_ids) - set(manifests))
    if missing:
        raise RuntimeFailure(f"Enabled adapters are not installed: {missing}")
    return {adapter_id: manifests[adapter_id] for adapter_id in adapter_ids}


def probe_adapter(manifest: AdapterManifest) -> Dict[str, Any]:
    process = AdapterProcess(manifest)
    try:
        response = process.request("capabilities.get", timeout=10)
        return {
            "id": manifest.adapter_id,
            "ok": True,
            "capabilities": response.get("capabilities", []),
            "jobTypes": response.get("jobTypes", []),
        }
    finally:
        process.close()


def snapshot_adapter(manifest: AdapterManifest) -> Dict[str, Any]:
    process = AdapterProcess(manifest)
    try:
        telemetry = process.request("telemetry.get", timeout=10)
        incidents = process.request("incidents.get", timeout=10)
        return {
            "id": manifest.adapter_id,
            "telemetry": telemetry.get("telemetry", {}),
            "incidents": incidents.get("incidents", []),
        }
    finally:
        process.close()


def load_job(path_value: str) -> Dict[str, Any]:
    if path_value == "-":
        try:
            value = json.load(sys.stdin)
        except json.JSONDecodeError as exc:
            raise RuntimeFailure(f"Invalid job JSON on stdin: {exc}") from exc
        if not isinstance(value, dict):
            raise RuntimeFailure("Job JSON must be an object")
        return value
    return read_json(Path(path_value))


def verify_runtime_process(pid: int) -> None:
    if not sys.platform.startswith("linux"):
        raise RuntimeFailure("Cross-process cancellation is supported only on Linux")
    command_path = Path(f"/proc/{pid}/cmdline")
    try:
        arguments = [
            value.decode("utf-8", errors="replace")
            for value in command_path.read_bytes().split(b"\0")
            if value
        ]
    except OSError as exc:
        raise RuntimeFailure(f"Cannot inspect runtime pid {pid}: {exc}") from exc
    runtime_path = Path(__file__).resolve()
    matches_runtime = False
    for argument in arguments:
        if argument.startswith("-"):
            continue
        try:
            if Path(argument).resolve() == runtime_path:
                matches_runtime = True
                break
        except OSError:
            continue
    if not matches_runtime or "run" not in arguments:
        raise RuntimeFailure(f"Pid {pid} is not an active ROC adapter runtime")


def cancel_active_job(sdk_home: Path, job_id: str) -> Dict[str, Any]:
    state_path = sdk_home / "runtime" / "state.json"
    if not state_path.exists():
        raise RuntimeFailure("No adapter runtime state exists")
    state = read_json(state_path)
    if state.get("jobId") != job_id:
        raise RuntimeFailure(
            f"Active state belongs to job {state.get('jobId')!r}, not {job_id!r}"
        )
    if state.get("state") not in ACTIVE_STATES:
        raise RuntimeFailure(f"Job is not active; current state is {state.get('state')}")
    pid = int(state.get("pid") or 0)
    if pid <= 0:
        raise RuntimeFailure("Runtime state does not contain a valid pid")
    lock_path = sdk_home / "runtime" / "runtime.lock"
    try:
        lock_owner = int(lock_path.read_text(encoding="ascii").strip())
    except (OSError, ValueError) as exc:
        raise RuntimeFailure("Active runtime lock is missing or invalid") from exc
    if lock_owner != pid:
        raise RuntimeFailure(
            f"Runtime lock belongs to pid {lock_owner}, not state pid {pid}"
        )
    verify_runtime_process(pid)
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError as exc:
        raise RuntimeFailure(f"Cannot signal runtime pid {pid}: {exc}") from exc
    return {"jobId": job_id, "pid": pid, "signal": "SIGTERM"}


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--adapter-root",
        action="append",
        default=[],
        help="Adapter directory to scan. May be repeated.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    list_parser = subparsers.add_parser("list", help="List validated adapter manifests")
    list_parser.add_argument("--json", action="store_true")
    validate_parser = subparsers.add_parser("validate", help="Validate adapter manifests")
    validate_parser.add_argument("--adapter", default="")
    activate_parser = subparsers.add_parser(
        "activate", help="Record the adapters enabled on this device"
    )
    activate_parser.add_argument("--adapters", required=True)
    subparsers.add_parser(
        "capabilities", help="Build the local capability registration document"
    )
    probe_parser = subparsers.add_parser(
        "probe", help="Start adapters and perform a non-job protocol handshake"
    )
    probe_parser.add_argument("--adapter", default="")
    snapshot_parser = subparsers.add_parser(
        "snapshot", help="Read adapter telemetry and active incidents"
    )
    snapshot_parser.add_argument("--adapter", default="")
    run_parser = subparsers.add_parser("run", help="Run one standard job")
    run_parser.add_argument("--job", required=True, help="Job JSON path, or - for stdin")
    run_parser.add_argument("--adapter", default="auto")
    run_parser.add_argument("--timeout", type=float, default=300.0)
    run_parser.add_argument("--poll-interval", type=float, default=0.25)
    cancel_parser = subparsers.add_parser("cancel", help="Cancel the active local job")
    cancel_parser.add_argument("--job-id", required=True)
    subparsers.add_parser("status", help="Show the last local job state")
    subparsers.add_parser("flush-outbox", help="Retry undelivered adapter events")
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = create_parser()
    args = parser.parse_args(argv)
    sdk_home = sdk_home_from_environment()
    outbox = EventOutbox(
        sdk_home / "runtime" / "outbox.jsonl",
        os.environ.get("ROC_ADAPTER_EVENT_URL", ""),
    )
    roots = [Path(value) for value in args.adapter_root] or default_adapter_roots()
    try:
        if args.command == "cancel":
            print(json.dumps(cancel_active_job(sdk_home, args.job_id), indent=2))
            return 0
        if args.command == "status":
            state_path = sdk_home / "runtime" / "state.json"
            if not state_path.exists():
                raise RuntimeFailure("No adapter runtime state exists")
            print(json.dumps(read_json(state_path), ensure_ascii=False, indent=2))
            return 0
        if args.command == "flush-outbox":
            print(json.dumps(outbox.flush(), indent=2))
            return 0
        manifests = discover_adapters(roots)
        if args.command == "activate":
            print(
                json.dumps(activate_adapters(sdk_home, manifests, args.adapters), indent=2)
            )
            return 0
        if args.command == "list":
            records = [manifests[key].public_record() for key in sorted(manifests)]
            if args.json:
                print(json.dumps(records, ensure_ascii=False, indent=2))
            else:
                for record in records:
                    print(
                        f"{record['id']}\t{record['version']}\t"
                        f"{','.join(record['jobTypes'])}"
                    )
            return 0
        if args.command == "validate":
            if args.adapter and args.adapter not in manifests:
                raise RuntimeFailure(f"Adapter not found: {args.adapter}")
            selected = [args.adapter] if args.adapter else sorted(manifests)
            print(
                json.dumps(
                    {"ok": True, "protocol": PROTOCOL, "adapters": selected}, indent=2
                )
            )
            return 0
        active = enabled_manifests(sdk_home, manifests)
        if args.command == "capabilities":
            registration = {
                "protocol": PROTOCOL,
                "generatedAt": utc_now(),
                "adapters": [
                    active[key].public_record() for key in sorted(active)
                ],
            }
            print(json.dumps(registration, ensure_ascii=False, indent=2))
            return 0
        if args.command == "probe":
            if args.adapter and args.adapter not in active:
                raise RuntimeFailure(f"Adapter is not enabled: {args.adapter}")
            selected = [args.adapter] if args.adapter else sorted(active)
            print(
                json.dumps(
                    [probe_adapter(active[key]) for key in selected],
                    ensure_ascii=False,
                    indent=2,
                )
            )
            return 0
        if args.command == "snapshot":
            if args.adapter and args.adapter not in active:
                raise RuntimeFailure(f"Adapter is not enabled: {args.adapter}")
            selected = [args.adapter] if args.adapter else sorted(active)
            print(
                json.dumps(
                    [snapshot_adapter(active[key]) for key in selected],
                    ensure_ascii=False,
                    indent=2,
                )
            )
            return 0
        if args.command == "run":
            timing_values = (args.timeout, args.poll_interval)
            if not all(math.isfinite(value) and value > 0 for value in timing_values):
                raise RuntimeFailure("timeout and poll-interval must be positive finite numbers")
            result = JobRuntime(sdk_home, outbox).run(
                active,
                load_job(args.job),
                args.adapter,
                args.timeout,
                args.poll_interval,
            )
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0 if result.get("state") == "SUCCEEDED" else 3
        raise RuntimeFailure(f"Unknown command: {args.command}")
    except RuntimeFailure as exc:
        print(
            json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False),
            file=sys.stderr,
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
