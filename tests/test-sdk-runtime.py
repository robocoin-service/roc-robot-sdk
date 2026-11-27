import base64
import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SDK = ROOT / "roc-robot-tpm-sdk.sh"
TOKEN = "offline-test-token"


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "sdk"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, command in (("lscpu", "printf 'CPU(s): 1\\n'"),
                              ("tpm2_getcap", "exit 1")):
            command_path = bin_dir / name
            command_path.write_text(f"#!/bin/sh\n{command}\n")
            command_path.chmod(0o700)
        self.env = dict(os.environ, ROC_SDK_HOME=str(self.home),
                        ROC_ALLOW_SOFTWARE_IDENTITY="1", ROC_AGENT_INTERVAL_SECONDS="1",
                        PATH=f"{bin_dir}:{os.environ['PATH']}")

    def run_sdk(self, *args, check=True):
        return subprocess.run(["bash", str(SDK), *args], env=self.env,
                              capture_output=True, text=True, timeout=15, check=check)

    def test_manifest(self):
        self.assertIn("go2", self.run_sdk("check-adapter", str(ROOT / "adapters/go2")).stdout)
        manifest = json.loads((ROOT / "adapters/go2/adapter.json").read_text())
        manifest["entrypoint"] = "../outside.py"
        (self.root / "adapter.json").write_text(json.dumps(manifest))
        self.assertNotEqual(self.run_sdk("check-adapter", str(self.root), check=False).returncode, 0)

    def test_binding_and_heartbeat_are_distinct(self):
        runtime = self
        seen = threading.Event()
        test_errors = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def respond(self, data):
                body = json.dumps(data, indent=2).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def verify(self, payload, public_key):
                for filename, content in (("key.pem", public_key.encode()),
                                          ("payload.txt", payload["signaturePayload"].encode()),
                                          ("signature.bin", base64.b64decode(payload["signature"], validate=True))):
                    (runtime.root / filename).write_bytes(content)
                subprocess.run(["openssl", "dgst", "-sha256", "-verify", "key.pem",
                                "-signature", "signature.bin", "payload.txt"],
                               cwd=runtime.root, check=True, capture_output=True)

            def do_GET(self):
                self.respond({"code": 200, "data": {"hasChallenge": False}})

            def do_POST(self):
                try:
                    data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    if self.path == "/user/robotSdkReport":
                        runtime.assertEqual(data["sdkBindingToken"], TOKEN)
                        self.verify(data, data["publicKeyPem"])
                        self.server.public_key = data["publicKeyPem"]
                        self.respond({"code": 200, "data": {
                            "robotId": 7, "bindingStatus": "BOUND", "signatureVerified": True}})
                    elif self.path == "/user/sdkAgent/heartbeat":
                        runtime.assertEqual(data["robotId"], 7)
                        self.verify(data, self.server.public_key)
                        self.respond({"code": 200, "data": {"robotId": 7, "signatureVerified": True}})
                        seen.set()
                    else:
                        raise AssertionError("unexpected request path")
                except Exception as error:
                    test_errors.append(error)
                    self.respond({"code": 500})
                    seen.set()

        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                url = f"http://127.0.0.1:{server.server_port}"
                self.assertFalse(self.home.exists())
                self.assertEqual(json.loads(self.run_sdk("doctor", "--json").stdout)["binding"], "not_bound")
                self.assertFalse(self.home.exists())
                bind = self.run_sdk("bind", TOKEN, url)
                self.assertNotIn(TOKEN, bind.stdout)
                self.assertFalse((self.home / "output" / "device-report.json").exists())
                self.assertEqual(list((self.home / "tpm").glob("session.*")), [])
                self.assertEqual(json.loads(self.run_sdk("doctor", "--json").stdout)["heartbeat"], "not_seen")
                with subprocess.Popen(["bash", str(SDK), "agent", "7", url], env=self.env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as agent:
                    try:
                        self.assertTrue(seen.wait(12), "no heartbeat received")
                        self.assertEqual(test_errors, [])
                        beat = self.home / "output" / "heartbeat-server-response.json"
                        for _ in range(10):
                            if beat.exists():
                                break
                            seen.clear()
                            seen.wait(0.1)
                        status = json.loads(self.run_sdk("doctor", "--json").stdout)
                        self.assertEqual(status["heartbeat"], "verified_recently")
                        self.assertEqual(set(status), {"binding", "heartbeat", "sdkVersion"})
                    finally:
                        agent.terminate()
                        agent.wait(timeout=10)
                beat.write_text(json.dumps({"code": 200, "data": {"robotId": 70, "signatureVerified": True}}))
                self.assertEqual(json.loads(self.run_sdk("doctor", "--json").stdout)["heartbeat"], "not_verified")
                before = time.time() - 120
                os.utime(beat, (before, before))
                self.assertEqual(json.loads(self.run_sdk("doctor", "--json").stdout)["heartbeat"], "stale")
            finally:
                server.shutdown()
                thread.join(timeout=5)

    def test_agent_recovers_and_signs_stage_challenge(self):
        runtime = self
        accepted = threading.Event()
        stage_reports = []
        errors = []
        payload = "verificationId=83;orderId=13;taskId=29;robotId=7;stage=START;nonce=testing\n"
        challenge = dict(hasChallenge=True, verificationId=83, orderId=13, taskId=29,
                         robotId=7, stage="START", nonce="testing", challengePayload=payload)

        class Handler(BaseHTTPRequestHandler):
            polls = 0

            def log_message(self, *_):
                pass

            def respond(self, data):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(data).encode())

            def do_GET(self):
                Handler.polls += 1
                self.respond({"code": 200, "data": {
                    1: {"hasChallenge": True},
                    2: dict(challenge, robotId=8),
                    3: challenge,
                    4: challenge,
                }.get(Handler.polls, {"hasChallenge": False})})

            def do_POST(self):
                try:
                    data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    if self.path == "/user/sdkAgent/heartbeat":
                        self.respond({"code": 200, "data": {"robotId": 7, "signatureVerified": True}})
                        return
                    runtime.assertEqual(self.path, "/user/sdkStageReport")
                    stage_reports.append(data)
                    check = runtime.root / "stage-test"
                    check.write_bytes(payload.encode())
                    signature = runtime.root / "signature"
                    signature.write_bytes(base64.b64decode(data["signature"], validate=True))
                    subprocess.run(["openssl", "dgst", "-sha256", "-verify",
                                    str(runtime.home / "tpm/robocoin-software-signing-public.pem"),
                                    "-signature", str(signature), str(check)], check=True, capture_output=True)
                    runtime.assertEqual(data["signaturePayload"], payload)
                    for key in ("robotId", "verificationId", "orderId", "taskId", "stage", "nonce"):
                        runtime.assertEqual(data[key], challenge[key])
                    if len(stage_reports) == 1:
                        self.respond({"code": 503})
                        return
                    self.respond({"code": 200, "data": {"verificationId": 83, "signatureVerified": True}})
                    accepted.set()
                except Exception as error:
                    errors.append(error)
                    self.respond({"code": 500})
                    accepted.set()

        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                url = f"http://127.0.0.1:{server.server_port}"
                with subprocess.Popen(["bash", str(SDK), "agent", "7", url], env=self.env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as agent:
                    try:
                        self.assertTrue(accepted.wait(9), f"no accepted stage after {Handler.polls} polls; agent exit={agent.poll()}")
                        self.assertEqual(errors, [])
                        self.assertEqual(len(stage_reports), 2)
                        self.assertIsNone(agent.poll())
                    finally:
                        agent.terminate()
                        agent.wait(timeout=10)
            finally:
                server.shutdown()
                thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
