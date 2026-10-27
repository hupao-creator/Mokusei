"""Compile unchanged production geometry from a Git baseline and the current tree.
No app/profile launch. Timings are diagnostic, not a GUI frame-rate benchmark.
"""
import argparse
import json
from pathlib import Path
import subprocess
import statistics

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--baseline', required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=True)
module = 'app/macos/Sources/Host/Overview/'
probe = Path(__file__).with_name('probe.swift').read_text()
for label in ['before', 'after']:
    def source(name):
        path = module + name + '.swift'
        return (subprocess.check_output(['git', 'show', f'{a.baseline}:{path}'], cwd=ROOT, text=True)
                if label == 'before' else (ROOT / path).read_text())
    folder = out / label
    folder.mkdir(exist_ok=True)
    driver = probe
    if label == 'after':
        driver = driver.replace('/*PREFERRED*/', ', preferredSize: preferred')
        driver = driver.replace('/*READING_POSITION*/', '''if !previous.isEmpty && result.shiftedIDs.isEmpty &&
        Set(members.map(\\.id)).isSubset(of: Set(previous.map(\\.id))) {
        after = NativeOverviewCameraGeometry.preservingReadingPosition(before, content: content, viewport: viewport)
    }''')
    (folder / 'main.swift').write_text(source('NativeOverviewLayout') + '\n' + driver)
    (folder / 'Camera.swift').write_text(source('NativeOverviewCamera').split('/// Single-writer camera')[0])
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(out / 'cache'),
                    str(folder / 'Camera.swift'), str(folder / 'main.swift'), '-o', str(folder / 'probe')], check=True)
    samples = [json.loads(subprocess.check_output([str(folder / 'probe')])) for _ in range(3)]
    for sample in samples[1:]:
        assert [r['result']['placements'] for r in sample] == [r['result']['placements'] for r in samples[0]]
    (out / f'{label}.json').write_text(json.dumps(samples, indent=2))
rows = []
for before, after in zip(json.loads((out / 'before.json').read_text())[0], json.loads((out / 'after.json').read_text())[0]):
    rows.append({'scenario': before['scenario'], **{key: [before[key], after[key]] for key in
                ['visibleFill', 'fullCards', 'screenMoved', 'screenMax', 'screenTotal', 'elapsedMs']},
                 'steps': [before['result']['work']['steps'], after['result']['work']['steps']]})
(out / 'comparison.json').write_text(json.dumps(rows, indent=2))
print(json.dumps(rows, indent=2))

by_name = {row['scenario']: row for row in rows}
assert by_name['three-900']['visibleFill'][1] - by_name['three-900']['visibleFill'][0] > 0.10
assert by_name['delete-center']['screenMax'][1] < 1
assert by_name['six-to-seven']['fullCards'][1] == 7
assert by_name['six-to-seven']['screenMax'][1] <= 188.01
assert by_name['six-repeat']['steps'][1] == 0
assert by_name['six-reversed']['steps'][1] == 0
for name in ['fresh-16', 'fresh-30', 'fresh-100', 'fresh-500']:
    assert by_name[name]['visibleFill'][1] >= by_name[name]['visibleFill'][0] - 1e-9
latencies = {}
for label in ['before', 'after']:
    samples = json.loads((out / f'{label}.json').read_text())
    latencies[label] = {row['scenario']: {
        'medianMs': statistics.median(sample[index]['elapsedMs'] for sample in samples),
        'maxMs': max(sample[index]['elapsedMs'] for sample in samples)
    } for index, row in enumerate(samples[0])}
(out / 'latencies.json').write_text(json.dumps(latencies, indent=2))
