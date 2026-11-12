"""External XCTest ownership and measurement lifecycle; no product launch."""
import json
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from lifecycle import native, save


class Hitches:
    def __init__(self, tools, bundle, pid, directory, expected_launch_date=None):
        self.directory = directory
        directory.mkdir(parents=True, exist_ok=True)
        self.owner = native(tools/'collector', 'inspect', pid)
        save(directory/'hitch-target.json', self.owner)
        self.done, self.finished, self.ready_record, self.batches = False, False, None, []
        config = {'app': str(bundle.resolve()), 'pid': pid,
                  'launchDate': self.owner['launchDate'] if expected_launch_date is None else expected_launch_date}
        if config['launchDate'] is None:
            raise ValueError('external metric requires an OS launch identity')
        save(directory/'hitch-config.json', config)
        token = secrets.token_hex(32)
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                if self.headers.get('Authorization') != token:
                    self.send_error(403); return
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 1024 * 1024:
                    self.send_error(400); return
                value = json.loads(self.rfile.read(length))
                answer = {}
                if self.path == '/config': answer = config
                elif self.path == '/status': answer = {'finished': owner.finished}
                elif self.path == '/ready':
                    owner.ready_record = value
                    save(directory/'hitch-ready.json', value)
                elif self.path == '/owner': save(directory/'hitch-owner.json', value)
                elif self.path == '/measurement':
                    owner.batches.append(value)
                    save(directory/f"hitch-{value['startNS']}.json", value)
                else:
                    self.send_error(404); return
                data = json.dumps(answer).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers()
                self.wfile.write(data)

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        envs = {'BENCH_HITCH_URL': f'http://127.0.0.1:{self.server.server_port}', 'BENCH_HITCH_TOKEN': token}
        original = next((tools/'HitchBuild/Build/Products').glob('Hitch_*.xctestrun'))
        configuration = plistlib.loads(original.read_bytes())
        for target in configuration.get('TestConfigurations', []):
            for test in target.get('TestTargets', []): test.setdefault('EnvironmentVariables', {}).update(envs)
        for value in configuration.values():
            if isinstance(value, dict) and value.get('TestBundlePath'): value.setdefault('EnvironmentVariables', {}).update(envs)
        self.testfile = original.parent / ('HitchRun-'+str(os.getpid())+'.xctestrun')
        self.testfile.write_bytes(plistlib.dumps(configuration))
        self.log = (directory/'hitch-xcodebuild.log').open('w')
        env = os.environ.copy(); env.update({'TEST_RUNNER_'+k:v for k,v in envs.items()})
        self.process = subprocess.Popen(['xcodebuild','test-without-building','-xctestrun',str(self.testfile),
            '-destination','platform=macOS,arch=arm64','-parallel-testing-enabled','NO',
            '-resultBundlePath',str(directory/'hitches.xcresult')],stdout=self.log,stderr=subprocess.STDOUT,env=env)

    def ready(self, timeout=60):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            if self.process.poll() is not None:
                raise RuntimeError('hitch target exited before ready; see '+str(self.directory/'hitch-xcodebuild.log'))
            if self.ready_record is not None: return self.ready_record
            time.sleep(.1)
        raise TimeoutError('external hitch collector readiness timeout')

    def finish(self):
        if self.done: return self.result
        self.finished = True
        try: status = self.process.wait(timeout=40)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try: status = self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill(); status = self.process.wait()
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.log.close(); self.testfile.unlink(missing_ok=True)
        self.result = {'version':1,'pid':self.owner['process']['pid'],'processIdentity':self.owner['process']['identity'],
            'launchDate':self.owner['launchDate'],'exitStatus':status,'batches':sorted(self.batches,key=lambda b:b['startNS']),
            'xcresult':'hitches.xcresult'}
        save(self.directory/'hitch.json',self.result)
        self.done = True
        return self.result
