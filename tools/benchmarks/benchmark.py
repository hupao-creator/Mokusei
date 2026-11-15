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
    from badge_comparison import SCENARIOS as BADGE_SCENARIOS
    compare=commands.add_parser('compare-badge',help='balanced flat / Liquid Glass Agent emoji badge observations')
    run=commands.add_parser('run',help='measure an already-built signed production artifact')
    for command in (run,compare):
        command.add_argument('--app',type=Path,required=True);command.add_argument('--tools',type=Path,required=True)
        command.add_argument('--output',type=Path,required=True);command.add_argument('--capabilities',type=Path)
        command.add_argument('--count',type=int,nargs='+',choices=(5,10,20),default=[10] if command is compare else [5,10,20])
        command.add_argument('--scenario',nargs='+',choices=BADGE_SCENARIOS if command is compare else SCENARIOS,
            default=list(BADGE_SCENARIOS) if command is compare else [s for s in SCENARIOS if 'zoom' not in s])
        command.add_argument('--seconds',type=float,default=8)
        command.add_argument('--warmup-seconds',type=float,default=6 if command is compare else 1)
        command.add_argument('--window-bounds',type=float,nargs=4,metavar=('X','Y','WIDTH','HEIGHT'),
            default=[50,60,1280,950] if command is compare else None,
            help='explicit OS window bounds; actual bounds must match before measurement')
        command.add_argument('--pacing',choices=tuple(RATES),default=DEFAULT_PACING,
            help='sparse (default): low-rate output; sustained/burst: explicit stress loads')
        command.add_argument('--chunk-bytes',type=int,default=64);command.add_argument('--message-bytes',type=int,default=512)
    run.add_argument('--mode',choices=('observed','minimal'),default='observed')
    run.add_argument('--agent-emoji-badge',choices=('flat','liquid-glass'),
        help='explicit badge experiment; requires a supporting artifact and its configuration receipt')
    compare.set_defaults(native_hitches=False)
    for command in (build,calibrate,run):
        command.add_argument('--native-hitches',action='store_true',
            help='explicit XCTest diagnostic; requires pre-authorized Developer Tools access; never part of the default run')
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
    if args.native_hitches:
        from hitches import preflight
        try:preflight()
        except RuntimeError as error:parser.error(str(error))
    tools=build_tools(args.tools.resolve(),native_hitches=args.native_hitches)
    if args.command=='build': print(tools);return 0
    from runner import calibrate as calibrate_controls, run_suite
    if args.command=='calibrate':
        result=calibrate_controls(tools,args.output.resolve(),native_hitches=args.native_hitches)
        print(json.dumps(result,indent=2));return 0 if result['passed'] and result['pixelsPassed'] else 2
    if not 4<=args.seconds<=120:parser.error('--seconds must be 4..120')
    if not .05<=args.warmup_seconds<=120:parser.error('--warmup-seconds must be .05..120')
    if len(set(args.scenario))!=len(args.scenario):parser.error('duplicate scenarios require separate experiment directories')
    bounds=dict(zip(('x','y','width','height'),args.window_bounds)) if args.window_bounds else None
    if bounds:
        from contracts.model import number
        try:
            for key,value in bounds.items():number(value,key,*((-100_000,100_000) if key in ('x','y') else (100,16384)))
        except ValueError as error:parser.error(str(error))
    if len(set(args.count))!=len(args.count):
        parser.error('duplicate counts require separate experiment directories')
    if args.command=='compare-badge':
        from badge_comparison import run as compare_badges
        summary=compare_badges(tools,args.app.resolve(),args.output.resolve(),args.count,args.scenario,args.seconds,
            args.capabilities.resolve() if args.capabilities else None,args.pacing,args.chunk_bytes,args.message_bytes,
            args.warmup_seconds,bounds)
        print(args.output.resolve()/'badge-comparison.md')
        return 2  # Descriptive observations never certify the incomplete full benchmark.
    results=run_suite(tools,args.app.resolve(),args.output.resolve(),args.count,args.scenario,args.mode,args.seconds,
                      args.capabilities.resolve() if args.capabilities else None,args.pacing,args.chunk_bytes,args.message_bytes,
                      native_hitches=args.native_hitches,emoji_badge=args.agent_emoji_badge,
                      warmup_seconds=args.warmup_seconds,window_bounds=bounds)
    print(json.dumps([{k:r.get(k) for k in ('path','measurement','product','comparison','reasons')} for r in results],indent=2))
    # Exit 2 means an incomplete/unsupported experiment, never a performance gate.
    return 0 if results and all(r['measurement']=='valid' and r['product']=='passed' for r in results) else 2


if __name__=='__main__':
    raise SystemExit(main())
