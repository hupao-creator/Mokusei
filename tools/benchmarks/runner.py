"""Fixed-clock experiments against an owned OS application and public protocols."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time
import uuid

from contracts.model import CLOCK, plan as validate_plan
from lifecycle import native, save, sha256
from analysis.report import seal, write_report
from hitches import Hitches

FRAMEWORK_FILES = {str(p.relative_to(Path(__file__).parent)): sha256(p)
                   for p in sorted(Path(__file__).parent.rglob('*'))
                   if p.is_file() and p.suffix in ('.py','.swift','.c','.h')}


def clock_bracket(helper):
    before = time.monotonic_ns()
    probe = native(helper, 'probe')
    return {'beforeNS': before, 'afterNS': time.monotonic_ns(), 'helper': probe}


def trajectory(bounds, seconds):
    # This operates a blank canvas margin, not a card's text selection surface.
    x, y = bounds['x'] + bounds['width'] - 70, bounds['y'] + bounds['height'] - 110
    events = [{'kind': 'move', 'atSeconds': .15, 'x': x, 'y': y},
              {'kind': 'down', 'atSeconds': .4, 'x': x, 'y': y}]
    duration = seconds - .9
    for n in range(1, round(duration * 60)):
        t = n / 60
        phase = t / duration
        dx = -120 * (2 * phase if phase <= .5 else 2 * (1 - phase))
        events.append({'kind': 'drag', 'atSeconds': .4 + t, 'x': x + dx, 'y': y + .3 * dx})
    events.append({'kind': 'up', 'atSeconds': seconds - .4, 'x': x, 'y': y})
    return events


def make_plan(owner, roots, scenario, count, mode, seconds=8, anchors=None):
    return {'version': 1, 'kind': 'plan', 'clock': CLOCK, 'scenario': scenario, 'count': count, 'mode': mode,
            'targetKind':'application', 'pid': owner['process']['pid'], 'processIdentity': owner['process']['identity'],
            'windowID': owner['windowID'], 'windowBounds': owner['bounds'], 'startNS': time.monotonic_ns() + 2_000_000_000,
            'warmupSeconds': 1.0, 'formalSeconds': float(seconds), 'tailSeconds': 2.0,
            'sampleHz': 10.0, 'captureHz': 5.0, 'maximumNoProgressSeconds': .65,
            'maximumCaptureGapSeconds': .65, 'motionTolerancePixels': 14.0,
            'anchors': anchors or [f'BENCH CARD {n:02d}' for n in range(1, count + 1)],
            'processRoots': roots, 'events': trajectory(owner['bounds'], seconds) if 'pan' in scenario else []}


def recognize_frames(helper, directory):
    observation = json.loads((directory/'observation.json').read_text())
    with (directory/'frames.jsonl').open('w') as stream:
        for capture in observation['frames']:
            ocr = native(helper, 'ocr', directory/capture['image'])
            stream.write(json.dumps({**capture, 'texts': ocr['texts']}) + '\n')


def collect(tools, directory, plan, bundle, capability=None, arm=None, fault=None, checkpoint=None):
    helper = tools/'collector'
    before = clock_bracket(helper)
    save(directory/'identity.json', {'owner': native(helper, 'process', plan['pid']),
         'collectorSHA256': sha256(helper), 'frameworkFiles': FRAMEWORK_FILES, 'toolBuild': json.loads((tools/'build.json').read_text()),
         'host': before['helper']})
    hitches = None
    hitch_error = None
    if plan['mode'] == 'observed':
        try:
            hitches = Hitches(tools, bundle, plan['pid'], directory)
            ready = hitches.ready()
            for collector_pid in (hitches.process.pid, ready['collectorPID']):
                plan['processRoots'].append({**native(helper, 'process', collector_pid), 'role': 'collector'})
        except Exception as error:
            hitch_error = str(error)
    plan['startNS'] = time.monotonic_ns() + 2_000_000_000
    validate_plan(plan); save(directory/'plan.json', plan)
    if arm: arm(plan['startNS'] + round(plan['warmupSeconds'] * 1e9))
    fault_thread = None
    if fault:
        def apply_fault():
            time.sleep(max(0, (plan['startNS'] + round((plan['warmupSeconds'] + 1.5) * 1e9) - time.monotonic_ns()) / 1e9))
            fault()
        fault_thread = threading.Thread(target=apply_fault); fault_thread.start()
    try:
        with (directory/'collector.log').open('w') as log:
            process = subprocess.run([str(helper), 'collect', str(directory/'plan.json'), str(directory)],
                stdout=log, stderr=subprocess.STDOUT,
                timeout=plan['warmupSeconds']+plan['formalSeconds']+plan['tailSeconds']+15)
        save(directory/'collector-exit.json', {'exitStatus': process.returncode})
        if checkpoint:save(directory/'tail-outcome.json',checkpoint())
    finally:
        if fault_thread: fault_thread.join(timeout=5)
        if hitches:
            record = hitches.finish()
            if capability: record['capability'] = capability
            if hitch_error: record['error'] = hitch_error
            save(directory/'hitch.json', record)
        elif hitch_error: save(directory/'hitch-error.json', {'error': hitch_error})
        save(directory/'clock.json', {'observations': [before, clock_bracket(helper)]})
    if (directory/'observation.json').exists() and plan['mode'] == 'observed':
        recognize_frames(helper, directory)


def control(tools, directory, mode, capability=None, observation_mode="observed"):
    directory.mkdir(parents=True, mode=0o700, exist_ok=False)
    bundle = tools/'Control.app'
    save(directory/'launch-config.json', {'app': str(bundle), 'arguments': [mode, str(directory/'stall')]})
    launched = native(tools/'collector', 'launch', directory/'launch-config.json')
    pid, identity = launched['process']['pid'], launched['process']['identity']
    try:
        time.sleep(.5)
        owner = native(tools/'collector', 'prepare', pid)
        save(directory/'prepared-window.json', owner)
        roots = [{**launched['process'], 'role': 'application'},
                 {**native(tools/'collector', 'process', os.getpid()), 'role': 'source'}]
        plan = make_plan(owner, roots, 'pan', 5, observation_mode, 5,
                         [f'BENCH CARD {n:02d}' for n in range(1, 5)])
        plan['targetKind']='control'
        collect(tools, directory, plan, bundle, capability,
                fault=(lambda: (directory/'stall').write_text('stall')) if mode == 'stall' else None)
        save(directory/'outcome.json', {'status': 'passed', 'oracle': 'control remains owned and running',
                                      'expectedFault': mode})
    finally:
        errors = []
        try:
            native(tools/'collector', 'quit', pid, identity)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                try: actual = native(tools/'collector', 'process', pid)
                except RuntimeError: break
                if actual['identity'] != identity: break
                time.sleep(.1)
            else: errors.append('control did not exit')
        except Exception as error: errors.append(str(error))
        save(directory/'cleanup.json', {'errors': errors})
    seal(directory)
    return write_report(directory)


def calibrate(tools, directory):
    directory.mkdir(parents=True, exist_ok=False, mode=0o700)
    reports = {}
    for mode in ('normal', 'frozen', 'wrong', 'delay', 'stall', 'children'):
        print('Collector control: '+mode, flush=True)
        reports[mode] = control(tools, directory/mode, mode)
    print('Collector control: minimal overhead pair', flush=True)
    reports['minimal'] = control(tools, directory/'minimal', 'normal', observation_mode='minimal')
    wrong_dir = directory/'wrong-owner'; wrong_dir.mkdir()
    save(wrong_dir/'launch-config.json', {'app': str(tools/'Control.app'), 'arguments': ['normal']})
    launched = native(tools/'collector', 'launch', wrong_dir/'launch-config.json')
    save(wrong_dir/'launch.json', launched)
    h = None
    try:
        time.sleep(.5)
        # The target remains live; a wrong birth identity must fail before readiness.
        h = Hitches(tools, tools/'Control.app', launched['process']['pid'], wrong_dir,
                    expected_launch_date=launched['launchDate'] - 10)
        try: h.ready(); rejected = False
        except RuntimeError: rejected = True
        record = h.finish()
        rejected = rejected and record['exitStatus'] != 0 and not record['batches'] and (
            'Error Domain=benchmark-owner Code=1' in (wrong_dir/'hitch-xcodebuild.log').read_text())
    finally:
        if h and not h.done: h.finish()
        native(tools/'collector', 'quit', launched['process']['pid'], launched['process']['identity'])
    normal_values = reports['normal'].get('metrics', {}).get('hitches', {}).get('measurements', [])
    stall_values = reports['stall'].get('metrics', {}).get('hitches', {}).get('measurements', [])
    baseline = {(v['identifier'],v['unit']):v['value'] for v in normal_values}
    increases = [v for v in stall_values if (v['identifier'],v['unit']) in baseline
                 and v['value'] > baseline[v['identifier'],v['unit']]]
    fault = [json.loads(line) for line in (directory/'stall/stall-events.jsonl').read_text().splitlines()]
    real_stall = len(fault) == 2 and fault[1]['atNS'] - fault[0]['atNS'] >= 1_000_000_000
    stalls_detected = reports['stall'].get('product') == 'overloaded' and real_stall
    pixels_passed = reports['normal'].get('product') == 'passed' and all(
        reports[name].get('product') == ('wrong-result' if name=='wrong' else 'overloaded') for name in ('frozen','wrong','delay','stall'))
    children = [json.loads(line) for line in (directory/'children/stall-events.jsonl').read_text().splitlines()]
    child_observation=json.loads((directory/'children/observation.json').read_text())
    sampled_pids={p['pid'] for row in child_observation['resources'] for p in row['processes']}
    missing_children=[event['pid'] for event in children if event.get('kind')=='childExit' and event['pid'] not in sampled_pids]
    child_coverage=bool(missing_children) and child_observation['processCoverage']['complete'] is False
    result = {'version': 1, 'normal': bool(normal_values), 'stall': bool(increases) and stalls_detected,
              'wrongOwner': rejected, 'passed': pixels_passed and bool(normal_values) and bool(increases) and stalls_detected and rejected,
              'pixelsPassed': pixels_passed, 'shortLivedAccountingLimitationExposed': child_coverage,
              'collectorSHA256': sha256(tools/'collector'), 'toolBuild': json.loads((tools/'build.json').read_text()),
              'frameworkFiles': FRAMEWORK_FILES,
              'host': native(tools/'collector','probe'), 'controls': {k:{'measurement':v['measurement'],
                  'product':v['product'],'reasons':v['reasons']} for k,v in reports.items()},
              'hitchIncreases': increases,
              'reason': 'Real main-thread stalls must affect the native metric; zeros are not proof of smoothness.'}
    save(directory/'capabilities.json', result)
    seal(directory)
    return result


def existing_fixture(application,directory):
    from adapter import wait_for
    state=application.runtime.state()
    threads=[{'id':t['id'],'title':t.get('title')} for t in state['threads'] if not t.get('moku') and not t.get('archived')]
    if len(threads)!=application.count or {t['id'] for t in threads}!=set(application.threads.values()):
        raise ValueError('all fixed fixture cards must already exist before the scenario')
    ui=wait_for(application.ui.request,lambda snapshot:snapshot and not snapshot.get('transitioning') and
        len(snapshot.get('threads',[]))==application.count and
        {t['threadId'] for t in snapshot['threads']}==set(application.threads.values()),15)
    fixture={'count':application.count,'threads':sorted(threads,key=lambda t:t['id']),
             'uiThreadIDs':sorted(t['threadId'] for t in ui['threads']),
             'observedNS':time.monotonic_ns(),'runtimeInsertionDeletion':False}
    save(directory/'existing-fixture.json',fixture)
    return fixture


def boundary_outcome(application):
    before=time.monotonic_ns()
    try:
        state=application.runtime.state()
        threads=[{'id':t['id'],'title':t.get('title'),'observation':t['observation']}
                 for t in state['threads'] if not t.get('moku') and not t.get('archived')]
        complete=len(threads)==application.count and {t['id'] for t in threads}==set(application.threads.values()) and all(
            (t['observation'].get('latestExecution') or {}).get('status')=='completed' for t in threads)
        return {'beforeNS':before,'afterNS':time.monotonic_ns(),'status':'completed' if complete else 'pending', 'threads':threads}
    except Exception as error:
        return {'beforeNS':before,'afterNS':time.monotonic_ns(),'status':'unavailable','error':str(error)}


def outcome(application, token=None, executions=None):
    from adapter import wait_for
    from provider import title
    def terminal(state):
        threads = {t['id']:t for t in state['threads'] if not t.get('moku') and not t.get('archived')}
        if set(threads) != set(application.threads.values()):
            raise ValueError('fixed fixture count or thread identities changed')
        for n, tid in application.threads.items():
            thread = threads[tid]
            execution = thread.get('observation', {}).get('latestExecution') or {}
            if thread.get('title') != title(n): raise ValueError('stable title changed during workload')
            if execution.get('status') in ('failed', 'interrupted'): raise ValueError('task did not complete: '+str(execution))
            if execution.get('status') != 'completed': return False
            if token and (execution.get('executionId') != executions[n] or f'RUN {token}.' not in execution.get('summary','')):
                return False
        if application.provider.failures: raise ValueError(str(application.provider.failures))
        return True
    state = wait_for(application.runtime.state, terminal, 15)
    ui = application.ui.request()
    if ui.get('page')!='overview' or ui.get('selectedThread') is not None:
        raise ValueError('final public page is not the existing-card Overview')
    return {'status': 'passed', 'threads': [{'id':t['id'],'title':t.get('title'),'observation':t['observation']}
            for t in state['threads'] if t['id'] in application.threads.values()], 'ui': ui,
            'observedNS': time.monotonic_ns(), 'controlCancellations':list(application.provider.cancellations)}


def startup(application, tools, directory, count, mode, seconds):
    from adapter import Runtime, UI, wait_for
    from types import SimpleNamespace
    helper = tools/'collector'
    fixture=existing_fixture(application,directory)
    cleanup = application.stop(); save(directory/'prelaunch-cleanup.json', cleanup)
    if cleanup['errors']: raise RuntimeError('prelaunch owned shutdown failed')
    application.owned.clear()
    application.socket=application.root/('ui-'+uuid.uuid4().hex[:8]+'.sock')
    source = {**native(helper, 'process', os.getpid()), 'role':'source'}
    plan = {'version':1,'kind':'plan','clock':CLOCK,'scenario':'first-render','count':count,'mode':mode,'targetKind':'application','fixture':fixture,
        'warmupSeconds':1.0,'formalSeconds':float(seconds),'tailSeconds':2.0,'sampleHz':10.0,'captureHz':5.0,
        'maximumNoProgressSeconds':.65,'maximumCaptureGapSeconds':.65,'motionTolerancePixels':14.0,
        'anchors':[f'BENCH CARD {n:02d}' for n in range(1,count+1)], 'processRoots':[source],
        'runtimeConnection':str(application.profile/'runtime/connection.json'),
        'runtimePath':str(application.bundle/'Contents/MacOS/mokusei-runtime')}
    relative = trajectory({'x':70,'y':110,'width':0,'height':0}, seconds-2)
    plan['events'] = [{**event,'atSeconds':event['atSeconds']+2} for event in relative]
    config = {'plan':plan, 'launch': {'app':str(application.bundle), 'arguments':['--data-dir',str(application.profile),
              '--automation-socket',str(application.socket),'--benchmark-scenario','overview'], 'environment':application.env}}
    before = clock_bracket(helper)
    try:
        with (directory/'collector.log').open('w') as log:
            process = subprocess.run([str(helper),'startup','-',str(directory)],input=json.dumps(config),text=True,
                stdout=log,stderr=subprocess.STDOUT,timeout=seconds+30)
        save(directory/'collector-exit.json',{'exitStatus':process.returncode})
    finally:
        if (directory/'launch.json').exists():
            launched = json.loads((directory/'launch.json').read_text())
            application.app = SimpleNamespace(pid=launched['process']['pid'])
            application.owned[application.app.pid] = launched['process']
            application.runtime = Runtime(application.profile)
            application.ui = UI(application.socket,application.app.pid)
        save(directory/'tail-outcome.json',boundary_outcome(application))
        save(directory/'clock.json',{'observations':[before,clock_bracket(helper)]})
    validate_plan(json.loads((directory/'plan.json').read_text()))
    connection = json.loads((application.profile/'runtime/connection.json').read_text())
    runtime = native(helper,'process',connection['pid']); application.owned[connection['pid']] = runtime
    save(directory/'identity.json',{'owner':launched['process'],'collectorSHA256':sha256(helper),'frameworkFiles':FRAMEWORK_FILES,
         'toolBuild':json.loads((tools/'build.json').read_text()),'host':before['helper']})
    save(directory/'hitch-error.json',{'error':'XCTest attachment after launch cannot cover the pre-attachment startup interval.'})
    if (directory/'observation.json').exists() and mode=='observed':recognize_frames(helper,directory)


def run_suite(tools, bundle, directory, counts, scenarios, mode, seconds, capability_dir=None,
              pacing='sustained', chunk_bytes=64, message_bytes=512):
    from lifecycle import Application
    from adapter import wait_for
    from workload import schedule
    directory.mkdir(parents=True,mode=0o700,exist_ok=False)
    capability = None
    if capability_dir:
        capability = json.loads((capability_dir/'capabilities.json').read_text())
        if capability['collectorSHA256'] != sha256(tools/'collector'):
            raise ValueError('calibration belongs to a different collector build')
        # Preserve all raw control evidence and hashes beside the production runs.
        shutil.copytree(capability_dir, directory/'calibration')
    summaries=[]
    for count in counts:
        group = directory/f'n-{count}'; group.mkdir()
        application = Application(bundle,group/'fixture',count,tools/'collector')
        trials=[]
        try:
            print(f'Preparing {count} tasks through public Moku commands',flush=True)
            application.start()
            for index,scenario in enumerate(scenarios):
                case=group/f'{index:02d}-{scenario}'; case.mkdir();trials.append(case)
                print(f'Measuring {scenario}, N={count}, {mode}',flush=True)
                try:
                    for filename in ('artifact.json','native-cli.json','selection.json'):
                        shutil.copy2(application.root/filename,case/filename)
                    if 'zoom' in scenario:
                        save(case/'report.json',{'version':1,'scenario':scenario,'count':count,'mode':mode,
                            'measurement':'unsupported','product':'unknown','comparison':'not-comparable','metrics':{},
                            'reasons':['No validated public system magnification injector; command-wheel is not a pinch.']})
                        continue
                    if scenario=='first-render':
                        startup(application,tools,case,count,mode,seconds)
                        save(case/'outcome.json',outcome(application))
                        continue
                    owner=native(tools/'collector','prepare',application.app.pid)
                    if scenario=='return':
                        application.ui.request({'name':'thread.open','threadId':application.threads[1],'typeId':'agent'})
                        wait_for(application.ui.request,lambda s:s.get('page')=='thread' and not s.get('transitioning'),15)
                        owner=native(tools/'collector','inspect',application.app.pid)
                    else:
                        state=application.ui.request()
                        if state.get('page')!='overview':
                            application.ui.request({'name':'overview.show'})
                        wait_for(application.ui.request,lambda s:s.get('page')=='overview' and not s.get('transitioning'),15)
                    tree=application.discover_owned()
                    roots=[]
                    for row in tree:
                        if row['pid']==application.app.pid:role='application'
                        elif Path(row['path']).name=='mokusei-runtime':role='runtime'
                        else:role='helper'
                        roots.append({**row,'role':role})
                        application.owned[row['pid']]=row
                    roots.append({**native(tools/'collector','process',os.getpid()),'role':'source'})
                    plan=make_plan(owner,roots,scenario,count,mode,seconds)
                    plan['fixture']=existing_fixture(application,case)
                    if scenario=='return':
                        key={'keyCode':40,'x':owner['bounds']['x']+50,'y':owner['bounds']['y']+50}
                        plan['events']=[{'kind':'keyDown','atSeconds':.1,**key},{'kind':'keyUp','atSeconds':.15,**key}]
                        plan['events'] += [{**e,'atSeconds':e['atSeconds']+2} for e in trajectory(owner['bounds'],seconds-2)]
                    elif scenario in ('idle.completed','idle.active','body'):
                        # A tail interaction probe leaves the formal idle/source interval uncontaminated.
                        plan['events']=[{**e,'atSeconds':e['atSeconds']+seconds-.15} for e in trajectory(owner['bounds'],2)]
                    token=None;executions={}
                    if scenario.startswith('body') or scenario=='idle.active':
                        workload=schedule(count,seconds,pacing,chunk_bytes,message_bytes)
                        plan['workload']=workload
                        token=application.provider.prepare_stream(workload,waiting=scenario=='idle.active')
                        for n,tid in application.threads.items():
                            result=application.runtime.invoke('thread:follow-up',[{'threadId':tid,'input':{'parts':[{
                                'kind':'text','text':f'BENCH ITEM {n:02d}: BENCH STREAM {n:02d} {token}. Review launch settings and report progress.'}]}}])
                            executions[n]=result['executionId']
                        wait_for(lambda:application.provider.streams[token]['ready'],lambda v:len(v)==count,60)
                        state=application.runtime.state()
                        save(case/'active-preparation.json',{'executions':executions,'threads':[
                            {'id':t['id'],'title':t.get('title'),'observation':t['observation']}
                            for t in state['threads'] if t['id'] in application.threads.values()]})
                    collect(tools,case,plan,bundle,capability,
                            arm=(lambda start:application.provider.arm(token,start)) if token else None,
                            checkpoint=lambda:boundary_outcome(application))
                    if token:save(case/'source.json',application.provider.source_evidence(token))
                    save(case/'outcome.json',outcome(application,token,executions))
                except Exception as error:
                    save(case/'failure.json',{'error':str(error),'atNS':time.monotonic_ns()})
                    save(case/'outcome.json',{'status':'timeout' if isinstance(error,TimeoutError) else 'unknown','error':str(error)})
                    # A failed source/ownership setup cannot seed later comparable cases.
                    break
        finally:
            cleanup=application.close()
            for case in trials:
                save(case/'cleanup.json',cleanup)
                seal(case)
                if (case/'plan.json').exists():report=write_report(case)
                elif (case/'report.json').exists():report=json.loads((case/'report.json').read_text())
                else:
                    report={'measurement':'incomplete','product':'unknown','comparison':'not-comparable','metrics':{},
                            'reasons':['scenario preparation failed; see failure.json']}
                    save(case/'report.json',report)
                summaries.append({'path':str(case.relative_to(directory)),**report})
    save(directory/'summary.json',{'version':1,'results':summaries,'statisticalRegressionGate':False})
    lines=['# Observed Overview measurements','',
           'All cards existed before each timed scenario. No layout score or statistical regression gate.',
           'CPU and footprint below describe sampled, identified App processes. They are not complete process-tree costs.',
           'Incomplete/unsupported rows cannot certify a passing performance comparison.','',
           '| Scenario | N | Measurement | Product | App CPU (s) | App sampled peak (MiB) | Body checkpoints |',
           '| --- | ---: | --- | --- | ---: | ---: | ---: |']
    for row in sorted(summaries,key=lambda r:(r.get('scenario',''),r.get('count',0))):
        metrics=row.get('metrics',{});app=metrics.get('formal',{}).get('roles',{}).get('application',{})
        cpu=f"{app['observedCPUSeconds']:.4f}" if 'observedCPUSeconds' in app else 'unavailable'
        memory=f"{app['sampledPeakFootprintBytes']/2**20:.1f}" if 'sampledPeakFootprintBytes' in app else 'unavailable'
        updates=metrics.get('body',{}).get('observedCheckpointLatenciesSeconds')
        lines.append(f"| {row.get('scenario',row['path'])} | {row.get('count','?')} | {row['measurement']} | {row['product']} | {cpu} | {memory} | {len(updates) if updates is not None else '—'} |")
    lines+=['','See each trial’s report and raw evidence for capture/input/source uncertainty, gaps and failures.','']
    (directory/'summary.md').write_text('\n'.join(lines))
    return summaries
