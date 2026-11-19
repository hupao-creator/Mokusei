#!/usr/bin/env python3
"""CLI e2e of explicit Rapid replay using the real Runtime admission property.

Generated malformed inputs must never fall back to random success. A temporary
Go overlay injects an oracle failure after the real property, then its removal
demonstrates a fixed counterexample without changing the product or its oracle.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
RUNNER = Path(__file__).with_name('run.py')
PROPERTY = ROOT / 'tools/verification/pbt/runtime/send_property_test.go'
CORPUS = PROPERTY.parent / 'testdata/rapid/TestSendAdmissionProperties/TestSendAdmissionProperties-rejected-follow-up.fail'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--examples', type=int, default=8)
    parser.add_argument('--seed', type=int, default=1729)
    parser.add_argument('--go', default='./scripts/go.sh' if sys.platform == 'darwin' else 'go')
    args = parser.parse_args()
    if args.examples < 1:
        parser.error('examples must be positive')
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    rng = random.Random(args.seed)
    checks = []
    result = {'kind': 'rapid-replay-cli-e2e', 'seed': args.seed, 'examples': args.examples,
              'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
              'status': subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True),
              'checks': checks, 'passed': False, 'productPerformanceMeasured': False}

    def replay(name, failfile, expected, *, overlay=None):
        output = args.output / name
        argv = [sys.executable, str(RUNNER), '--property', 'PBT-RUNTIME-ADMISSION', '--cases', '3',
                '--seed', str(args.seed), '--failfile', str(failfile), '--artifacts', str(output), '--go', args.go, '--timeout', '90']
        env = dict(os.environ)
        if overlay:
            env['GOFLAGS'] = env.get('GOFLAGS', '') + ' -overlay=' + str(overlay)
        child = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True, timeout=100)
        receipt = {'argv': argv, 'exitCode': child.returncode, 'stdout': child.stdout, 'stderr': child.stderr,
                   'overlay': str(overlay) if overlay else None}
        (args.output / (name + '.command.json')).write_text(json.dumps(receipt, indent=2) + '\n')
        assert child.returncode == expected, receipt
        summary = json.loads((output/'summary.json').read_text())
        item = summary['properties'][0]
        assert summary['exitCode'] == expected and item['exitCode'] == expected
        assert item['replay']['sha256'] == hashlib.sha256(failfile.read_bytes()).hexdigest()
        assert (output/item['replay']['artifact']).read_bytes() == failfile.read_bytes()
        assert item['replay']['status'] == {0: 'passed', 1: 'failed', 2: 'invalid'}[expected]
        if expected == 0:
            assert item['generatedCases'] == 3, 'explicit replay replaced generated checks'
        else:
            assert 'generatedCases' not in item, 'invalid/failing replay fell through to random checks'
        checks.append(name)

    try:
        valid = args.output / 'valid.fail'
        valid.write_bytes(CORPUS.read_bytes())
        replay('valid-fixed-corpus', valid, 0)
        for index in range(args.examples):
            number = rng.getrandbits(64)
            data = (f'corrupt-{number}\n', f'v{number}.0#1729\n0x0\n',
                    f'v0.4.8#1729\n0x{number:x}invalid\n', 'v0.4.8#1729\n')[index % 4]
            invalid = args.output / f'invalid-{index}.fail'
            invalid.write_text(data)
            replay(f'reject-{index}', invalid, 2)
        source = PROPERTY.read_text()
        ending = '\n\t})\n}'
        assert source.count(ending) == 1, 'oracle injection location changed'
        mutated = args.output / 'send_property_test.go'
        mutated.write_text(source.replace(ending, '\n\t\tt.Fatal("replay CLI injected oracle failure")' + ending))
        overlay = args.output / 'overlay.json'
        overlay.write_text(json.dumps({'Replace': {str(PROPERTY): str(mutated)}}) + '\n')
        result['oracleInjection'] = {'source': str(PROPERTY.relative_to(ROOT)),
                                    'overlay': str(overlay), 'sha256': hashlib.sha256(mutated.read_bytes()).hexdigest()}
        replay('valid-failing-oracle', valid, 1, overlay=overlay)
        replay('valid-fixed-after-injection', valid, 0)
        result['passed'] = True
    finally:
        (args.output/'verification.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f'Passed {len(checks)} replay CLI e2e paths; evidence: {args.output}')


if __name__ == '__main__':
    main()
