#!/usr/bin/env python3
"""Versioned performance campaigns, regression judgment and explicit baselines."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ET

from gate.engine import catalog, digest, judge, read, require, save_report, sha, text, write
from gate.runner import BENCHMARKS, ROOT, phase, run, utc


def baseline_revision(value, suite, policy_digest):
    require(type(value) is dict, 'baseline manifest must be an object')
    require(type(value.get('schemaVersion')) is int and value['schemaVersion'] == 1 and
            value.get('kind') == 'performance-baseline', 'unsupported baseline version/kind')
    require(value.get('suite') == suite and value.get('policySHA256') == policy_digest,
            'baseline suite/policy identity differs')
    for key in ('reviewer', 'reason', 'approvedAt'):
        require(bool(text(value.get(key), 'baseline ' + key).strip()), 'baseline metadata cannot be blank')
    sha(value.get('reportSHA256'), 'baseline report digest')
    sha(value.get('revision'), 'baseline revision', 40)
    return value['revision']


def publish_exclusive(path, data):
    # Publish complete bytes without replacing an existing approval/snapshot,
    # including when two commands race. Failed writes leave no partial approval.
    descriptor, temporary = tempfile.mkstemp(prefix='.promotion-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, path)
    finally:
        os.unlink(temporary)


def promote_report(bundle, report, output, reviewer, reason):
    require(report['exitCode'] == 0, 'only a revalidated passing campaign can be promoted')
    for value, label in ((reviewer, 'reviewer'), (reason, 'reason')):
        require(bool(text(value, label).strip()), label + ' required')
    require(not output.exists() and not output.is_symlink(), 'approval output already exists')
    payload = (json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + '\n').encode()
    report_digest = hashlib.sha256(payload).hexdigest()
    snapshots = bundle / 'approved-reports'
    require(not snapshots.is_symlink(), 'approved reports directory cannot be a symlink')
    snapshots.mkdir(exist_ok=True)
    snapshot = snapshots / (report_digest + '.json')
    try:
        publish_exclusive(snapshot, payload)
    except FileExistsError:
        require(not snapshot.is_symlink() and snapshot.read_bytes() == payload, 'approved snapshot differs')
    approval = {'schemaVersion': 1, 'kind': 'performance-baseline', 'suite': report['suite'],
                'revision': report['subjects']['candidate']['revision'], 'policySHA256': report['policySHA256'],
                'reportSHA256': report_digest, 'reportSnapshot': str(snapshot.relative_to(bundle)),
                'reviewer': reviewer, 'reason': reason, 'approvedAt': utc()}
    publish_exclusive(output, (json.dumps(approval, indent=2) + '\n').encode())
    return approval


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path, default=BENCHMARKS / 'gate/catalog.json')
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('list')
    capability = commands.add_parser('capabilities')
    capability.add_argument('--output', type=Path, required=True)
    binding = commands.add_parser('bind-artifact')
    binding.add_argument('--app', type=Path, required=True)
    binding.add_argument('--revision', required=True)
    binding.add_argument('--output', type=Path, required=True)
    trace = commands.add_parser('trace')
    trace.add_argument('--executable', type=Path, required=True)
    trace.add_argument('--template', choices=('Metal System Trace', 'Animation Hitches', 'App Launch'), default='Metal System Trace')
    trace.add_argument('--seconds', type=int, default=3)
    trace.add_argument('--output', type=Path, required=True)
    trace.add_argument('arguments', nargs=argparse.REMAINDER)
    trace_analysis = commands.add_parser('trace-analyze')
    trace_analysis.add_argument('table', type=Path)
    trace_analysis.add_argument('--pid', type=int, required=True)
    trace_analysis.add_argument('--output', type=Path, required=True)
    collect = commands.add_parser('run')
    collect.add_argument('--suite', required=True)
    baseline = collect.add_mutually_exclusive_group(required=True)
    baseline.add_argument('--baseline')
    baseline.add_argument('--baseline-manifest', type=Path)
    collect.add_argument('--candidate', required=True)
    collect.add_argument('--output', type=Path, required=True)
    collect.add_argument('--go', default=shutil.which('go') or str(ROOT / 'scripts/go.sh'))
    collect.add_argument('--configure-display', action='store_true')
    for name in ('baseline-artifact', 'candidate-artifact', 'tools', 'capabilities'):
        collect.add_argument('--' + name, type=Path)
    evaluate = commands.add_parser('judge')
    evaluate.add_argument('bundle', type=Path)
    promote = commands.add_parser('promote')
    promote.add_argument('bundle', type=Path)
    promote.add_argument('--output', type=Path, required=True)
    promote.add_argument('--reviewer', required=True)
    promote.add_argument('--reason', required=True)
    args = parser.parse_args()
    report = None
    try:
        if args.command == 'trace-analyze':
            from gate.trace import gpu_observation
            require(args.pid > 0, 'target PID must be positive')
            value = gpu_observation(args.table, args.pid)
            with args.output.open('x') as stream:
                stream.write(json.dumps(value, indent=2) + '\n')
            return 0 if value['status'] == 'observed-diagnostic' else 2
        if args.command == 'trace':
            from gate.trace import collect
            args.output = args.output.resolve()
            args.output.mkdir(parents=True, exist_ok=False)
            arguments = args.arguments[1:] if args.arguments[:1] == ['--'] else args.arguments
            report = collect(args.output, args.executable, arguments, args.template, args.seconds)
            print(args.output / 'report.md')
            return report['exitCode']
        if args.command == 'capabilities':
            from gate.capabilities import probe
            args.output.mkdir(parents=True, exist_ok=False)
            result = probe(args.output)
            print(args.output / 'capabilities.md')
            return 2 if any(v['status'] == 'unsupported' for v in result['capabilities'].values()) else 0
        if args.command == 'bind-artifact':
            from gate.ux import artifact
            value = artifact(args.app, args.revision)
            with args.output.open('x') as stream:
                stream.write(json.dumps(value, indent=2) + '\n')
            return 0
        if args.command in ('list', 'run'):
            policy = catalog(read(args.catalog))
            if args.command == 'list':
                print(json.dumps(policy, indent=2))
                return 0
            require(args.suite in policy['suites'], 'unknown suite')
            baseline = args.baseline
            if args.baseline_manifest:
                baseline = baseline_revision(read(args.baseline_manifest), args.suite, digest(args.catalog))
            sha(baseline, 'baseline revision', 40)
            sha(args.candidate, 'candidate revision', 40)
            args.output = args.output.resolve()
            args.output.mkdir(parents=True, exist_ok=False)
            run(args.output, args.catalog.resolve(), args.suite, baseline, args.candidate, args.go, args.configure_display,
                {name: getattr(args, name) for name in ('baseline_artifact', 'candidate_artifact', 'tools', 'capabilities')})
            bundle = args.output
        else:
            bundle = args.bundle.resolve()
        report = judge(bundle)
        phase(report, 'judge')
        phase(report, 'report')
        if args.command == 'promote':
            approval = promote_report(bundle, report, args.output, args.reviewer, args.reason)
            print(json.dumps({'kind': 'performance-promotion-result', 'status': 'approved', 'exitCode': 0,
                              'performanceExitCode': report['exitCode'], 'approval': str(args.output),
                              'reportSHA256': approval['reportSHA256'], 'reportSnapshot': approval['reportSnapshot']}))
            return 0
        save_report(bundle, report)
        print(f"{report['suite']}: {report['status']} / {report['decision']} — {bundle / 'report.md'}")
        return report['exitCode']
    except (OSError, ValueError, KeyError, TypeError, ET.ParseError) as error:
        if args.command == 'promote':
            print(json.dumps({'kind': 'performance-promotion-result', 'status': 'rejected', 'exitCode': 2,
                              'performanceExitCode': report['exitCode'] if report else None, 'reason': str(error)}))
        print(str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
