#!/usr/bin/env python3
"""CLI-level generated properties and end-to-end failure/promotion paths.

Synthetic measurements exercise the actual shipped command. They are not product
performance results and do not duplicate its regression calculation.
"""
import argparse
import copy
import json
from pathlib import Path
import random
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gate.engine import digest, identity, read, reference, write

CLI = Path(__file__).resolve().parents[1] / 'performance.py'


def fixture(path, base=1000, candidate=1000, direction='lower'):
    path.mkdir(parents=True)
    suite = {'version': 1, 'documentation': 'gate/README.md', 'calibration': 'synthetic-contract-fixture',
             'adapter': 'runtime', 'pairCount': 6, 'budgetSeconds': 10, 'maxNormalizedMAD': 1,
             'scenarios': ['fixture'], 'workload': {'records': 1},
             'metrics': {'cost': {'unit': 'synthetic', 'direction': direction, 'relative': .15, 'absolute': 10}}}
    write(path / 'catalog.json', {'schemaVersion': 1, 'kind': 'performance-catalog', 'suites': {'synthetic': suite}})
    session = {k: 'synthetic-only' for k in ('id', 'runner', 'os', 'architecture', 'hardware', 'toolchain', 'mode')}
    campaign = {'schemaVersion': 1, 'kind': 'performance-campaign', 'suite': 'synthetic', 'runId': path.name,
                'analysisSHA256': digest(Path(__file__).with_name('engine.py')),
                'policySHA256': digest(path / 'catalog.json'), 'harnessSHA256': 'a' * 64, 'session': session,
                'validity': 'valid', 'cleanup': 'passed', 'phases': [], 'reasons': [],
                'subjects': {side: {'revision': letter * 40, 'artifactSHA256': letter * 64}
                             for side, letter in (('baseline', 'b'), ('candidate', 'c'))}, 'runs': []}
    for pair in range(6):
        for side in ('baseline', 'candidate'):
            row = {'id': f'{pair}-{side}', 'scenario': 'fixture', 'pair': pair, 'side': side,
                   'order': 'AB' if pair % 2 == 0 else 'BA', 'validity': 'valid', 'product': 'passed',
                   'artifactSHA256': campaign['subjects'][side]['artifactSHA256'],
                   'identity': {'session': session, 'harnessSHA256': campaign['harnessSHA256'], 'suiteVersion': 1, 'workload': suite['workload']},
                   'comparison': {'fixture': 'synthetic'}, 'metrics': {'cost': base if side == 'baseline' else candidate}}
            campaign['runs'].append(row)
    persist(path, campaign)
    return campaign


def persist(path, campaign):
    for row in campaign['runs']:
        raw = path / (row['id'] + '.json')
        write(raw, {k: v for k, v in row.items() if k not in ('evidence', 'observation')})
        row.update(observation=raw.name, evidence=[reference(path, raw)])
    campaign['evidence'] = [reference(path, p) for p in sorted(path.glob('*.json'))
                            if p.name not in ('catalog.json', 'campaign.json', 'report.json', 'approval.json')]
    campaign['policySHA256'] = digest(path / 'catalog.json')
    write(path / 'campaign.json', campaign)


def cli(args, expected, report=None):
    result = subprocess.run([sys.executable, str(CLI), *map(str, args)], capture_output=True, text=True, timeout=30)
    if result.returncode != expected:
        raise AssertionError(f'{args}: expected {expected}, got {result.returncode}\n{result.stdout}\n{result.stderr}')
    if report:
        value = read(report / 'report.json')
        assert value['exitCode'] == expected, 'process exit and report disagree'
        return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--examples', type=int, default=40)
    parser.add_argument('--seed', type=int, default=67421)
    args = parser.parse_args()
    assert args.examples > 0
    args.output.mkdir(parents=True, exist_ok=False)
    rng = random.Random(args.seed)
    checks = []
    try:
        for index in range(args.examples):
            # Generate many scales and both directions. Improvements preserve a
            # passing identity; a deliberately large degradation fails in either
            # direction. No expected calculation mirrors the production judge.
            base = rng.uniform(1000, 1000000)
            direction = rng.choice(('lower', 'higher'))
            path = args.output / f'property-{index:03d}'
            campaign = fixture(path, base, base, direction)
            cli(['judge', path], 0, path)
            for row in campaign['runs']:
                if row['side'] == 'candidate':
                    row['metrics']['cost'] = base * (.5 if direction == 'lower' else 2)
            persist(path, campaign)
            cli(['judge', path], 0, path)
            changed = base * (2 if direction == 'lower' else .1)
            for row in campaign['runs']:
                if row['side'] == 'candidate':
                    row['metrics']['cost'] = changed
            persist(path, campaign)
            first = cli(['judge', path], 1, path)
            rng.shuffle(campaign['runs'])
            persist(path, campaign)
            second = cli(['judge', path], 1, path)
            assert first['metrics'] == second['metrics'], 'run inventory permutation changed judgment'
            scale = rng.uniform(.001, 100)
            policy = read(path / 'catalog.json')
            policy['suites']['synthetic']['metrics']['cost']['absolute'] *= scale
            write(path / 'catalog.json', policy)
            for row in campaign['runs']:
                row['metrics']['cost'] *= scale
            persist(path, campaign)
            cli(['judge', path], 1, path)
            invalid = copy.deepcopy(policy)
            metric = invalid['suites']['synthetic']['metrics']
            if rng.choice((False, True)):
                metric['cost'] = rng.choice((None, bool(rng.getrandbits(1)),
                                           [rng.randrange(100)], str(rng.randrange(100))))
            else:
                metric['cost']['relative'] = 10 ** rng.randrange(330, 480)
            invalid_path = path / 'invalid-catalog.json'
            write(invalid_path, invalid)
            cli(['--catalog', invalid_path, 'list'], 2)
            checks.append('identity/degradation/direction/permutation/scale/catalog-rejection:' + str(index))
        mutations = {
            'missing-run': lambda c: c['runs'].pop(),
            'missing-metric': lambda c: c['runs'][0]['metrics'].clear(),
            'null-metric': lambda c: c['runs'][0]['metrics'].update(cost=None),
            'boolean-metric': lambda c: c['runs'][0]['metrics'].update(cost=True),
            'invalid': lambda c: c['runs'][0].update(validity='invalid'),
            'unsupported': lambda c: c.update(validity='unsupported'),
            'cleanup': lambda c: c.update(cleanup='failed'),
            'incomparable': lambda c: c['runs'][0].update(comparison={'fixture': 'different'}),
            'wrong-version': lambda c: c.update(schemaVersion=2),
            'boolean-version': lambda c: c.update(schemaVersion=True),
            'different-analysis': lambda c: c.update(analysisSHA256='d'*64),
            'artifact': lambda c: c['runs'][0].update(artifactSHA256='f'*64),
            'runner': lambda c: c['runs'][0].update(identity={}),
            'functional': lambda c: c['runs'][0].update(product='wrong-result'),
            'order': lambda c: c['runs'][0].update(order='BA'),
            'uncertainty': lambda c: [r['metrics'].update(cost={'lower': 0, 'upper': 3000}) for r in c['runs']],
            'order-disagreement': lambda c: [r['metrics'].update(cost=2000 if r['order']=='AB' else 500) for r in c['runs'] if r['side']=='candidate'],
        }
        for name, mutate in mutations.items():
            path = args.output / name
            campaign = fixture(path)
            mutate(campaign)
            persist(path, campaign)
            cli(['judge', path], 2, path)
            checks.append(name)
        for name, action in (
            ('changed-evidence', lambda p: (p / '0-baseline.json').write_text('{}')),
            ('absent-evidence', lambda p: (p / '0-baseline.json').unlink()),
            ('duplicate-json', lambda p: (p / 'campaign.json').write_text('{"schemaVersion":1,"schemaVersion":1}')),
            ('nonfinite-json', lambda p: (p / 'campaign.json').write_text('{"bad":NaN}')),
        ):
            path = args.output / name
            fixture(path); action(path)
            cli(['judge', path], 2, path)
            checks.append(name)
        path = args.output / 'changed-normalization'
        campaign = fixture(path)
        campaign['runs'][0]['metrics']['cost'] = 10
        write(path / 'campaign.json', campaign)  # No resealing the original observation.
        cli(['judge', path], 2, path)
        checks.append('normalized-values-bound-to-evidence')
        # Metamorphic ownership/union properties through the public trace parser:
        # duplicates, interval translation and unrelated process activity cannot
        # inflate the target GPU active duration.
        import xml.etree.ElementTree as ET
        for index in range(12):
            start, width = rng.randrange(10000), rng.randrange(1, 10000)
            durations = []
            for variant, shift in (('original', 0), ('translated', 100000)):
                tree = ET.Element('trace-query-result')
                schema = ET.SubElement(tree, 'schema', name='metal-gpu-intervals')
                for name in ('start', 'duration', 'state', 'event-depth', 'process'):
                    ET.SubElement(ET.SubElement(schema, 'col'), 'mnemonic').text = name
                rows = [(start+shift, width, 55), (start+shift, width, 55), (0, width*100, 99)]
                rng.shuffle(rows)
                for begin, duration, pid in rows:
                    row = ET.SubElement(tree, 'row')
                    for tag, value in (('start-time', begin), ('duration', duration), ('gpu-state', 'Active'), ('metal-nesting-level', 0)):
                        ET.SubElement(row, tag).text = str(value)
                    ET.SubElement(ET.SubElement(row, 'process'), 'pid').text = str(pid)
                xml = args.output / f'gpu-{index}-{variant}.xml'
                xml.write_text(ET.tostring(tree, encoding='unicode'))
                result = args.output / f'gpu-{index}-{variant}.json'
                cli(['trace-analyze', xml, '--pid', 55, '--output', result], 0)
                observation = read(result)
                assert observation['value'] == width/1e9 and observation['gateEligible'] is False
                durations.append(observation['value'])
            assert durations[0] == durations[1]
        checks.append('GPU-ownership-duplicate-translation-properties:12')
        path = args.output / 'promotion'
        fixture(path)
        cli(['promote', path, '--output', path/'approval.json', '--reviewer', 'CLI-e2e', '--reason', 'synthetic verification only'], 0, path)
        before = (path / 'approval.json').read_bytes()
        cli(['promote', path, '--output', path/'approval.json', '--reviewer', 'CLI-e2e', '--reason', 'must not replace'], 2)
        assert (path / 'approval.json').read_bytes() == before
        (path / '0-baseline.json').write_text('{}')
        cli(['promote', path, '--output', path/'bad.json', '--reviewer', 'CLI-e2e', '--reason', 'must revalidate'], 2, path)
        assert not (path / 'bad.json').exists()
        checks.append('promotion-is-explicit-exclusive-and-revalidated')
        path = args.output / 'unsupported-command'
        cli(['run', '--suite', 'ux-zoom', '--baseline', 'b'*40, '--candidate', 'c'*40, '--output', path], 2, path)
        cli(['run', '--suite', 'ux-zoom', '--baseline', 'b'*40, '--candidate', 'c'*40, '--output', path], 2)
        checks.append('unsupported-command-and-output-exclusivity')
    except BaseException as error:
        write(args.output / 'verification.json', {'kind': 'synthetic-gate-verification', 'passed': False,
              'seed': args.seed, 'completed': checks, 'error': str(error)})
        raise
    write(args.output / 'verification.json', {'kind': 'synthetic-gate-verification', 'passed': True,
          'seed': args.seed, 'examples': args.examples, 'checks': checks, 'productPerformanceMeasured': False})
    print(f'Passed {len(checks)} generated property/e2e groups; evidence: {args.output}')


if __name__ == '__main__':
    main()
