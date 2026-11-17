"""Bounded Instruments evidence acquisition, separate from unprofiled gates."""
from pathlib import Path
import xml.etree.ElementTree as ET

from .engine import digest, reference, report_base, require, save_report
from .runner import command, lease, phase
from .ux import native_lease

TEMPLATES = ('Metal System Trace', 'Animation Hitches', 'App Launch')
TABLES = ('metal-gpu-intervals', 'displayed-surfaces-interval', 'ca-client-presented-handler')


def gpu_observation(path, pid):
    """Xcode 26 exported active depth-zero intervals, unioned across channels.

    A command may occupy overlapping GPU channels. Summing rows double-counts
    time, so this reports the union only and retains all admitted intervals.
    Missing target activity is unknown, never a fabricated zero-cost product.
    """
    require(Path(path).stat().st_size <= 256 * 1024 * 1024, 'GPU export exceeds analysis size budget')
    tree = ET.parse(path).getroot()
    definitions = {node.get('id'): node for node in tree.iter() if node.get('id')}
    def resolve(node):
        visited = set()
        while node.get('ref'):
            ref = node.get('ref')
            require(ref not in visited and ref in definitions, 'invalid Instruments reference')
            visited.add(ref)
            node = definitions[ref]
        return node
    schema = tree.find('.//schema')
    require(schema is not None and schema.get('name') == 'metal-gpu-intervals', 'unsupported GPU table')
    columns = [c.findtext('mnemonic') for c in schema.findall('col')]
    require(all(name in columns for name in ('start', 'duration', 'state', 'event-depth', 'process')), 'GPU schema lacks ownership/timing')
    intervals = []
    for row in tree.findall('.//row'):
        require(len(row) == len(columns), 'GPU row width differs from schema')
        fields = dict(zip(columns, row))
        owner = resolve(fields['process'])
        process_id = owner.find('pid')
        if process_id is None or resolve(process_id).text != str(pid):
            continue
        if resolve(fields['state']).text != 'Active' or resolve(fields['event-depth']).text != '0':
            continue
        start, duration = int(resolve(fields['start']).text), int(resolve(fields['duration']).text)
        require(start >= 0 and duration >= 0, 'negative GPU timestamp/duration')
        intervals.append([start, start + duration])
    merged = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return {'metric': 'traceOwnedGPUActiveSeconds', 'unit': 'seconds', 'pid': int(pid),
            'value': sum(end-start for start, end in merged)/1e9 if intervals else None,
            'activeIntervalsNS': intervals, 'unionIntervalsNS': merged,
            'status': 'observed-diagnostic' if intervals else 'incomplete', 'gateEligible': False,
            'scope': 'target PID active depth-zero GPU intervals; union across channels; instrumented trace, not whole App energy'}


def collect(output, executable, arguments, template, seconds):
    require(executable.is_file(), 'trace target executable is absent')
    require(1 <= seconds <= 30, 'diagnostic traces are bounded to 1..30 seconds')
    result = report_base('instruments-diagnostic', output.name)
    result.update(validity='unsupported', reasons=['Raw trace acquisition does not establish calibrated per-product FPS/GPU/energy metrics'],
                  trace={'template': template, 'executableSHA256': digest(executable), 'tables': [],
                         'instrumented': True, 'automaticUpload': False})
    phase(result, 'prepare')
    try:
        with lease(), native_lease():
            phase(result, 'execute')
            command(['xcrun', 'xctrace', 'record', '--template', template, '--time-limit', str(seconds)+'s',
                     '--no-prompt', '--output', str(output/'recording.trace'), '--target-stdout', str(output/'target-stdout.txt'),
                     '--launch', '--', str(executable.resolve()), *arguments], output/'record.log', timeout=seconds+90)
            phase(result, 'collect')
            command(['xcrun', 'xctrace', 'export', '--input', str(output/'recording.trace'), '--toc',
                     '--output', str(output/'toc.xml')], output/'export.log', timeout=60)
            toc = ET.parse(output/'toc.xml').getroot()
            result['trace']['instrumentsVersion'] = toc.findtext('./run/info/summary/instruments-version')
            require(toc.findtext('./run/info/summary/template-name') == template, 'recorded template differs')
            target = toc.find('./run/info/target/process')
            require(target is not None and target.get('type') == 'launched', 'trace has no owned launched target')
            result['trace']['target'] = dict(target.attrib)
            require(target.get('return-exit-status') == '0' and target.get('termination-reason', '').startswith('exit('),
                    'diagnostic target must exit itself successfully; no completed cleanup receipt')
            tables = {t.get('schema') for t in toc.findall('.//table')}
            for name in TABLES:
                if name not in tables:
                    continue
                destination = output/(name+'.xml')
                command(['xcrun', 'xctrace', 'export', '--input', str(output/'recording.trace'), '--xpath',
                         '/trace-toc/run[@number="1"]/data/table[@schema="'+name+'"]',
                         '--output', str(destination)], output/(name+'.log'), timeout=60)
                tree = ET.parse(destination).getroot()
                result['trace']['tables'].append({'schema': name, 'rows': len(tree.findall('.//row')),
                                                  'path': destination.name, 'targetAttributionValidated': False})
                if name == 'metal-gpu-intervals':
                    result['trace']['gpuObservation'] = gpu_observation(destination, target.get('pid'))
            result['trace']['collection'] = 'completed'
            phase(result, 'validate')
    except (Exception, KeyboardInterrupt) as error:
        result.update(validity='invalid', reasons=[type(error).__name__ + ': ' + str(error)])
        result['trace']['collection'] = 'failed'
    result['evidence'] = [reference(output, p) for p in sorted(output.rglob('*')) if p.is_file()]
    phase(result, 'judge')
    phase(result, 'report')
    save_report(output, result)
    return result
