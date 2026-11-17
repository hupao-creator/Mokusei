"""Serial preparation/execution adapters. No product instrumentation is required."""
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time
import uuid

from .engine import digest, identity, read, reference, require, sha, write

ROOT = Path(__file__).resolve().parents[3]
BENCHMARKS = ROOT / 'tools/benchmarks'


def utc():
    return datetime.now(timezone.utc).isoformat()


@contextmanager
def lease():
    # Never unlink a flock file: a new inode would permit concurrent holders.
    path = Path(tempfile.gettempdir()) / f'mokusei-performance-{os.getuid()}.lock'
    with path.open('a') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError('another performance campaign owns this host') from error
        yield


def command(argv, path, *, cwd=ROOT, timeout=120, env=None, graceful=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    receipt = {'argv': list(map(str, argv)), 'startedAt': utc(), 'exitCode': None}
    start = time.monotonic()
    process = None
    try:
        with path.open('w') as output, path.with_suffix('.stderr').open('w') as error:
            process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=output, stderr=error, start_new_session=True)
            receipt['exitCode'] = process.wait(timeout=timeout)
        require(receipt['exitCode'] == 0, f'command exit {receipt["exitCode"]}: {path.name}')
    except BaseException as error:
        receipt['error'] = type(error).__name__ + ': ' + str(error)
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGINT if graceful else signal.SIGTERM)
            try:
                process.wait(timeout=45 if graceful else 3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=3)
            receipt['exitCode'] = process.returncode
        raise
    finally:
        receipt.update(finishedAt=utc(), elapsedSeconds=time.monotonic() - start)
        write(path.with_suffix('.command.json'), receipt)


def observe(argv):
    completed = subprocess.run(argv, capture_output=True, text=True, timeout=20)
    require(completed.returncode == 0, 'environment observation failed: ' + str(argv))
    return completed.stdout.strip()


def phase(campaign, name):
    campaign['phases'].append({'phase': name, 'at': utc()})


def source_hash(paths):
    return identity({str(path.relative_to(ROOT)): digest(path) for path in sorted(paths)})


def row_identity(campaign, suite):
    return {'session': campaign['session'], 'harnessSHA256': campaign['harnessSHA256'],
            'suiteVersion': suite['version'], 'workload': suite['workload']}


def store_observation(output, campaign, suite, row):
    row['identity'] = row_identity(campaign, suite)
    observation = output / 'observations' / (row['id'] + '.json')
    write(observation, row)
    row = {**row, 'observation': str(observation.relative_to(output)), 'evidence': [reference(output, observation), *row['evidence']]}
    campaign['runs'].append(row)
    write(output / 'campaign.json', campaign)


def remaining(deadline, maximum):
    value = deadline - time.monotonic()
    require(value > 0, 'campaign budget exhausted')
    return min(value, maximum)


def checkout(revision, destination, output, deadline):
    archive = output / 'source.tar'
    command(['git', 'archive', '--format=tar', '-o', str(archive), revision, 'internal', 'go.mod', 'go.sum'], output / 'archive.log',
            timeout=remaining(deadline, 60))
    destination.mkdir()
    # Git archives are locally resolved commits. Reject special files and links
    # anyway so a product revision cannot escape its disposable checkout.
    with tarfile.open(archive) as stream:
        members = stream.getmembers()
        for item in members:
            require(not Path(item.name).is_absolute() and '..' not in Path(item.name).parts and
                    (item.isfile() or item.isdir()), 'unsupported archive entry: ' + item.name)
        stream.extractall(destination, members=members)
    archive.unlink()


def runtime(output, campaign, suite, deadline, go):
    workload = suite['workload']
    require(set(workload) == {'records', 'iterations', 'warmup', 'samples', 'gomaxprocs'}, 'unknown Runtime workload')
    require(workload['samples'] == 1, 'independent process pairs require samples=1')
    for key, value in workload.items():
        require(type(value) is int and (value >= 0 if key == 'warmup' else value > 0), 'invalid Runtime workload')
    paths = list((ROOT / 'tools/verification/runtime-performance').rglob('*.go'))
    campaign['harnessSHA256'] = source_hash(paths)
    environment = {**os.environ, 'CGO_ENABLED': '1', 'GOTOOLCHAIN': 'local', 'GOFLAGS': '-mod=readonly',
                   'GOMAXPROCS': str(workload['gomaxprocs'])}
    # An owned temporary root also contains any fixture remnants after timeout.
    with tempfile.TemporaryDirectory(prefix='mokusei-perf-') as temporary:
        work = Path(temporary)
        environment['TMPDIR'] = str(work)
        binaries = {}
        for side, subject in campaign['subjects'].items():
            build = output / 'builds' / side
            checkout(subject['revision'], work / side, build, deadline)
            for path in paths:
                target = work / side / path.relative_to(ROOT)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
            binary = work / (side + '-benchmark')
            command([go, 'build', '-trimpath', '-o', str(binary), './tools/verification/runtime-performance'],
                    build / 'build.log', cwd=work / side, timeout=remaining(deadline, 300), env=environment)
            subject['artifactSHA256'] = digest(binary)
            binaries[side] = binary
        phase(campaign, 'execute')
        for pair in range(suite['pairCount']):
            order = 'AB' if pair % 2 == 0 else 'BA'
            scenarios = suite['scenarios'] if pair % 2 == 0 else list(reversed(suite['scenarios']))
            for scenario in scenarios:
                for letter in order:
                    side = 'baseline' if letter == 'A' else 'candidate'
                    run_id = f'{pair:02d}-{scenario}-{side}'
                    raw = output / 'raw' / (run_id + '.json')
                    command([str(binaries[side]), '-scenario', scenario, '-records', str(workload['records']),
                             '-iterations', str(workload['iterations']), '-samples', '1', '-warmup', str(workload['warmup']),
                             '-label', campaign['subjects'][side]['revision']], raw,
                            timeout=remaining(deadline, suite['processSeconds']), env=environment)
                    value = read(raw)
                    require(value['scenario'] == scenario and value['records'] == workload['records'] and
                            value['warmupOperations'] == workload['warmup'] and value['gomaxprocs'] == workload['gomaxprocs'] and
                            value['profiled'] is False and len(value['measurements']) == 1 and
                            value['measurements'][0]['operations'] == workload['iterations'] and
                            value['executableSHA256'] == campaign['subjects'][side]['artifactSHA256'], 'Runtime result identity mismatch')
                    values = value['measurements'][0]
                    comparison = {k: value[k] for k in ('goos', 'goarch', 'goVersion', 'gomaxprocs', 'records', 'warmupOperations', 'profiled')}
                    store_observation(output, campaign, suite, {
                        'id': run_id, 'scenario': scenario, 'pair': pair, 'order': order, 'side': side,
                        'validity': 'valid', 'product': 'passed', 'reasons': [],
                        'artifactSHA256': value['executableSHA256'], 'comparison': comparison,
                        'metrics': {name: values[name] for name in suite['metrics']}, 'evidence': [reference(output, raw)]})


def overview(output, campaign, suite, deadline, configure_display):
    raw_dir = output / 'overview'
    argv = [os.sys.executable, str(ROOT / 'tools/verification/overview-ci-performance/run.py'),
            '--baseline', campaign['subjects']['baseline']['revision'], '--candidate', campaign['subjects']['candidate']['revision'],
            '--output', str(raw_dir), '--time-budget-seconds', str(int(remaining(deadline, suite['budgetSeconds'])))]
    if configure_display:
        argv.append('--configure-display')
    phase(campaign, 'execute')
    # The nested Overview runner owns its native flock; the outer atomic GUI
    # lease coordinates the independent e2e workstream without double locking.
    from .ux import ui_lease
    with ui_lease():
        command(argv, output / 'overview-command.log', timeout=remaining(deadline, suite['budgetSeconds']) + 60, graceful=True)
    raw = read(raw_dir / 'report.json')
    require(raw['status'] == 'completed' and not raw['errors'], 'Overview collection/cleanup failed')
    campaign['harnessSHA256'] = raw['harness']['sha256']
    for letter, side in (('A', 'baseline'), ('B', 'candidate')):
        build = raw['builds'][letter]
        require(build['product']['revision'] == campaign['subjects'][side]['revision'], 'Overview product SHA differs')
        campaign['subjects'][side]['artifactSHA256'] = identity({k: build[k] for k in ('probeSHA256', 'runtimeSHA256')})
    for item in raw['runs']:
        result = item['result']
        require(item['valid'] is True, 'Overview observation invalid')
        side = 'baseline' if item['side'] == 'A' else 'candidate'
        store_observation(output, campaign, suite, {
            'id': item['id'], 'scenario': item['condition'], 'pair': item['repetition'] * 2 + (item['order'] == 'BA'),
            'order': item['order'], 'side': side, 'validity': 'valid', 'product': 'passed', 'reasons': [],
            'artifactSHA256': campaign['subjects'][side]['artifactSHA256'],
            'comparison': {'fixture': result['comparisonIdentity'], 'power': item['powerBefore']},
            'metrics': {'uiCPUPercent': result['ui']['cpuPercent'], 'coreCPUPercent': result['core']['cpu']['cpuPercent'],
                        'totalCPUPercent': result['ui']['cpuPercent'] + result['core']['cpu']['cpuPercent']},
            'evidence': [reference(output, raw_dir / 'report.json')]})


def run(output, catalog_path, suite_id, baseline, candidate, go, configure_display=False, options=None):
    policy = read(catalog_path)
    suite = policy['suites'][suite_id]
    shutil.copy2(catalog_path, output / 'catalog.json')
    campaign = {'schemaVersion': 1, 'kind': 'performance-campaign', 'suite': suite_id,
                'runId': str(uuid.uuid4()), 'policySHA256': digest(output / 'catalog.json'),
                'validity': 'incomplete', 'cleanup': 'unknown', 'reasons': [], 'runs': [], 'evidence': [],
                'subjects': {'baseline': {'revision': baseline}, 'candidate': {'revision': candidate}}, 'phases': []}
    campaign['analysisSHA256'] = digest(Path(__file__).with_name('engine.py'))
    phase(campaign, 'prepare')
    write(output / 'campaign.json', campaign)
    if suite['adapter'] == 'unsupported':
        campaign.update(validity='unsupported', reasons=[suite['reason']])
        write(output / 'campaign.json', campaign)
        return
    deadline = time.monotonic() + suite['budgetSeconds']
    try:
        with lease():
            document = (BENCHMARKS / suite['documentation']).resolve()
            require(document.is_relative_to(BENCHMARKS) and document.is_file(), 'suite documentation unavailable')
            content = document.read_text()
            require(all(name in content for name in [suite_id, *suite['scenarios'], *suite['metrics']]),
                    'suite/scenario/metric IDs must appear in the referenced current specification')
            shutil.copy2(document, output / 'specification.md')
            for value in (baseline, candidate):
                sha(value, 'product revision', 40)
                require(observe(['git', 'rev-parse', value + '^{commit}']) == value, 'product commit not available')
            toolchain = observe([go, 'version']) if suite['adapter'] != 'external' else 'collector toolchain pending preflight'
            hardware = observe(['sysctl', '-n', 'hw.model']) if platform.system() == 'Darwin' else observe(['uname', '-m'])
            campaign['session'] = {'id': campaign['runId'], 'runner': os.environ.get('RUNNER_NAME', platform.node()),
                                   'os': platform.platform(), 'architecture': platform.machine(), 'hardware': hardware,
                                   'toolchain': toolchain, 'mode': 'unprofiled-release'}
            write(output / 'campaign.json', campaign)
            if suite['adapter'] == 'runtime':
                runtime(output, campaign, suite, deadline, go)
            elif suite['adapter'] == 'external':
                from .ux import execute
                execute(output, campaign, suite, deadline, options)
            else:
                overview(output, campaign, suite, deadline, configure_display)
            phase(campaign, 'collect')
            campaign.update(validity='valid', cleanup='passed')
    except (Exception, KeyboardInterrupt) as error:
        from lifecycle import DesktopUnavailable
        unavailable = isinstance(error, DesktopUnavailable)
        campaign.update(validity='unsupported' if unavailable else 'invalid', reasons=[type(error).__name__ + ': ' + str(error)])
        if unavailable:
            campaign['cleanup'] = 'passed'  # Preflight failed before creating any owned GUI process.
        # Other exceptions can occur after process creation; context unwinding
        # alone does not certify cleanup for those incomplete attempts.
    finally:
        campaign['evidence'] = [reference(output, p) for p in sorted(output.rglob('*'))
                                if p.is_file() and p.relative_to(output).as_posix() not in ('campaign.json', 'catalog.json', 'report.json', 'report.md')]
        # Aggregate Overview report is input evidence, not this driver's output.
        phase(campaign, 'validate')
        write(output / 'campaign.json', campaign)
