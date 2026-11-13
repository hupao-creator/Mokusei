#!/usr/bin/env python3
"""Standalone artifact-based Overview benchmark; Python 3.10+ standard library."""
import argparse
import json
from pathlib import Path
import sys

from contracts.model import SCENARIOS
from workload import DEFAULT_PACING, RATES


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    commands=parser.add_subparsers(dest='command',required=True)
    build=commands.add_parser('build',help='compile only independent macOS collectors')
    build.add_argument('--tools',type=Path,required=True)
    calibrate=commands.add_parser('calibrate',help='live pixel/hitch/process controls and interference pair')
    calibrate.add_argument('--tools',type=Path,required=True);calibrate.add_argument('--output',type=Path,required=True)
    run=commands.add_parser('run',help='measure an already-built signed production artifact')
    run.add_argument('--app',type=Path,required=True);run.add_argument('--tools',type=Path,required=True)
    run.add_argument('--output',type=Path,required=True);run.add_argument('--capabilities',type=Path)
    run.add_argument('--count',type=int,nargs='+',choices=(5,10,20),default=[5,10,20])
    run.add_argument('--scenario',nargs='+',choices=SCENARIOS,
                     default=[s for s in SCENARIOS if 'zoom' not in s],
                     help='default: the six supported Overview scenarios')
    run.add_argument('--mode',choices=('observed','minimal'),default='observed')
    run.add_argument('--seconds',type=float,default=8)
    run.add_argument('--pacing',choices=tuple(RATES),default=DEFAULT_PACING,
                     help='sparse (default): low-rate output; sustained/burst: explicit stress loads')
    run.add_argument('--chunk-bytes',type=int,default=64);run.add_argument('--message-bytes',type=int,default=512)
    analyze=commands.add_parser('analyze',help='offline reanalysis; does not reseal or change evidence')
    analyze.add_argument('directory',type=Path)
    commands.add_parser('conformance',help='portable adverse protocol/scorer replays')
    args=parser.parse_args()
    if args.command=='conformance':
        from conformance.replay import main as replay
        return replay()
    if args.command=='analyze':
        from analysis.report import write_report
        result=write_report(args.directory)
        print(json.dumps(result,indent=2))
        return 0 if result['measurement']=='valid' and result['product']=='passed' else 2
    if sys.platform!='darwin':parser.error('live collection requires macOS; conformance/analyze are portable')
    from build import build as build_tools
    tools=build_tools(args.tools.resolve())
    if args.command=='build': print(tools);return 0
    from runner import calibrate as calibrate_controls, run_suite
    if args.command=='calibrate':
        result=calibrate_controls(tools,args.output.resolve())
        print(json.dumps(result,indent=2));return 0 if result['passed'] and result['pixelsPassed'] else 2
    if not 4<=args.seconds<=120:parser.error('--seconds must be 4..120')
    if len(set(args.count))!=len(args.count):
        parser.error('duplicate counts require separate experiment directories')
    results=run_suite(tools,args.app.resolve(),args.output.resolve(),args.count,args.scenario,args.mode,args.seconds,
                      args.capabilities.resolve() if args.capabilities else None,args.pacing,args.chunk_bytes,args.message_bytes)
    print(json.dumps([{k:r.get(k) for k in ('path','measurement','product','comparison','reasons')} for r in results],indent=2))
    # Exit 2 means an incomplete/unsupported experiment, never a performance gate.
    return 0 if results and all(r['measurement']=='valid' and r['product']=='passed' for r in results) else 2


if __name__=='__main__':
    raise SystemExit(main())
