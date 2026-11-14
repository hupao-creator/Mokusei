"""Descriptive, balanced badge-material experiment over external production runs."""
import copy
import hashlib
import math
import re
import statistics

from contracts.model import integer
from lifecycle import save

STYLES = ('flat', 'liquid-glass')
SCENARIOS = ('idle.completed', 'idle.active', 'pan', 'body', 'body.pan')
ORDER = ('flat', 'liquid-glass', 'liquid-glass', 'flat')


def validate_receipt(value, style, pid):
    if type(value) is not dict or type(value.get('version')) is not int or value['version'] != 1:
        raise ValueError('unsupported badge configuration receipt')
    if style not in STYLES or value.get('scenario') != 'overview' or value.get('agentEmojiBadge') != style:
        raise ValueError('application did not admit the requested badge experiment')
    if integer(value.get('pid'), 'badge receipt owner', 1) != pid:
        raise ValueError('badge receipt belongs to a different application owner')
    for key in ('reduceTransparency', 'reduceMotion', 'increaseContrast'):
        if type(value.get(key)) is not bool:
            raise ValueError('badge receipt lacks accessibility state: ' + key)
    if value['reduceTransparency']:
        raise ValueError('Reduce Transparency would replace Liquid Glass with an opaque fallback')
    return value


def workload_signature(workload):
    if workload is None:
        return None
    result = copy.deepcopy(workload)
    # The final result's fixed-width nonce proves this execution completed. It
    # deliberately differs per trial; retain its byte budget and every other byte.
    for message in result.get('terminal', []):
        if message.get('kind') != 'terminal' or message.get('atSeconds') != result['durationSeconds']:
            continue
        value, replaced = re.subn(r' RUN [0-9a-f]{32}\.$', ' RUN ' + '0'*32 + '.', message['text'])
        if replaced:
            message['text'] = value
            message['sha256'] = hashlib.sha256(value.encode()).hexdigest()
    return result


def summarize(directory, attempts):
    from analysis.report import analyze
    from contracts.model import load
    groups = {}
    for attempt in attempts:
        for result in attempt['results']:
            case = directory/attempt['directory']/result['path']
            row = {'attempt': attempt['index'], 'style': attempt['style'], 'path': str(case.relative_to(directory))}
            key = (result['count'], result['scenario'])
            groups.setdefault(key, []).append(row)
            try:
                # Recheck sealed evidence; an edited cached report is not a result.
                report = analyze(case)
                plan = load(case/'plan.json')
                receipt = validate_receipt(load(case/'rendering-configuration.json'), attempt['style'], plan['pid'])
                manifest = load(case/'manifest.json')
                if 'rendering-configuration.json' not in manifest['files']:
                    raise ValueError('badge configuration receipt is unsealed')
                app = report.get('metrics', {}).get('formal', {}).get('roles', {}).get('application', {})
                row.update({k: report[k] for k in ('measurement', 'product', 'comparison', 'reasons')})
                row['application'] = app
                origin = next((event for event in plan['events'] if event['kind'] == 'down'), {'x': 0, 'y': 0})
                relative_input = [{**event, **{axis: round(event[axis]-origin[axis], 6) for axis in ('x', 'y')}}
                                  for event in plan['events']]
                identity = load(case/'identity.json')
                row['matchingConditions'] = {
                    'artifact': load(case/'artifact.json'),
                    'collectorSHA256': identity['collectorSHA256'],
                    'frameworkFiles': identity.get('frameworkFiles'),
                    'nativeCLI': load(case/'native-cli.json'),
                    'window': plan['windowBounds'], 'mode': plan['mode'],
                    'warmupSeconds': plan['warmupSeconds'], 'formalSeconds': plan['formalSeconds'],
                    'tailSeconds': plan['tailSeconds'], 'relativeInput': relative_input,
                    'budgets': {k: plan[k] for k in ('maximumNoProgressSeconds', 'maximumCaptureGapSeconds', 'motionTolerancePixels')},
                    'sampleHz': plan['sampleHz'], 'captureHz': plan['captureHz'],
                    'workload': workload_signature(plan.get('workload')),
                    'accessibility': {k: receipt[k] for k in ('reduceTransparency', 'reduceMotion', 'increaseContrast')},
                    'host': {k: identity['host'][k] for k in ('os', 'screens')},
                }
                observation = load(case/'observation.json')
                row['appPresentInEverySample'] = bool(observation['resources']) and all(any(
                    process['identity'] == plan['processIdentity'] and process['pid'] == plan['pid']
                    and process['role'] == 'application' for process in sample['processes'])
                    for sample in observation['resources'])
                cpu = app.get('singleCoreCPUPercent')
                peak = app.get('sampledPeakFootprintBytes')
                # The exploratory App interval is separate from the known missing
                # descendant-exit and native-hitch capabilities. A missing helper may
                # coexist with complete App samples; a missing App never does.
                # Other gaps withhold deltas.
                allowed = ('process lifecycle/exit CPU coverage incomplete',
                    'declared process root missing from sample',
                    'native hitch sensitivity/ownership controls did not establish capability',
                    'native hitch unavailable: native XCTest hitch collection not requested; default collection never starts the privileged performance service')
                row['resourceEligible'] = (row['appPresentInEverySample'] and report['product'] == 'passed' and report['measurement'] != 'invalid'
                    and all(reason in allowed for reason in report['reasons'])
                    and type(cpu) in (int, float) and math.isfinite(cpu) and cpu >= 0
                    and type(peak) is int and peak > 0)
            except (ValueError, KeyError, OSError) as error:
                row['resourceEligible'] = False
                row['error'] = str(error)
    summaries = []
    for (count, scenario), rows in groups.items():
        entry = {'count': count, 'scenario': scenario, 'trials': rows, 'comparison': 'not-comparable'}
        matching = len(rows) == len(ORDER) and [row['style'] for row in rows] == list(ORDER)
        matching = matching and all(row.get('resourceEligible') for row in rows)
        matching = matching and all(row['matchingConditions'] == rows[0]['matchingConditions'] for row in rows)
        entry['matchedResourceObservations'] = matching
        if matching:
            means = {}
            for style in STYLES:
                samples = [r['application'] for r in rows if r['style'] == style]
                means[style] = {'appCPUPercent': statistics.mean(r['singleCoreCPUPercent'] for r in samples),
                    'sampledPeakMiB': statistics.mean(r['sampledPeakFootprintBytes']/1024**2 for r in samples)}
            flat, glass = means['flat'], means['liquid-glass']
            entry['descriptiveMeans'] = means
            entry['glassMinusFlatCPUPoints'] = glass['appCPUPercent'] - flat['appCPUPercent']
            entry['glassCPUChangePercent'] = (100*(glass['appCPUPercent']/flat['appCPUPercent']-1)
                                             if flat['appCPUPercent'] > 0 else None)
            entry['glassMinusFlatPeakMiB'] = glass['sampledPeakMiB'] - flat['sampledPeakMiB']
        summaries.append(entry)
    summary = {'version': 1, 'order': list(ORDER), 'scope': 'Same signed artifact, Agent emoji badge material only',
        'statisticalRegressionGate': False, 'comparison': 'not-comparable',
        'limitations': ['Descriptive App CPU/footprint observations; two samples per material, no statistical inference.',
            'Incomplete descendant/exit CPU and unavailable native hitches remain measurement limitations.',
            'No GPU, WindowServer attribution, energy, optical FPS or pixel-style comparison.'], 'results': summaries}
    save(directory/'badge-comparison.json', summary)
    lines = ['# Agent emoji badge material observations', '',
        'Order: flat → Liquid Glass → Liquid Glass → flat. Same signed artifact; pre-existing cards.',
        'CPU 100% means one core. Peak memory is sampled physical footprint. Values below are two-run means.',
        'Full benchmark comparison remains not-comparable; these are exploratory resource differences.', '',
        '| N | Scenario | Flat CPU | Glass CPU | Glass − flat | Flat / glass MiB |',
        '| --- | --- | ---: | ---: | ---: | ---: |']
    for entry in summaries:
        if not entry['matchedResourceObservations']:
            lines.append(f"| {entry['count']} | {entry['scenario']} | — | — | withheld: unmatched/incomplete evidence | — |")
            continue
        flat, glass = (entry['descriptiveMeans'][s] for s in STYLES)
        lines.append(f"| {entry['count']} | {entry['scenario']} | {flat['appCPUPercent']:.2f}% | {glass['appCPUPercent']:.2f}% | "
            f"{entry['glassMinusFlatCPUPoints']:+.2f} pp | {flat['sampledPeakMiB']:.2f} / {glass['sampledPeakMiB']:.2f} |")
    lines += ['', *summary['limitations'], '', 'See badge-comparison.json for every trial, condition, status and reason.']
    (directory/'badge-comparison.md').write_text('\n'.join(lines)+'\n')
    return summary


def run(tools, bundle, directory, counts, scenarios, seconds, capabilities, pacing, chunk_bytes, message_bytes,
        warmup_seconds=6.0, window_bounds=None):
    from runner import run_suite
    directory.mkdir(parents=True, exist_ok=False, mode=0o700)
    attempts = []
    try:
        for index, style in enumerate(ORDER):
            name = f'{index:02d}-{style}'
            results = run_suite(tools, bundle, directory/name, counts, scenarios, 'observed', seconds, capabilities,
                pacing, chunk_bytes, message_bytes, emoji_badge=style, warmup_seconds=warmup_seconds,
                window_bounds=window_bounds)
            attempts.append({'index': index, 'style': style, 'directory': name, 'results': results})
            save(directory/'attempts.json', attempts)
    finally:
        summary = summarize(directory, attempts)
    return summary
