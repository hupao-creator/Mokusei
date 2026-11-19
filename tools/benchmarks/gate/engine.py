"""Versioned input boundary and deterministic paired regression judgment."""
import hashlib
import json
import math
from pathlib import Path
import re
import random
import statistics

VERSION = 1
PHASES = ('prepare', 'execute', 'collect', 'validate', 'judge', 'report', 'upload')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def pairs_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON field: ' + key)
        result[key] = value
    return result


def read(path):
    path = Path(path)
    require(path.stat().st_size <= 128 * 1024 * 1024, 'JSON size limit exceeded')
    return json.loads(path.read_text(), object_pairs_hook=pairs_object,
                      parse_constant=lambda v: require(False, 'nonfinite JSON: ' + v))


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')
    temporary.replace(path)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def identity(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def text(value, label):
    require(type(value) is str and 0 < len(value) <= 4096, label + ': nonempty bounded string required')
    return value


def number(value, label, minimum=0):
    # JSON integers may exceed float range; bound them before isfinite converts.
    require(type(value) in (int, float) and minimum <= value <= 1e30 and math.isfinite(value),
            label + ': finite nonnegative number required')
    return value


def sha(value, label, length=64):
    require(type(value) is str and re.fullmatch('[0-9a-f]{' + str(length) + '}', value), label + ': invalid digest')


def catalog(value):
    require(type(value) is dict and type(value.get('schemaVersion')) is int and value.get('schemaVersion') == VERSION and value.get('kind') == 'performance-catalog',
            'unsupported catalog version/kind')
    suites = value.get('suites')
    require(type(suites) is dict and bool(suites), 'catalog must enumerate suites')
    for name, suite in suites.items():
        text(name, 'suite ID')
        require(type(suite) is dict and type(suite.get('version')) is int and suite['version'] > 0, 'suite version required')
        text(suite.get('documentation'), 'suite documentation')
        text(suite.get('calibration'), 'policy calibration status')
        scenarios = suite.get('scenarios')
        require(type(scenarios) is list and bool(scenarios), 'required scenario IDs missing')
        for scenario in scenarios:
            text(scenario, 'scenario ID')
            require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', scenario), 'unsafe scenario ID')
        require(len(scenarios) == len(set(scenarios)), 'duplicate scenario IDs')
        require(suite.get('adapter') in ('runtime', 'overview', 'external', 'unsupported'), 'unknown adapter')
        if suite['adapter'] == 'unsupported':
            text(suite.get('reason'), 'capability reason')
            continue
        count = suite.get('pairCount')
        require(type(count) is int and 6 <= count <= 50 and count % 2 == 0, 'at least six balanced pairs required')
        number(suite.get('budgetSeconds'), 'suite budget', 1)
        number(suite.get('maxNormalizedMAD'), 'noise budget')
        require(type(suite.get('workload')) is dict and bool(suite['workload']), 'workload required')
        metrics = suite.get('metrics')
        require(type(metrics) is dict and bool(metrics), 'required metrics missing')
        for name, policy in metrics.items():
            text(name, 'metric ID')
            require(type(policy) is dict, 'metric policy must be an object')
            text(policy.get('unit'), 'metric unit')
            require(policy.get('direction') in ('lower', 'higher'), 'metric direction required')
            number(policy.get('relative'), 'relative tolerance')
            number(policy.get('absolute'), 'absolute tolerance', 1e-20)
    return value


def evidence(root, references):
    require(type(references) is list and bool(references), 'evidence references missing')
    names = set()
    for entry in references:
        name = text(entry.get('path'), 'evidence path')
        require(name not in names, 'duplicate evidence path')
        names.add(name)
        path = Path(name)
        require(not path.is_absolute() and '..' not in path.parts, 'evidence path traversal')
        resolved = (root / path).resolve()
        require(resolved.is_relative_to(root.resolve()), 'evidence escapes bundle')
        sha(entry.get('sha256'), 'evidence SHA256')
        require(resolved.is_file(), 'missing evidence: ' + name)
        require(digest(resolved) == entry['sha256'], 'evidence changed: ' + name)


def reference(root, path):
    return {'path': str(Path(path).relative_to(root)), 'sha256': digest(path)}


def bounds(value, label):
    if type(value) is dict:
        require(set(value) == {'lower', 'upper'}, label + ': interval requires lower/upper')
        low, high = number(value['lower'], label), number(value['upper'], label)
        require(low <= high, label + ': inverted interval')
        return low, high
    value = number(value, label)
    return value, value


def bootstrap(pairs):
    # Resample independent adjacent pairs, stratified by order. Keeping both
    # interval endpoints propagates capture uncertainty instead of inventing a
    # precise latency from an OCR sample. The fixed seed makes offline review exact.
    rng = random.Random(1729)
    groups = [[p for p in pairs if p['order'] == order] for order in ('AB', 'BA')]
    lower, upper = [], []
    for _ in range(2000):
        sample = [rng.choice(group) for group in groups for _ in group]
        lower.append(statistics.median(p['excessBounds'][0] for p in sample))
        upper.append(statistics.median(p['excessBounds'][1] for p in sample))
    return {'level': .95, 'lower': sorted(lower)[49], 'upper': sorted(upper)[1949],
            'method': 'order-stratified paired percentile bootstrap; observation bounds propagated',
            'resamples': 2000, 'seed': 1729, 'independentPairs': len(pairs)}


def report_base(suite, run_id):
    return {'schemaVersion': VERSION, 'kind': 'boundary-report', 'boundary': 'performance',
            'suite': suite, 'runId': run_id, 'status': 'blocked', 'validity': 'incomplete',
            'decision': 'not-evaluated', 'exitCode': 2, 'reasons': [], 'evidence': [],
            'phases': [], 'metrics': []}


def blocked(report, reason, validity='invalid', decision='not-evaluated'):
    report.update(status='blocked', validity=validity, decision=decision, exitCode=2)
    report['reasons'].append(reason)
    return report


def judge(root):
    """Load untrusted bundles once; a malformed or partial bundle cannot certify a pass."""
    root = Path(root)
    result = report_base('unknown', root.name)
    try:
        policy = catalog(read(root / 'catalog.json'))
        campaign = read(root / 'campaign.json')
        require(type(campaign) is dict and type(campaign.get('schemaVersion')) is int and campaign.get('schemaVersion') == VERSION and
                campaign.get('kind') == 'performance-campaign', 'unsupported campaign version/kind')
        suite_id = campaign.get('suite')
        require(suite_id in policy['suites'], 'suite absent from catalog')
        suite = policy['suites'][suite_id]
        result.update(suite=suite_id, runId=text(campaign.get('runId'), 'run ID'),
                      policySHA256=digest(root / 'catalog.json'), policy=suite,
                      subjects=campaign.get('subjects'), session=campaign.get('session'),
                      phases=campaign.get('phases', []))
        result['analysisSHA256'] = digest(Path(__file__))
        if campaign.get('analysisSHA256') != result['analysisSHA256']:
            return blocked(result, 'analysis implementation differs from campaign', 'valid', 'not-comparable')
        require(campaign.get('policySHA256') == result['policySHA256'], 'catalog digest changed')
        result['evidence'] = [reference(root, root / name) for name in ('catalog.json', 'campaign.json')]
        if suite['adapter'] == 'unsupported':
            return blocked(result, suite['reason'], 'unsupported')
        if campaign.get('validity') != 'valid':
            state = campaign.get('validity')
            require(state in ('invalid', 'incomplete', 'unsupported'), 'invalid measurement status')
            return blocked(result, '; '.join(campaign.get('reasons') or ['measurement not valid']), state)
        require(campaign.get('cleanup') == 'passed', 'cleanup did not pass')
        sha(campaign.get('harnessSHA256'), 'harness SHA256')
        result['harnessSHA256'] = campaign['harnessSHA256']
        session = campaign.get('session')
        require(type(session) is dict, 'session identity missing')
        for key in ('id', 'runner', 'os', 'architecture', 'hardware', 'toolchain', 'mode'):
            text(session.get(key), 'session.' + key)
        subjects = campaign.get('subjects')
        require(type(subjects) is dict and set(subjects) == {'baseline', 'candidate'}, 'two subject identities required')
        for subject in subjects.values():
            sha(subject.get('revision'), 'product revision', 40)
            sha(subject.get('artifactSHA256'), 'product artifact SHA256')
        evidence(root, campaign.get('evidence'))
        rows = campaign.get('runs')
        require(type(rows) is list, 'run inventory missing')
        if len(rows) != len(suite['scenarios']) * suite['pairCount'] * 2:
            return blocked(result, 'prescribed run inventory incomplete or duplicated', 'incomplete')
        admitted = {}
        seen_ids = set()
        for row in rows:
            require(type(row) is dict, 'run object required')
            run_id = text(row.get('id'), 'run ID')
            require(run_id not in seen_ids, 'duplicate run ID')
            seen_ids.add(run_id)
            scenario, pair, side = row.get('scenario'), row.get('pair'), row.get('side')
            require(scenario in suite['scenarios'] and type(pair) is int and 0 <= pair < suite['pairCount'] and
                    side in subjects, 'unexpected scenario, pair or side')
            key = (scenario, pair, side)
            require(key not in admitted, 'duplicate pair member')
            require(row.get('order') == ('AB' if pair % 2 == 0 else 'BA'), 'unbalanced pair order')
            if row.get('validity') != 'valid':
                state = row.get('validity')
                require(state in ('invalid', 'incomplete', 'unsupported'), 'invalid run validity')
                return blocked(result, run_id + ': ' + '; '.join(row.get('reasons') or ['not valid']), state)
            if row.get('product') != 'passed':
                return blocked(result, run_id + ': functional observation did not pass')
            require(row.get('artifactSHA256') == subjects[side]['artifactSHA256'], 'run artifact identity mismatch')
            expected = {'session': session, 'harnessSHA256': campaign['harnessSHA256'],
                        'suiteVersion': suite['version'], 'workload': suite['workload']}
            if row.get('identity') != expected:
                return blocked(result, run_id + ': runner/toolchain/harness/workload identity differs', 'valid', 'not-comparable')
            require(type(row.get('comparison')) is dict and bool(row['comparison']), 'comparison identity missing')
            evidence(root, row.get('evidence'))
            observation = row.get('observation')
            require(observation in {item['path'] for item in row['evidence']}, 'sealed normalized observation absent')
            original = read(root / observation)
            require({k: v for k, v in row.items() if k not in ('observation', 'evidence')} ==
                    {k: v for k, v in original.items() if k != 'evidence'}, 'campaign differs from sealed observation')
            values = row.get('metrics')
            if type(values) is not dict or not set(suite['metrics']).issubset(values):
                return blocked(result, run_id + ': required metric not collected', 'incomplete')
            for name in suite['metrics']:
                bounds(values[name], run_id + '.' + name)
            admitted[key] = row
        for scenario in suite['scenarios']:
            for name, threshold in suite['metrics'].items():
                pairs = []
                for pair in range(suite['pairCount']):
                    a = admitted[(scenario, pair, 'baseline')]
                    b = admitted[(scenario, pair, 'candidate')]
                    if a['comparison'] != b['comparison']:
                        return blocked(result, scenario + ': paired environment/fixture identity differs', 'valid', 'not-comparable')
                    bl, bu = bounds(a['metrics'][name], name)
                    cl, cu = bounds(b['metrics'][name], name)
                    base, candidate = (bl + bu) / 2, (cl + cu) / 2
                    delta = candidate - base
                    degradation = delta if threshold['direction'] == 'lower' else -delta
                    allowed = max(threshold['absolute'], base * threshold['relative'])
                    if threshold['direction'] == 'lower':
                        excess_bounds = [cl - bu - max(threshold['absolute'], bu * threshold['relative']),
                                         cu - bl - max(threshold['absolute'], bl * threshold['relative'])]
                    else:
                        # Relative tolerances >100% would invert baseline monotonicity.
                        require(threshold['relative'] <= 1, 'higher-is-better relative tolerance exceeds 100%')
                        excess_bounds = [bl - cu - max(threshold['absolute'], bl * threshold['relative']),
                                         bu - cl - max(threshold['absolute'], bu * threshold['relative'])]
                    pairs.append({'pair': pair, 'order': a['order'], 'baseline': base, 'candidate': candidate,
                                  'baselineBounds': [bl, bu], 'candidateBounds': [cl, cu], 'excessBounds': excess_bounds,
                                  'delta': delta, 'relativeDelta': delta / base if base else None,
                                  'degradation': degradation, 'allowed': allowed, 'excess': degradation - allowed,
                                  'normalizedExcess': (degradation - allowed) / allowed,
                                  'evidence': a['evidence'] + b['evidence']})
                normalized = [p['normalizedExcess'] for p in pairs]
                center = statistics.median(normalized)
                mad = statistics.median(abs(x - center) for x in normalized)
                orders = {order: statistics.median(p['excess'] for p in pairs if p['order'] == order)
                          for order in ('AB', 'BA')}
                median = statistics.median(p['excess'] for p in pairs)
                interval = bootstrap(pairs)
                state = 'inconclusive'
                if mad <= suite['maxNormalizedMAD'] and (orders['AB'] > 0) == (orders['BA'] > 0):
                    if interval['lower'] > 0:
                        state = 'regressed'
                    elif interval['upper'] <= 0:
                        state = 'passed'
                result['metrics'].append({'scenario': scenario, 'metric': name, **threshold, 'pairs': pairs,
                                          'medianExcess': median, 'orderMedianExcess': orders,
                                          'confidenceInterval': interval,
                                          'normalizedMAD': mad, 'maxNormalizedMAD': suite['maxNormalizedMAD'],
                                          'rawRange': {'baseline': [min(p['baseline'] for p in pairs), max(p['baseline'] for p in pairs)],
                                                       'candidate': [min(p['candidate'] for p in pairs), max(p['candidate'] for p in pairs)]},
                                          'decision': state})
        if any(m['decision'] == 'inconclusive' for m in result['metrics']):
            return blocked(result, 'noise budget exceeded or opposite orders disagree', 'valid', 'inconclusive')
        regression = any(m['decision'] == 'regressed' for m in result['metrics'])
        result.update(status='failed' if regression else 'passed', validity='valid',
                      decision='regressed' if regression else 'passed', exitCode=1 if regression else 0)
        return result
    except (OSError, ValueError, KeyError, TypeError, AttributeError, OverflowError) as error:
        return blocked(result, str(error))


def save_report(root, report):
    write(root / 'report.json', report)
    lines = ['# Performance boundary report', '',
             f"{report['suite']}: **{report['status']}** / {report['decision']} (exit {report['exitCode']})", '',
             'Validity: ' + report['validity'], '',
             'Provisional budgets; deterministic paired screen, no statistical significance claim.', '']
    lines.extend('- ' + reason for reason in report['reasons'])
    for key in ('subjects', 'session', 'policySHA256', 'harnessSHA256'):
        lines.extend(['', f'{key}: `{json.dumps(report.get(key), sort_keys=True)}`'])
    for metric in report['metrics']:
        lines += ['', f"## {metric['scenario']} / {metric['metric']}: {metric['decision']}", '',
                  f"Unit: {metric['unit']}; direction: {metric['direction']}; relative: {metric['relative']}; absolute: {metric['absolute']}.",
                  f"Median paired excess: {metric['medianExcess']}; order medians: {metric['orderMedianExcess']}; normalized MAD: {metric['normalizedMAD']} (budget {metric['maxNormalizedMAD']}).", '',
                  f"95% paired excess interval: [{metric['confidenceInterval']['lower']}, {metric['confidenceInterval']['upper']}]; {metric['confidenceInterval']['method']}.", '',
                  '| Pair/order | Baseline | Candidate | Delta | Allowed | Excess |',
                  '| --- | ---: | ---: | ---: | ---: | ---: |']
        lines += [f"| {p['pair']}/{p['order']} | {p['baseline']:.6g} | {p['candidate']:.6g} | {p['delta']:.6g} | {p['allowed']:.6g} | {p['excess']:.6g} |" for p in metric['pairs']]
    lines += ['', 'Full original values, identity, policy and evidence hashes are retained in JSON.', '']
    (root / 'report.md').write_text('\n'.join(lines))
