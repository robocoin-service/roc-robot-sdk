#!/usr/bin/env python3
"""Hardware-free reference implementation of the ROC JSON Lines protocol."""

import json
import math
import sys
import time


PROTOCOL = "roc.adapter.jsonl.v1"
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
    value = {
        "protocol": PROTOCOL,
        "requestId": request.get("requestId"),
        "ok": ok,
        **payload,
    }
    print(json.dumps(value, ensure_ascii=False), flush=True)


def refresh_state():
    if current_job and current_job["state"] == "RUNNING":
        if time.monotonic() >= current_job["deadline"]:
            current_job["state"] = "SUCCEEDED"
    return current_job["state"] if current_job else "IDLE"


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
            adapter={"id": "mock-wheel", "version": "1.0.0"},
        )
        return
    if message_type == "telemetry.get":
        respond(
            request,
            telemetry={
                "batteryPercent": 100,
                "motionState": refresh_state(),
                "pose": {"x": 0.0, "y": 0.0, "yaw": 0.0},
                "simulated": True,
            },
        )
        return
    if message_type == "incidents.get":
        respond(request, incidents=[])
        return
    if message_type == "job.start":
        job = request.get("job") or {}
        job_id = job.get("id")
        job_type = str(job.get("type") or "").upper()
        required = set(job.get("requiredCapabilities") or [])
        if not job_id or job_type not in JOB_TYPES:
            respond(request, False, error="Unsupported or invalid job")
            return
        if not required.issubset(CAPABILITIES):
            respond(request, False, error="Required capability is not available")
            return
        if current_job and refresh_state() == "RUNNING":
            respond(request, False, error="Another job is already running")
            return
        duration = 0.0
        if job_type != "STOP":
            duration = float((job.get("parameters") or {}).get("durationSeconds", 0.2))
            if not math.isfinite(duration):
                raise ValueError("durationSeconds must be finite")
            duration = max(0.01, min(duration, 30.0))
        current_job = {
            "id": job_id,
            "type": job_type,
            "state": "SUCCEEDED" if job_type == "STOP" else "RUNNING",
            "deadline": time.monotonic() + duration,
        }
        respond(
            request,
            state=current_job["state"],
            data={"simulated": True, "jobType": job_type},
        )
        return
    if message_type == "job.status":
        if not current_job or request.get("jobId") != current_job["id"]:
            respond(request, False, error="Job not found")
            return
        respond(
            request,
            state=refresh_state(),
            data={"simulated": True, "jobType": current_job["type"]},
        )
        return
    if message_type == "job.cancel":
        if not current_job or request.get("jobId") != current_job["id"]:
            respond(request, False, error="Job not found")
            return
        current_job["state"] = "CANCELLED"
        respond(request, state="CANCELLED", data={"simulated": True})
        return
    respond(request, False, error=f"Unsupported message type: {message_type}")


for line in sys.stdin:
    request_value = {}
    try:
        request_value = json.loads(line)
        if not isinstance(request_value, dict):
            raise ValueError("request must be an object")
        handle(request_value)
    except Exception as exc:
        respond(request_value, False, error=str(exc))
