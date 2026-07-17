#!/usr/bin/env python3
import argparse
import json
import logging
import math
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(
    level=logging.INFO,
    format='[Go2 Bridge] %(asctime)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger('go2_bridge')

parser = argparse.ArgumentParser(description='Unitree Go2 & DeRAS SDK Local Bridge')
parser.add_argument('--server', type=str, default='http://172.16.18.187:8090', help='Real DeRAS Server URL')
parser.add_argument('--host', type=str, default='0.0.0.0', help='Bridge listen host')
parser.add_argument('--port', type=int, default=8080, help='Bridge listen port')
parser.add_argument('--mock', action='store_true', default=False, help='Enable mock mode')
parser.add_argument('--network', type=str, default=os.environ.get('ROC_GO2_NETWORK', 'eth0'), help='Network interface connected to Go2')
args, unknown = parser.parse_known_args()

REAL_SERVER_URL = args.server.rstrip('/')
NETWORK_INTERFACE = args.network
TINY_MOVE_BIN = '/home/unitree/go2_tiny_move/build/go2_tiny_move'
TINY_MOVE_LD = '/home/unitree/Downloads/sdk/unitree_sdk2/thirdparty/lib/aarch64:/home/unitree/Downloads/sdk/unitree_sdk2/lib/aarch64'
SDK_ACTION_HELPER_BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'go2_helper', 'build', 'go2_action_helper')


class RobotExecutor:
    def __init__(self, mock=False):
        self.mock = mock
        self.state = 'IDLE'
        self.error_msg = ''
        self.current_pose = {'x': 0.0, 'y': 0.0, 'yaw': 0.0}
        self.target_pose = None
        self.battery = 100
        self.sport_client = None
        self.sdk2_initialized = False
        self._motion_process_lock = threading.Lock()
        self._active_motion_process = None
        self._linear_motion_pending = False
        self._cancel_requested = threading.Event()
        if not self.mock:
            self._init_unitree_sdk2()

    def _init_unitree_sdk2(self):
        try:
            logger.info('Initializing unitree_sdk2py on interface: %s', NETWORK_INTERFACE)
            from unitree_sdk2py.core.channel import ChannelFactoryInitialize
            from unitree_sdk2py.go2.sport.sport_client import SportClient
            ChannelFactoryInitialize(0, NETWORK_INTERFACE)
            self.sport_client = SportClient()
            self.sport_client.SetTimeout(10.0)
            self.sport_client.Init()
            self.sdk2_initialized = True
            logger.info('Unitree SportClient initialized')
        except Exception as exc:
            self.sdk2_initialized = False
            self.error_msg = 'Unitree SDK init failed: %s' % exc
            logger.exception(self.error_msg)

    def _call_sport_method(self, names):
        for name in names:
            method = getattr(self.sport_client, name, None)
            if callable(method):
                logger.info('Calling SportClient.%s()', name)
                code = method()
                logger.info('SportClient.%s() returned code=%s', name, code)
                if code not in (0, None):
                    raise RuntimeError('SportClient.%s returned code=%s' % (name, code))
                return code
        raise AttributeError('None of SportClient methods exist: %s' % names)

    def _call_sport_method_isolated(self, names, tolerate_sigsegv=False):
        script = """
import json
import os
from unitree_sdk2py.core.channel import ChannelFactoryInitialize
from unitree_sdk2py.go2.sport.sport_client import SportClient
network = os.environ.get('ROC_GO2_NETWORK', 'eth0')
names = json.loads(os.environ.get('ROC_GO2_METHODS', '[]'))
ChannelFactoryInitialize(0, network)
client = SportClient()
client.SetTimeout(10.0)
client.Init()
for name in names:
    method = getattr(client, name, None)
    if callable(method):
        print('Calling SportClient.%s()' % name, flush=True)
        code = method()
        print('RESULT SportClient.%s code=%s' % (name, code), flush=True)
        if code not in (0, None):
            raise RuntimeError('SportClient.%s returned code=%s' % (name, code))
        print('DONE', flush=True)
        break
else:
    raise AttributeError('None of SportClient methods exist: %s' % names)
"""
        env = dict(os.environ)
        env['ROC_GO2_NETWORK'] = NETWORK_INTERFACE
        env['ROC_GO2_METHODS'] = json.dumps(names)
        result = subprocess.run([sys.executable, '-c', script], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=20)
        if result.returncode == 0:
            return result.stdout
        if tolerate_sigsegv and result.returncode == -11:
            raise RuntimeError('SportClient process crashed before action result: %s' % result.stdout)
        raise RuntimeError('SportClient method process failed rc=%s output=%s' % (result.returncode, result.stdout))

    def _run_named_action(self, action):
        helper = SDK_ACTION_HELPER_BIN if os.path.isfile(SDK_ACTION_HELPER_BIN) else TINY_MOVE_BIN
        if not os.path.isfile(helper):
            raise RuntimeError('Go2 C++ action helper is missing: %s' % helper)
        env = dict(os.environ)
        env['LD_LIBRARY_PATH'] = TINY_MOVE_LD

        def run_once(named_action):
            cmd = [helper, NETWORK_INTERFACE, named_action]
            logger.info('Running verified C++ named action: %s', ' '.join(cmd))
            return subprocess.run(
                cmd, cwd=os.path.dirname(helper), env=env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30
            )

        if action in ('heart', 'dance1', 'dance2'):
            stand_result = run_once('stand_up')
            if stand_result.returncode == 0:
                time.sleep(1.0)
            else:
                logger.warning('Go2 stand preflight failed before %s: %s', action, stand_result.stdout)

        result = run_once(action)
        if result.returncode != 0 and 'code=3104' in result.stdout and action in ('heart', 'dance1', 'dance2'):
            logger.warning('Go2 action %s timed out; recovering stand state before one retry', action)
            stand_result = run_once('stand_up')
            if stand_result.returncode == 0:
                time.sleep(1.5)
                result = run_once(action)
        if result.returncode != 0:
            raise RuntimeError('Go2 named action failed rc=%s output=%s' % (result.returncode, result.stdout))
        return result.stdout

    def _run_tiny_motion(self, vx, vy, vyaw, duration_ms):
        env = dict(os.environ)
        env['LD_LIBRARY_PATH'] = TINY_MOVE_LD
        helper = SDK_ACTION_HELPER_BIN if os.path.isfile(SDK_ACTION_HELPER_BIN) else TINY_MOVE_BIN
        if not os.path.isfile(helper):
            raise RuntimeError('Go2 C++ action helper is missing: %s' % helper)
        cmd = [helper, NETWORK_INTERFACE, str(vx), str(vy), str(vyaw), str(int(duration_ms))]
        logger.info('Running verified C++ motion helper: %s', ' '.join(cmd))
        process = subprocess.Popen(
            cmd, cwd=os.path.dirname(helper), env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        if duration_ms > 0:
            with self._motion_process_lock:
                self._active_motion_process = process
        try:
            try:
                output, _ = process.communicate(timeout=max(8, int(duration_ms / 1000) + 5))
            except subprocess.TimeoutExpired as exc:
                process.terminate()
                try:
                    output, _ = process.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    output, _ = process.communicate(timeout=3)
                raise RuntimeError('Go2 motion helper timed out: %s' % (output or exc.output or ''))
        finally:
            with self._motion_process_lock:
                if self._active_motion_process is process:
                    self._active_motion_process = None
        if process.returncode != 0:
            raise RuntimeError('go2_tiny_move failed rc=%s output=%s' % (process.returncode, output))
        return output

    def _terminate_active_motion(self):
        with self._motion_process_lock:
            process = self._active_motion_process
        if process is None or process.poll() is not None:
            return
        logger.warning('Terminating active Go2 motion process pid=%s', process.pid)
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)

    def _motion_is_active(self):
        with self._motion_process_lock:
            process = self._active_motion_process
            return self._linear_motion_pending or (process is not None and process.poll() is None)

    def _queue_linear_motion(self, action, distance, seconds):
        self._cancel_requested.clear()
        with self._motion_process_lock:
            process = self._active_motion_process
            if self._linear_motion_pending or (process is not None and process.poll() is None):
                return False
            self._linear_motion_pending = True
        try:
            threading.Thread(
                target=self._run_linear_motion,
                args=(action, distance, seconds),
                daemon=True,
            ).start()
            return True
        except Exception:
            with self._motion_process_lock:
                self._linear_motion_pending = False
            raise

    def _run_linear_motion(self, action, distance, seconds):
        try:
            self.state = 'ACTION_RUNNING'
            self.error_msg = ''
            if self._cancel_requested.is_set():
                self.state = 'ACTION_DONE'
                return
            speed = 0.30 if distance > 10.0 else 0.18
            duration_ms = int((float(seconds) * 1000) if seconds else (distance / speed * 1000))
            duration_ms = max(100, min(duration_ms, 240000))
            if self.mock:
                time.sleep(min(duration_ms / 1000.0, 2.0))
                output = 'mock linear motion'
            else:
                vx = speed if action == 'move_forward' else -speed
                output = self._run_tiny_motion(vx, 0.0, 0.0, duration_ms)
            if self._cancel_requested.is_set():
                logger.info('Go2 linear motion stopped by request')
            else:
                logger.info('Go2 linear motion completed: %s', output)
            self.state = 'ACTION_DONE'
            self.error_msg = ''
        except Exception as exc:
            if self._cancel_requested.is_set():
                self.state = 'ACTION_DONE'
                self.error_msg = ''
                logger.info('Go2 linear motion stopped by request')
            else:
                self.state = 'ERROR'
                self.error_msg = 'Go2 linear motion failed: %s' % exc
                logger.exception(self.error_msg)
                try:
                    self._stop_sport_motion()
                except Exception:
                    pass
        finally:
            with self._motion_process_lock:
                self._linear_motion_pending = False

    def _stop_sport_motion(self):
        if not self.mock:
            self._cancel_requested.set()
            self._terminate_active_motion()
            return self._run_tiny_motion(0.0, 0.0, 0.0, 0)

    def _run_patrol_helper(self, distance, turn_seconds):
        helper = SDK_ACTION_HELPER_BIN if os.path.isfile(SDK_ACTION_HELPER_BIN) else TINY_MOVE_BIN
        if not os.path.isfile(helper):
            raise RuntimeError('Go2 C++ action helper is missing: %s' % helper)
        env = dict(os.environ)
        env['LD_LIBRARY_PATH'] = TINY_MOVE_LD
        cmd = [helper, NETWORK_INTERFACE, 'patrol', str(distance), str(turn_seconds)]
        logger.info('Running continuous C++ patrol: %s', ' '.join(cmd))
        process = subprocess.Popen(
            cmd, cwd=os.path.dirname(helper), env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        with self._motion_process_lock:
            self._active_motion_process = process
        try:
            try:
                output, _ = process.communicate(timeout=180)
            except subprocess.TimeoutExpired as exc:
                process.terminate()
                try:
                    output, _ = process.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    output, _ = process.communicate(timeout=3)
                raise RuntimeError('Go2 patrol helper timed out: %s' % (output or exc.output or ''))
        finally:
            with self._motion_process_lock:
                if self._active_motion_process is process:
                    self._active_motion_process = None
        if self._cancel_requested.is_set():
            raise RuntimeError('Go2 patrol was cancelled')
        if process.returncode != 0:
            raise RuntimeError('Go2 patrol helper failed rc=%s output=%s' % (process.returncode, output))
        logger.info('Go2 patrol completed: %s', output)
        return output

    def _run_patrol_inspection(self, distance, turn_seconds):
        try:
            self.state = 'ACTION_RUNNING'
            self.error_msg = ''
            self._cancel_requested.clear()
            patrol_distance = max(0.5, min(float(distance or 10.0), 20.0))
            patrol_turn_seconds = max(1.0, min(float(turn_seconds or 9.0), 12.0))
            self._run_patrol_helper(patrol_distance, patrol_turn_seconds)
            self.state = 'ACTION_DONE'
        except Exception as exc:
            if self._cancel_requested.is_set():
                self.state = 'ACTION_DONE'
                self.error_msg = ''
                logger.info('Go2 patrol stopped by request')
                return
            self.state = 'ERROR'
            self.error_msg = 'Go2 patrol inspection failed: %s' % exc
            logger.exception(self.error_msg)
            try:
                self._stop_sport_motion()
            except Exception:
                pass

    def execute_action(self, action, meters=None, seconds=None, yaw_rate=None):
        action_key = (action or '').strip().upper()
        supported = {
            'DANCE': 'dance1',
            'DANCE_1': 'dance1',
            'DANCE1': 'dance1',
            'DANCE_2': 'dance2',
            'DANCE2': 'dance2',
            'MOVE_FORWARD': 'move_forward',
            'FORWARD': 'move_forward',
            'MOVE_BACKWARD': 'move_backward',
            'BACKWARD': 'move_backward',
            'TURN_AROUND': 'turn_around',
            'STOP': 'stop',
            'DAMP': 'stop',
            'STAND_UP': 'stand_up',
            'STAND': 'stand_up',
            'HEART': 'heart',
            'LOVE': 'heart',
            'PATROL_INSPECTION': 'patrol_inspection',
            'INSPECTION_PATROL': 'patrol_inspection',
        }
        normalized = supported.get(action_key)
        if not normalized:
            return {'code': 400, 'message': 'Unsupported Go2 action: %s' % action}

        self.state = 'ACTION_RUNNING'
        self.error_msg = ''
        logger.info('Executing action=%s meters=%s seconds=%s yawRate=%s', normalized, meters, seconds, yaw_rate)
        try:
            if self.mock:
                if normalized == 'stop':
                    self._cancel_requested.set()
                    self.state = 'ACTION_DONE'
                    return {'code': 200, 'message': 'Mock motion stopped', 'data': {'action': normalized}}
                if normalized in ('move_forward', 'move_backward'):
                    distance = max(0.1, min(float(meters or 1.0), 60.0))
                    if not self._queue_linear_motion(normalized, distance, seconds):
                        return {'code': 409, 'message': 'A Go2 motion action is already running'}
                    return {
                        'code': 200,
                        'message': 'Mock linear motion started',
                        'data': {'action': normalized, 'meters': distance},
                    }
                if normalized == 'patrol_inspection':
                    threading.Thread(target=self._run_patrol_inspection, args=(meters or 10.0, seconds or 9.0), daemon=True).start()
                    return {'code': 200, 'message': 'Mock patrol inspection started', 'data': {'action': normalized}}
                time.sleep(float(seconds or 2.0))
                self.state = 'ACTION_DONE'
                return {'code': 200, 'message': 'Mock action %s finished' % normalized, 'data': {'action': normalized}}

            if normalized == 'patrol_inspection':
                if self._motion_is_active():
                    self.state = 'ACTION_RUNNING'
                    return {'code': 409, 'message': 'A Go2 motion action is already running'}
                threading.Thread(target=self._run_patrol_inspection, args=(meters or 10.0, seconds or 9.0), daemon=True).start()
                return {'code': 200, 'message': 'Go2 patrol inspection started', 'data': {'action': normalized, 'meters': meters or 10.0, 'turnSeconds': seconds or 9.0}}
            if normalized == 'stop':
                output = self._stop_sport_motion()
            elif normalized in ('move_forward', 'move_backward'):
                distance = max(0.1, min(float(meters or 1.0), 60.0))
                if not self._queue_linear_motion(normalized, distance, seconds):
                    return {'code': 409, 'message': 'A Go2 motion action is already running'}
                return {
                    'code': 200,
                    'message': 'Go2 linear motion started',
                    'data': {'action': normalized, 'meters': distance},
                }
            elif normalized == 'turn_around':
                rate = max(0.1, min(float(yaw_rate or 0.8), 0.8))
                duration_ms = int((float(seconds) * 1000) if seconds else 4000)
                duration_ms = max(100, min(duration_ms, 12000))
                output = self._run_tiny_motion(0.0, 0.0, rate, duration_ms)
            elif normalized in ('stand_up', 'dance1', 'dance2', 'heart'):
                output = self._run_named_action(normalized)
            else:
                raise RuntimeError('No executor configured for Go2 action: %s' % normalized)

            self.state = 'ACTION_DONE'
            return {'code': 200, 'message': 'Go2 action %s finished' % normalized, 'data': {'action': normalized, 'output': output}}
        except Exception as exc:
            self.state = 'ERROR'
            self.error_msg = 'Go2 action failed: %s' % exc
            logger.exception(self.error_msg)
            try:
                self._stop_sport_motion()
            except Exception:
                pass
            return {'code': 500, 'message': self.error_msg}

    def status(self):
        return {
            'status': self.state,
            'current_pose': self.current_pose,
            'target_pose': self.target_pose,
            'battery': self.battery,
            'sdk2_initialized': self.sdk2_initialized,
            'network_interface': NETWORK_INTERFACE,
            'action_helper_ready': os.path.isfile(SDK_ACTION_HELPER_BIN) or os.path.isfile(TINY_MOVE_BIN),
            'motion_active': self._motion_is_active(),
            'error': self.error_msg,
        }


executor = RobotExecutor(mock=args.mock)


def json_bytes(payload):
    return json.dumps(payload, ensure_ascii=False).encode('utf-8')


class BridgeHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        logger.info('%s - %s', self.client_address[0], fmt % args)

    def _send_json(self, payload, status=200):
        body = json_bytes(payload)
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get('Content-Length') or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        if not raw:
            return {}
        return json.loads(raw.decode('utf-8'))

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == '/api/v1/status':
            self._send_json(executor.status())
            return
        self._proxy()

    def do_POST(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == '/api/v1/action':
            try:
                payload = self._read_json()
                result = executor.execute_action(
                    payload.get('action'),
                    meters=payload.get('meters'),
                    seconds=payload.get('seconds'),
                    yaw_rate=payload.get('yawRate'),
                )
                self._send_json(result, 200 if result.get('code') == 200 else 500)
            except Exception as exc:
                logger.exception('Action request failed')
                self._send_json({'code': 500, 'message': str(exc)}, 500)
            return
        if parsed.path == '/api/v1/cancel':
            executor.execute_action('STOP')
            self._send_json({'code': 200, 'message': 'Task cancelled and robot stopped'})
            return
        self._proxy()

    def do_PUT(self):
        self._proxy()

    def do_DELETE(self):
        self._proxy()

    def _proxy(self):
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length) if length else None
        target = REAL_SERVER_URL + self.path
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ('host', 'content-length', 'connection')}
        req = urllib.request.Request(target, data=body, headers=headers, method=self.command)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = resp.read()
                self.send_response(resp.getcode())
                content_type = resp.headers.get('Content-Type', 'application/json; charset=utf-8')
                self.send_header('Content-Type', content_type)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        except urllib.error.HTTPError as exc:
            data = exc.read()
            self.send_response(exc.code)
            self.send_header('Content-Type', exc.headers.get('Content-Type', 'application/json; charset=utf-8'))
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as exc:
            logger.exception('Proxy failed: %s', target)
            self._send_json({'code': 502, 'message': 'DeRAS Server unreachable: %s' % exc}, 502)


if __name__ == '__main__':
    server = ThreadingHTTPServer((args.host, args.port), BridgeHandler)
    logger.info('Go2 bridge listening on %s:%s, proxy=%s, network=%s', args.host, args.port, REAL_SERVER_URL, NETWORK_INTERFACE)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info('Go2 bridge stopped')
