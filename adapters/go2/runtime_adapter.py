#!/usr/bin/env python3
"""Translate standard ROC jobs to the existing local Go2 HTTP bridge."""

import json
import math
import os
import sys
import urllib.error
import urllib.request


PROTOCOL = "roc.adapter.jsonl.v1"
BRIDGE_URL = os.environ.get("ROC_GO2_BRIDGE_URL", "http://127.0.0.1:8080").rstrip("/")
CAPABILITIES = [
    "incident.status",
    "job.cancel",
    "motion.linear",
    "navigation.obstacle-avoidance",
    "patrol",
    "status.robot",
    "telemetry.basic",
]
JOB_TYPES = ["DELIVERY", "INSPECTION", "PATROL", "STOP"]
current_job = None


def respond(request, ok=True, **payload):
    print(
        json.dumps(
            {
                "protocol": PROTOCOL,
                "requestId": request.get("requestId"),
                "ok": ok,
                **payload,
            },
            ensure_ascii=False,
        ),
        flush=True,
    )


def bridge_request(path, payload=None):
    body = None
    method = "GET"
    headers = {}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        method = "POST"
        headers["Content-Type"] = "application/json; charset=utf-8"
    request = urllib.request.Request(
        BRIDGE_URL + path, data=body, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as result:
            value = json.loads(result.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Go2 bridge request failed: {exc}") from exc
    if not isinstance(value, dict):
        raise RuntimeError("Go2 bridge returned a non-object response")
    if value.get("code") not in (None, 200):
        raise RuntimeError(str(value.get("message") or value))
    return value


def bounded_parameter(parameters, name, default, minimum, maximum):
    try:
        value = float(parameters.get(name, default))
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be a number") from exc
    if not math.isfinite(value):
        raise ValueError(f"{name} must be finite")
    return max(minimum, min(value, maximum))


def stop_active_job():
    global current_job
    if not current_job or current_job.get("state") != "RUNNING":
        return
    bridge_request("/api/v1/cancel", {})
    current_job["state"] = "CANCELLED"


def map_bridge_state(value):
    raw_state = str(value.get("status") or value.get("state") or "").upper()
    if raw_state in {"ACTION_RUNNING", "RUNNING", "STARTING"}:
        return "RUNNING"
    if raw_state in {"ERROR", "FAILED"}:
        return "FAILED"
    if raw_state in {"ACTION_DONE", "DONE", "SUCCEEDED", "IDLE"}:
        return "SUCCEEDED"
    return "RUNNING"


def handle(request):
    global current_job
    if request.get("protocol") != PROTOCOL:
        respond(request, False, error="Unsupported protocol")
        return
    message_type = request.get("type")
    if message_type == "capabilities.get":
        respond(
            request,
            capabilities=CAPABILITIES,
            jobTypes=JOB_TYPES,
            adapter={"id": "go2", "version": "1.1.0"},
        )
        return
    if message_type == "telemetry.get":
        status = bridge_request("/api/v1/status")
        respond(
            request,
            telemetry={
                "batteryPercent": status.get("battery"),
                "motionState": map_bridge_state(status),
                "pose": status.get("current_pose"),
                "controllerReady": status.get("sdk2_initialized"),
            },
        )
        return
    if message_type == "incidents.get":
        status = bridge_request("/api/v1/status")
        incidents = []
        if str(status.get("status") or "").upper() in {"ERROR", "FAILED"}:
            incidents.append(
                {
                    "code": "CONTROLLER_ERROR",
                    "severity": "ERROR",
                    "message": str(status.get("error") or "Go2 controller error"),
                }
            )
        respond(request, incidents=incidents)
        return
    if message_type == "job.start":
        job = request.get("job") or {}
        job_id = job.get("id")
        job_type = str(job.get("type") or "").upper()
        required = set(job.get("requiredCapabilities") or [])
        if not job_id or job_type not in JOB_TYPES:
            respond(request, False, error="Unsupported or invalid Go2 job")
            return
        if not required.issubset(CAPABILITIES):
            respond(request, False, error="Required capability is not available")
            return
        if job_type != "STOP" and current_job and current_job.get("state") == "RUNNING":
            respond(request, False, error="Another job is already running")
            return

        parameters = job.get("parameters") or {}
        if job_type == "STOP":
            bridge_request("/api/v1/cancel", {})
            state = "SUCCEEDED"
        elif job_type == "DELIVERY":
            bridge_request(
                "/api/v1/action",
                {
                    "action": "NAVIGATE_FORWARD_AVOID",
                    "meters": bounded_parameter(parameters, "distanceMeters", 1.0, 0.1, 60.0),
                },
            )
            state = "RUNNING"
        else:
            bridge_request(
                "/api/v1/action",
                {
                    "action": "PATROL_INSPECTION",
                    "meters": bounded_parameter(parameters, "distanceMeters", 10.0, 0.5, 20.0),
                    "seconds": bounded_parameter(parameters, "turnSeconds", 9.0, 1.0, 12.0),
                },
            )
            state = "RUNNING"
        current_job = {"id": job_id, "type": job_type, "state": state}
        respond(
            request,
            state=state,
            data={"bridgeUrl": BRIDGE_URL, "jobType": job_type},
        )
        return
    if message_type == "job.status":
        if not current_job or request.get("jobId") != current_job["id"]:
            respond(request, False, error="Job not found")
            return
        bridge_status = {}
        if current_job["state"] == "RUNNING":
            bridge_status = bridge_request("/api/v1/status")
            current_job["state"] = map_bridge_state(bridge_status)
        respond(
            request,
            state=current_job["state"],
            data={"bridgeStatus": bridge_status},
        )
        return
    if message_type == "job.cancel":
        if not current_job or request.get("jobId") != current_job["id"]:
            respond(request, False, error="Job not found")
            return
        bridge_request("/api/v1/cancel", {})
        current_job["state"] = "CANCELLED"
        respond(request, state="CANCELLED", data={"bridgeUrl": BRIDGE_URL})
        return
    respond(request, False, error=f"Unsupported message type: {message_type}")


def main():
    try:
        for line in sys.stdin:
            request_value = {}
            try:
                request_value = json.loads(line)
                if not isinstance(request_value, dict):
                    raise ValueError("request must be an object")
                handle(request_value)
            except Exception as exc:
                respond(request_value, False, error=str(exc))
    finally:
        try:
            stop_active_job()
        except Exception as exc:
            print(
                f"Failed to stop active Go2 job during adapter shutdown: {exc}",
                file=sys.stderr,
            )


if __name__ == "__main__":
    main()
