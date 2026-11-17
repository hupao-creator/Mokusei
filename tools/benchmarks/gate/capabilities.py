"""Read-only probes of installed macOS collectors; never request privileges."""
import os
from pathlib import Path
import platform
import subprocess

from .engine import reference, write


def probe(output):
    observations = {}
    commands = {
        'xcode': ['xcodebuild', '-version'],
        'xctrace-version': ['xcrun', 'xctrace', 'version'],
        'xctrace-templates': ['xcrun', 'xctrace', 'list', 'templates'],
        'xctrace-devices': ['xcrun', 'xctrace', 'list', 'devices'],
        'metalperftrace': ['xcrun', '--find', 'metalperftrace'],
        'powermetrics-help': ['/usr/bin/powermetrics', '--help'],
    }
    if platform.system() == 'Darwin':
        # A single unprivileged sample either succeeds with existing rights or
        # records the kernel tool's refusal. No sudo or authorization mutation.
        commands['powermetrics-sample'] = ['/usr/bin/powermetrics', '--samplers', 'gpu_power', '-i', '100', '-n', '1']
    for name, argv in commands.items():
        try:
            value = subprocess.run(argv, capture_output=True, text=True, timeout=20)
            observations[name] = {'argv': argv, 'exitCode': value.returncode, 'stdout': value.stdout, 'stderr': value.stderr}
        except (OSError, subprocess.TimeoutExpired) as error:
            observations[name] = {'argv': argv, 'exitCode': None, 'error': str(error)}
        write(output / (name + '.json'), observations[name])
    templates = observations['xctrace-templates'].get('stdout', '')
    devices = observations['xctrace-devices'].get('stdout', '')
    result = {'schemaVersion': 1, 'kind': 'performance-capabilities', 'platform': platform.platform(),
              'privilegeChanges': False, 'foregroundInput': False,
              'capabilities': {
                  'presentedFrameTime': {'status': 'unsupported', 'unit': 'seconds/frame',
                      'reason': 'No validated process/surface-attributed presentation trace adapter; capture cadence is not display FPS',
                      'metalSystemTraceInstalled': 'Metal System Trace' in templates,
                      'recordingDevicesReported': 'No devices available' not in devices and bool(devices)},
                  'gpuExecutionTime': {'status': 'unsupported', 'unit': 'seconds',
                      'reason': 'No calibrated signed-App GPU gate; traceOwnedGPUActiveSeconds is a separate instrumented diagnostic',
                      'diagnosticCommand': 'performance.py trace / trace-analyze'},
                  'energyJoules': {'status': 'unsupported', 'unit': 'joules',
                      'reason': 'No per-product physical energy measurement; system estimated power and energy impact are different signals'},
                  'systemEstimatedGPUPower': {'status': 'available-diagnostic' if observations.get('powermetrics-sample', {}).get('exitCode') == 0 else 'unsupported',
                      'unit': 'milliwatts-estimated', 'attribution': 'whole-system', 'gateEligible': False},
                  'overviewPinchInjection': {'status': 'unsupported',
                      'reason': 'No validated public macOS system magnification injector; product ignores command/control/option wheel for canvas navigation'},
                  'startupColdOSCache': {'status': 'unsupported',
                      'reason': 'No controlled reboot/cache-cold protocol; collector never purges system caches'},
              },
              'evidence': [reference(output, output / (name + '.json')) for name in commands]}
    write(output / 'capabilities.json', result)
    (output / 'capabilities.md').write_text('# Performance capabilities\n\n' + '\n'.join(
        '- **' + name + '**: ' + value['status'] + '. ' + value.get('reason', value.get('attribution', ''))
        for name, value in result['capabilities'].items()) + '\n')
    return result
