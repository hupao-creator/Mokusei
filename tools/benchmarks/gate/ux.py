"""Narrow pixel/identified-App metrics over signed external collection.

Whole-task accounting remains incomplete. Only explicitly scoped, independently
calibrated observations can enter this adapter; unknown exclusions fail closed.
"""
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import uuid

from .engine import digest, identity, read, reference, require, sha, write
from .runner import BENCHMARKS, command, observe, phase, remaining, source_hash, store_observation, utc


def artifact(app, revision):
    app = app.resolve()
    sha(revision, 'declared artifact revision', 40)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    provenance = read(app / 'Contents/Resources/build-provenance.json')
    require(info.get('CFBundleIdentifier') == 'com.mokusei.desktop' and provenance.get('channel') == 'production'
            and provenance.get('configuration') == 'release', 'requires production Release artifact')
    result = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], capture_output=True, text=True, timeout=30)
    require(result.returncode == 0, 'artifact signature verification failed: ' + result.stderr)
    files = {str(p.relative_to(app)): digest(p) for p in sorted(app.rglob('*')) if p.is_file()}
    return {'schemaVersion': 1, 'kind': 'performance-artifact', 'revision': revision,
            'revisionBinding': 'operator-attested; bundle provenance does not contain a source revision',
            'app': str(app), 'artifactSHA256': identity(files), 'files': files, 'provenance': provenance}


@contextmanager
def ui_lease():
    # The atomic directory coordinates independent worktrees/agents. Never infer
    # that an existing owner is stale or replace it based on elapsed time.
    directory = Path('/private/tmp/mokusei-ui-verification.lock')
    owner = directory / 'owner.json'
    inherited = os.environ.get('MOKUSEI_UI_LEASE_TOKEN')
    if inherited and owner.exists():
        receipt = read(owner)
        if receipt.get('token') == inherited and receipt.get('pid') == os.getppid():
            yield
            return
    directory.mkdir()
    token = uuid.uuid4().hex
    previous = os.environ.get('MOKUSEI_UI_LEASE_TOKEN')
    previous_term = signal.getsignal(signal.SIGTERM)
    def interrupt(signum, frame):
        # Let subprocess/context-manager cleanup run before releasing the desktop.
        raise KeyboardInterrupt('desktop lease interrupted')
    try:
        thread = os.environ.get('MOKUSEI_VERIFICATION_THREAD_ID', os.environ.get('CODEX_THREAD_ID', 'performance-regression-gates'))
        write(owner, {'thread_id': thread, 'threadId': thread, 'pid': os.getpid(), 'start': utc(), 'token': token})
        signal.signal(signal.SIGTERM, interrupt)
        os.environ['MOKUSEI_UI_LEASE_TOKEN'] = token
        yield
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        if previous is None:
            os.environ.pop('MOKUSEI_UI_LEASE_TOKEN', None)
        else:
            os.environ['MOKUSEI_UI_LEASE_TOKEN'] = previous
        if owner.exists() and read(owner).get('token') == token:
            owner.unlink()
            directory.rmdir()


@contextmanager
def native_lease():
    with ui_lease():
        if os.environ.get('MOKUSEI_NATIVE_LEASE_PID') == str(os.getppid()):
            # Only the direct child of the atomic-directory owner inherits its
            # existing native flock. Arbitrary unrelated processes still block.
            owner = read(Path('/private/tmp/mokusei-ui-verification.lock/owner.json'))
            if owner.get('pid') == os.getppid() and owner.get('token') == os.environ.get('MOKUSEI_UI_LEASE_TOKEN'):
                yield
                return
        # Retain compatibility with the NativeReplay lease as well.
        with (Path(tempfile.gettempdir()) / f'mokusei-note-replay-{os.getuid()}.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            previous = os.environ.get('MOKUSEI_NATIVE_LEASE_PID')
            try:
                os.environ['MOKUSEI_NATIVE_LEASE_PID'] = str(os.getpid())
                yield
            finally:
                if previous is None:
                    os.environ.pop('MOKUSEI_NATIVE_LEASE_PID', None)
                else:
                    os.environ['MOKUSEI_NATIVE_LEASE_PID'] = previous


def scoped_metrics(case, suite):
    from analysis.report import analyze
    report = analyze(case)  # Revalidate sealed source/control evidence, not report booleans.
    allowed = {
        'process lifecycle/exit CPU coverage incomplete',
        'native hitch sensitivity/ownership controls did not establish capability',
        'reading scroll controls do not certify native hitch sensitivity or ownership',
    }
    # These metrics name optical bounds and the identified live App only. Missing
    # descendant/hitch accounting is outside this scope, never silently repaired.
    disallowed = [reason for reason in report['reasons'] if reason not in allowed and not reason.startswith('native hitch unavailable: ')]
    if suite['workload']['family'] == 'startup':
        disallowed = [r for r in disallowed if r not in (
            'startup pixels before window capture attachment are unobserved',
            'startup resource samples begin after OS launch attachment')]
    require(report['measurement'] != 'invalid' and report['product'] == 'passed' and not disallowed,
            'UX observation not established: ' + '; '.join(disallowed or [report['product']]))
    require(report.get('collectorCalibration', {}).get('pixelsPassed') is True, 'pixel controls did not pass')
    metrics = report['metrics']
    family = suite['workload']['family']
    if family == 'startup':
        app = metrics['startupApplication']
        values = {'firstContentSeconds': metrics['presentation']['firstContentSecondsBounds'],
                  'appCPUSeconds': app['cpuSecondsSinceProcessBirth'],
                  'appPeakFootprintBytes': app['sampledPeakFootprintBytes']}
    else:
        app = metrics['formal']['roles']['application']
        values = {'appCPUPercent': app['singleCoreCPUPercent'], 'appPeakFootprintBytes': app['sampledPeakFootprintBytes']}
        if family == 'reading':
            reading = metrics['reading']
            values['responseSeconds'] = {
                endpoint: max(s['firstVisibleResponseSeconds'][endpoint] for s in reading['scroll']) for endpoint in ('lower', 'upper')}
            values['noProgressSeconds'] = {
                endpoint: max(s['maximumObservedNoProgressSeconds'][endpoint] for s in reading['scroll']) for endpoint in ('lower', 'upper')}
            if 'firstContentSeconds' in suite['metrics']:
                values['firstContentSeconds'] = reading['presentation']['firstContentSeconds']
        else:
            values.update(responseSeconds=metrics['pan']['firstVisibleResponseSecondsBounds'],
                          noProgressSeconds=metrics['pan']['noProgressSecondsBounds'])
    return {name: values[name] for name in suite['metrics']}, report


def export_evidence(source, destination):
    """Copy failed as well as complete trials, excluding private fixture profiles."""
    destination.mkdir(parents=True)
    if not source.exists():
        return
    for child in source.iterdir():
        if child.is_file() and child.suffix in ('.json', '.md'):
            shutil.copy2(child, destination / child.name)
        elif child.name == 'calibration':
            shutil.copytree(child, destination / child.name)
        elif child.is_dir() and re.fullmatch(r'(n|body)-[0-9]+', child.name):
            group = destination / child.name
            group.mkdir()
            for entry in child.iterdir():
                if entry.is_file() and entry.suffix == '.json':
                    shutil.copy2(entry, group / entry.name)
                elif entry.is_dir() and re.match(r'^[0-9]{2}-', entry.name):
                    shutil.copytree(entry, group / entry.name)
                elif entry.is_dir() and (entry / 'cleanup.json').exists():
                    shutil.copy2(entry / 'cleanup.json', group / (entry.name + '-cleanup.json'))


def execute(output, campaign, suite, deadline, options):
    require(options and all(options.get(name) for name in ('baseline_artifact', 'candidate_artifact', 'tools', 'capabilities')),
            'signed UX collection requires --baseline-artifact, --candidate-artifact, --tools and --capabilities')
    tools = options['tools'].resolve()
    require((tools / 'collector').is_file() and (tools / 'build.json').is_file(), 'build independent collectors before measurement')
    manifests = {}
    for side in ('baseline', 'candidate'):
        manifest = read(options[side + '_artifact'])
        require(manifest.get('kind') == 'performance-artifact' and manifest.get('schemaVersion') == 1,
                'unsupported signed artifact manifest')
        require(manifest['revision'] == campaign['subjects'][side]['revision'], 'artifact revision binding mismatch')
        actual = artifact(Path(manifest['app']), manifest['revision'])
        require(actual == manifest, 'signed artifact changed after binding')
        manifests[side] = manifest
        campaign['subjects'][side].update(artifactSHA256=manifest['artifactSHA256'], revisionBinding=manifest['revisionBinding'])
        write(output / (side + '-artifact.json'), manifest)
    campaign['harnessSHA256'] = source_hash([p for p in BENCHMARKS.rglob('*') if p.suffix in ('.py', '.swift', '.c', '.h')])
    campaign['session']['toolchain'] = read(tools / 'build.json')['toolchain']
    campaign['session']['mode'] = 'signed-release-optical-identified-app'
    workload = suite['workload']
    family = workload['family']
    phase(campaign, 'execute')
    with native_lease(), tempfile.TemporaryDirectory(prefix='chief-ux-private-') as temporary:
        from lifecycle import desktop_preflight
        desktop_preflight(tools, output)
        private = Path(temporary)
        for pair in range(suite['pairCount']):
            order = 'AB' if pair % 2 == 0 else 'BA'
            for letter in order:
                side = 'baseline' if letter == 'A' else 'candidate'
                run_id = f'{pair:02d}-{side}'
                private_run = private / run_id
                cli = 'reading_benchmark.py' if family == 'reading' else 'benchmark.py'
                args = [os.sys.executable, str(BENCHMARKS / cli), 'run', '--app', manifests[side]['app'],
                        '--tools', str(tools), '--capabilities', str(options['capabilities'].resolve()),
                        '--output', str(private_run), '--scenario', *suite['scenarios']]
                args += ['--body-kib', str(workload['bodyKiB'])] if family == 'reading' else [
                    '--count', str(workload['count']), '--seconds', str(workload['formalSeconds']),
                    '--window-bounds', *map(str, workload['windowBounds'])]
                # External collector exit 2 faithfully denotes its wider unsupported
                # scope. The narrow adapter reanalyzes every retained case below.
                destination = output / 'raw' / run_id
                power = observe(['pmset', '-g', 'batt'])
                source = re.search(r"Now drawing from '([^']+)'", power)
                require(source is not None, 'power source unknown')
                environment = {'powerSource': source[1], 'thermal': observe(['pmset', '-g', 'therm'])}
                write(output / 'environment' / (run_id + '-before.json'), environment)
                try:
                    command(args, output / 'commands' / (run_id + '.log'), timeout=remaining(deadline, 600), graceful=True)
                except ValueError:
                    receipt = read(output / 'commands' / (run_id + '.command.json'))
                    require(receipt['exitCode'] == 2, 'external collector failed before analysis')
                finally:
                    export_evidence(private_run, destination)
                power_after = re.search(r"Now drawing from '([^']+)'", observe(['pmset', '-g', 'batt']))
                after = {'powerSource': power_after[1] if power_after else None, 'thermal': observe(['pmset', '-g', 'therm'])}
                write(output / 'environment' / (run_id + '-after.json'), after)
                require(environment == after, 'power/thermal state changed during collection')
                summary = read(destination / 'summary.json')
                for entry in summary['results']:
                    relative = Path(entry['path'])
                    require(not relative.is_absolute() and '..' not in relative.parts, 'unsafe trial path')
                    require(len(relative.parts) == 2 and re.match(r'^[0-9]{2}-', relative.name), 'fixture preparation failed; no certified trial')
                    case = destination / relative
                    values, result = scoped_metrics(case, suite)
                    plan, owner = read(case / 'plan.json'), read(case / 'identity.json')
                    # Fixture IDs differ across fresh profiles. Compare declared
                    # workload/content and actual display/collector, not random IDs.
                    comparison = {'host': {k: owner['host'][k] for k in ('os', 'screens')},
                                  'powerThermal': environment,
                                  'collectorSHA256': owner['collectorSHA256'], 'toolBuild': owner['toolBuild'],
                                  'windowBounds': plan['windowBounds'],
                                  'nativeCLI': read(case / 'native-cli.json')['sha256'],
                                  'timing': {k: plan[k] for k in ('sampleHz', 'captureHz', 'formalSeconds', 'warmupSeconds', 'tailSeconds')}}
                    store_observation(output, campaign, suite, {
                        'id': run_id + '-' + entry['scenario'], 'scenario': entry['scenario'], 'pair': pair,
                        'order': order, 'side': side, 'validity': 'valid', 'product': 'passed', 'reasons': [],
                        'scope': 'optical bounds and identified live App; not whole task CPU, native FPS or energy',
                        'widerMeasurement': result['measurement'], 'excludedCapabilities': result['reasons'],
                        'artifactSHA256': manifests[side]['artifactSHA256'], 'comparison': comparison, 'metrics': values,
                        'evidence': [reference(output, p) for p in sorted(case.rglob('*')) if p.is_file()]})
    for side in manifests:
        require(artifact(Path(manifests[side]['app']), manifests[side]['revision']) == manifests[side], 'artifact changed during campaign')
