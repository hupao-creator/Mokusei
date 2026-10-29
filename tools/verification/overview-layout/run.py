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
regression = Path(__file__).with_name('regression.swift').read_text()
for label in ['before', 'after']:
    def source(name):
        path = module + name + '.swift'
        return (subprocess.check_output(['git', 'show', f'{a.baseline}:{path}'], cwd=ROOT, text=True)
                if label == 'before' else (ROOT / path).read_text())
    folder = out / label
    folder.mkdir(exist_ok=True)
    layout_source = source('NativeOverviewLayout')
    driver = probe
    if 'preferredSize: CGSize?' in layout_source:
        driver = driver.replace('/*PREFERRED*/', ', preferredSize: preferred')
    if label == 'after' or 'preserveReadingPosition: !replaceScene' in source('NativeOverviewCanvas'):
        driver = driver.replace('/*READING_POSITION*/', '''if !previous.isEmpty && result.shiftedIDs.isEmpty &&
        Set(members.map(\\.id)).isSubset(of: Set(previous.map(\\.id))) {
        after = NativeOverviewCameraGeometry.preservingReadingPosition(before, content: content, viewport: viewport)
    }''')
    (folder / 'main.swift').write_text(layout_source + '\n' + driver)
    (folder / 'Camera.swift').write_text(source('NativeOverviewCamera').split('/// Single-writer camera')[0])
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(out / 'cache'),
                    str(folder / 'Camera.swift'), str(folder / 'main.swift'), '-o', str(folder / 'probe')], check=True)
    samples = [json.loads(subprocess.check_output([str(folder / 'probe')])) for _ in range(3)]
    for sample in samples[1:]:
        assert [r['result']['placements'] for r in sample] == [r['result']['placements'] for r in samples[0]]
    (out / f'{label}.json').write_text(json.dumps(samples, indent=2))
    regression_folder = folder / 'regression'
    regression_folder.mkdir(exist_ok=True)
    (regression_folder / 'main.swift').write_text(layout_source + '\n' + regression)
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(out / 'cache'),
                    str(folder / 'Camera.swift'), str(regression_folder / 'main.swift'),
                    '-o', str(regression_folder / 'probe')], check=True)
    regression_samples = [json.loads(subprocess.check_output([str(regression_folder / 'probe')])) for _ in range(3)]
    for sample in regression_samples[1:]:
        assert [r['result']['placements'] for r in sample] == [r['result']['placements'] for r in regression_samples[0]]
    (out / f'{label}-regression.json').write_text(json.dumps(regression_samples, indent=2))
rows = []
for before, after in zip(json.loads((out / 'before.json').read_text())[0], json.loads((out / 'after.json').read_text())[0]):
    rows.append({'scenario': before['scenario'], **{key: [before[key], after[key]] for key in
                ['visibleFill', 'fullCards', 'screenMoved', 'screenMax', 'screenTotal', 'elapsedMs']},
                 'steps': [before['result']['work']['steps'], after['result']['work']['steps']]})
(out / 'comparison.json').write_text(json.dumps(rows, indent=2))
print(json.dumps(rows, indent=2))

by_name = {row['scenario']: row for row in rows}
assert by_name['three-900']['visibleFill'][1] >= by_name['three-900']['visibleFill'][0] - 1e-9
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

regressions = {row['scenario']: row['result'] for row in regression_samples[0]}
before_regressions = {row['scenario']: row['result'] for row in json.loads((out / 'before-regression.json').read_text())[0]}
def cells(result):
    return {p['member']['id']: (p['column'], p['row'], p['member']['columns'], p['member']['rows'])
            for p in result['placements']}
for name, wide_id in [('delete-wide-and-edge', '10-g'), ('shrink-wide', 'g'), ('screenshot-same-footprints', 'g')]:
    result = regressions[name]
    assert (result['bounds']['columns'], result['bounds']['rows']) == (3, 3), name
    assert result['shiftedIDs'] == [wide_id], name
    assert cells(result)[wide_id] == (1, 2, 2, 1), name
    assert not result['requiresRepack'], name
for name, original in [('delete-repeat', 'delete-wide-and-edge'), ('shrink-repeat', 'shrink-wide')]:
    assert cells(regressions[name]) == cells(regressions[original]), name
    assert regressions[name]['work']['steps'] == 0, name
for name in ['history-expand', 'necessary-wide-vacancy', 'necessary-center-vacancy', 'center-refill']:
    assert regressions[name]['shiftedIDs'] == [], name
for name in ['necessary-wide-vacancy', 'necessary-center-vacancy']:
    assert regressions[name]['work']['steps'] == 0, name
assert cells(regressions['screenshot-offset'])['g'] == (8, 13, 2, 1)
assert regressions['screenshot-offset']['shiftedIDs'] == ['g']
assert cells(regressions['screenshot-transposed'])['g'] == (2, 1, 1, 2)
assert regressions['screenshot-transposed']['shiftedIDs'] == ['g']
assert regressions['filter-compact']['bounds']['columns'] * regressions['filter-compact']['bounds']['rows'] == 9
for name in ['no-viewport-compact', 'insufficient-capacity']:
    assert cells(regressions[name]) == cells(before_regressions[name]), name
assert regressions['capacity-recovery']['bounds']['columns'] == 3
assert regressions['capacity-recovery']['bounds']['rows'] == 3
square = regressions['necessary-square-vacancy']
assert square['bounds']['columns'] == square['bounds']['rows'] == 4
assert square['shiftedIDs'] == [] and square['work']['steps'] < 100
exhausted = regressions['probe-budget-exhausted']
assert not exhausted['searchComplete'] and exhausted['work']['steps'] == 1
assert exhausted['shiftedIDs'] == [] and not exhausted['requiresRepack']
assert exhausted['bounds']['columns'] * exhausted['bounds']['rows'] == 12
compact = regressions['compact-budget-exhausted']
assert not compact['searchComplete'] and compact['work']['steps'] == 200
assert compact['bounds']['columns'] * compact['bounds']['rows'] == 9
assert compact['requiresRepack']
assert regressions['growth-repack']['requiresRepack']
assert not regressions['growth-repack']['searchComplete']
assert not regressions['mixed-truncated']['searchComplete']
assert regressions['mixed-truncated']['bounds']['width'] <= 1500
assert regressions['mixed-truncated']['bounds']['height'] <= 700
for count in [100, 500]:
    assert cells(regressions[f'large-repeat-{count}']) == cells(regressions[f'large-{count}'])
regression_comparison = [{
    'scenario': name,
    'bounds': [[version['bounds']['columns'], version['bounds']['rows']]
               for version in [before_regressions[name], result]],
    'shiftedIDs': [before_regressions[name]['shiftedIDs'], result['shiftedIDs']],
    'steps': [before_regressions[name]['work']['steps'], result['work']['steps']],
    'searchComplete': [before_regressions[name]['searchComplete'], result['searchComplete']],
    'requiresRepack': [before_regressions[name]['requiresRepack'], result['requiresRepack']],
} for name, result in regressions.items()]
(out / 'regression-comparison.json').write_text(json.dumps(regression_comparison, indent=2))
print(f'Passed {len(regressions)} history/capacity/budget scenarios (three deterministic runs per version).')
