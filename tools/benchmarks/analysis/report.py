"""Offline external-evidence analysis. No layout or implementation assertions."""
import hashlib
import json
import math
from pathlib import Path
import re
import struct

from contracts.model import CLOCK, ROLES, envelope, integer, load, loads, number, plan as validate_plan, text
from input_region import validate_preparation


def hash_file(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def seal(directory):
    root = Path(directory)
    files = {str(p.relative_to(root)): hash_file(p) for p in sorted(root.rglob('*'))
             if p.is_file() and p != root/'manifest.json' and p.name not in ('report.json', 'report.md')}
    (root/'manifest.json').write_text(json.dumps({'version': 1, 'files': files}, indent=2) + '\n')


def analyze(directory):
    root = Path(directory)
    plan = validate_plan(load(root/'plan.json'))
    result = {'version': 1, 'scenario': plan['scenario'], 'count': plan['count'], 'mode': plan['mode'],
              'measurement': 'valid', 'product': 'unknown', 'comparison': 'inconclusive',
              'reasons': [], 'metrics': {}, 'scope': 'complete application scenario, not rendering-module attribution'}
    priorities = {'valid': 0, 'unsupported': 1, 'incomplete': 2, 'invalid': 3}
    def mark(reason, measurement=None, product=None):
        if measurement and priorities[measurement] > priorities[result['measurement']]:
            result['measurement'] = measurement
        if product and (result['product'] in ('unknown', 'passed') or product == 'crash'):
            result['product'] = product
        if reason not in result['reasons']:
            result['reasons'].append(reason)
    sealed=set()
    if not (root/'manifest.json').exists():
        mark('evidence manifest absent', 'incomplete')
    else:
        manifest = load(root/'manifest.json')
        if manifest.get('version') != 1 or not isinstance(manifest.get('files'), dict):
            raise ValueError('invalid evidence manifest')
        sealed=set(manifest['files'])
        for name, digest in manifest['files'].items():
            path = root/name
            if Path(name).is_absolute() or '..' in Path(name).parts or not path.resolve().is_relative_to(root.resolve()):
                raise ValueError('manifest path escapes experiment')
            if not path.is_file() or hash_file(path) != digest:
                mark('evidence absent or modified: '+name, 'invalid')
        if plan['targetKind']=='application':
            for name in ('artifact.json','native-cli.json','existing-fixture.json'):
                if name not in sealed:mark('unsealed application evidence: '+name,'incomplete')
            if (root/'existing-fixture.json').exists() and load(root/'existing-fixture.json')!=plan['fixture']:
                mark('fixture preparation differs from planned existing card set','invalid')
            if plan['scenario'].startswith('reading.'):
                for name in ('reading-fixture.json', 'body-corpus.json', 'public-content.json'):
                    if name not in sealed: mark('unsealed reader evidence: '+name, 'incomplete')
                if (root/'body-corpus.json').exists() and load(root/'body-corpus.json') != plan['reading']['corpus']:
                    mark('reader corpus differs from the declared workload', 'invalid')
        for name in ('plan.json', 'observation.json', 'outcome.json', 'identity.json', 'clock.json', 'cleanup.json', 'collector-exit.json'):
            if name not in manifest['files']:
                mark('unsealed required evidence: '+name, 'incomplete')
    if not (root/'observation.json').exists():
        mark('collector terminal observation absent', 'incomplete')
        result['comparison'] = 'not-comparable'
        return result
    observation = envelope(load(root/'observation.json'), 'observation')
    if (root/'collector-exit.json').exists() and load(root/'collector-exit.json').get('exitStatus') != 0:
        mark('collector process did not exit successfully', 'incomplete')
    if observation.get('windowBounds') != plan.get('windowBounds'):
        mark('window changed after external input preparation', 'invalid')
    if observation.get('unsupported'):
        mark(text(observation['unsupported'], 'unsupported capability'), 'unsupported')
        result['comparison'] = 'not-comparable'
        return result
    if (root/'identity.json').exists() and load(root/'identity.json').get('owner',{}).get('identity') != plan['processIdentity']:
        mark('artifact owner evidence does not match the plan','invalid')
    if observation['owner']['identity'] != plan['processIdentity'] or observation['owner']['pid'] != plan['pid']:
        mark('collector attached to the wrong process identity', 'invalid')
    if (root/'clock.json').exists():
        clock = load(root/'clock.json')
        for bracket in clock['observations']:
            before = integer(bracket['beforeNS'], 'clock before', 1)
            after = integer(bracket['afterNS'], 'clock after', before)
            observed = integer(bracket['helper']['nowNS'], 'helper clock', 1)
            mach = integer(bracket['helper']['machNS'], 'mach conversion', 1)
            if bracket['helper']['clock'] != CLOCK or not before <= observed <= after or abs(mach-observed) > 5_000_000:
                mark('cross-process clock mapping failed', 'invalid')
        if len(clock['observations']) < 2:
            mark('clock calibration requires before/after observations', 'incomplete')
    else:
        mark('clock calibration absent', 'incomplete')
    bounds = observation['boundaries']
    times = [integer(bounds[key], key, 1) for key in ('warmupStart', 'formalStart', 'formalEnd', 'tailEnd')]
    if times != sorted(set(times)) or times[0] != plan['startNS']:
        raise ValueError('invalid observation boundaries')
    for a,b,key in zip(times,times[1:],('warmupSeconds','formalSeconds','tailSeconds')):
        if abs((b-a)/1e9-plan[key]) > 1e-6:
            mark('phase clock differs from planned schedule','invalid')
    inputs = observation['inputs']
    if len(inputs) != len(plan['events']):
        mark('input ledger incomplete or contains extra events','incomplete')
    for event, expected in zip(inputs,plan['events']):
        if any(event.get(k) != v for k,v in expected.items()):
            mark('dispatched input differs from planned trajectory','invalid')
        planned = integer(event['plannedNS'],'planned input',1)
        posted = integer(event['postedNS'],'posted input',1)
        if abs(planned - (times[1]+round(expected['atSeconds']*1e9))) > 10_000:
            mark('input deadline mapping mismatch','invalid')
        if posted < planned or posted-planned > 50_000_000 or event.get('error'):
            mark('input dispatch missed deadline or failed','invalid')
    if plan['targetKind']=='application' and any(e['kind']=='drag' for e in plan['events']):
        if 'input-preparation.json' not in sealed:
            mark('mouse-down background target was not externally prepared','incomplete')
        else:
            context=validate_preparation(load(root/'input-preparation.json'),plan)
            result['inputPreparation']={'context':context,'publicAccessibilityGeometry':True}
    if plan['targetKind']=='application':
        if 'tail-outcome.json' not in sealed:
            mark('immediate post-window business observation absent','incomplete')
        else:
            tail=load(root/'tail-outcome.json')
            before=integer(tail['beforeNS'],'tail outcome request',times[3])
            after=integer(tail['afterNS'],'tail outcome response',before)
            if after-times[3]>1_000_000_000:mark('post-window business observation was delayed','incomplete')
            if tail.get('status')=='pending':
                mark('business work still pending beyond the declared catch-up tail','incomplete',product='overloaded')
            elif tail.get('status')!='completed':mark('post-window business observation unavailable','incomplete')
            elif 'workload' in plan:
                if 'active-preparation.json' not in sealed:
                    mark('requested active execution identities absent','incomplete')
                elif not completed_executions(plan,load(root/'active-preparation.json'),tail['threads']):
                    mark('requested execution results incomplete at the catch-up boundary','incomplete',product='overloaded')
    resources(plan, observation, times, result, mark)
    if observation.get('productExited') is True:
        mark('application exited during observation',product='crash')
    if observation.get('captureErrors'):
        mark('capture errors retained in observation','incomplete')
    if plan['mode'] == 'observed':
        for name in ['frames.jsonl','hitch.json']+[f['image'] for f in observation['frames']]:
            if name not in sealed:mark('unsealed observed evidence: '+name,'incomplete')
        if (plan['scenario'].startswith('body') or plan['scenario']=='reading.output-scroll') and 'source.json' not in sealed:
            mark('unsealed body source evidence','incomplete')
        frames = []
        if (root/'frames.jsonl').exists():
            if (root/'frames.jsonl').stat().st_size>128*1024*1024:raise ValueError('frame ledger too large')
            frames = [loads(line) for line in (root/'frames.jsonl').read_text().splitlines() if line]
            pixels(root, plan, observation, frames, times, result, mark)
        else:
            mark('continuous pixel observations absent','incomplete')
        hitch(root, plan, times, result, mark)
    else:
        result['continuousQuality'] = 'unobserved'
    if (root/'outcome.json').exists():
        outcome = load(root/'outcome.json')
        if outcome.get('status') in ('timeout','crash','wrong-result'):
            mark('public business outcome: '+outcome['status'],product=outcome['status'])
        elif outcome.get('status') != 'passed':
            mark('business outcome has no terminal status','incomplete')
        elif result['product'] == 'unknown' and result.get('scenarioEvidence') is True:
            result['product'] = 'passed'
        if plan['targetKind']=='application' and outcome.get('status')=='passed':
            actual={t['id']:t['title'] for t in outcome['threads']}
            expected={t['id']:t['title'] for t in plan['fixture']['threads']}
            if actual!=expected or len(outcome['threads'])!=plan['count']:
                mark('pre-existing card count/identity/title changed',product='wrong-result')
            if 'workload' in plan and not completed_executions(plan,load(root/'active-preparation.json'),outcome['threads']):
                mark('terminal business content does not match the requested executions',product='wrong-result')
            if plan['scenario'].startswith('reading.'):
                from reading.analysis import outcome as reading_outcome
                reading_outcome(root, plan, outcome, mark)
        result['businessOutcome'] = outcome.get('status','unknown')
    else:
        mark('final public business outcome absent','incomplete')
    if (root/'cleanup.json').exists() and load(root/'cleanup.json').get('errors'):
        mark('owned process cleanup incomplete','incomplete')
    if plan['scenario']=='first-render' and (root/'launch.json').exists():
        launched=load(root/'launch.json')
        if launched.get('process',{}).get('identity')!=plan['processIdentity']:
            mark('launch receipt belongs to another process','invalid')
        result['metrics']['startupCoverage']={
            'resourceObservationStartsAfterLaunch':True,'preAttachmentHitches':'unavailable',
            'wholeLaunchCostCertified':False}
    if result['measurement'] != 'valid' or result['product'] not in ('passed',):
        result['comparison'] = 'not-comparable'
    if result['measurement']=='invalid' and result['product'] not in ('crash','timeout'):result['product']='unknown'
    if plan['targetKind']=='application' and plan['mode']=='observed':
        if plan['scenario'].startswith('reading.'):
            from reading.analysis import calibration as reading_calibration
            calibrated=reading_calibration(root, mark)
        else:
            calibrated=calibration(root, mark)
        result['collectorCalibration']=calibrated
        if 'hitches' in result['metrics']:
            result['metrics']['hitches']['capabilityValidated']=calibrated['hitchesPassed']
        if not calibrated['pixelsPassed'] and result['product'] not in ('crash','timeout'):
            result['product']='unknown'
        if result['measurement']!='valid':result['comparison']='not-comparable'
    result['allRequiredCapabilitiesAvailable'] = result['measurement']=='valid'
    return result


def completed_executions(plan, preparation, threads):
    """Correlate the captured public result with each admitted execution/body."""
    executions=preparation['executions']
    if set(executions)!=set(map(str,range(1,plan['count']+1))) or len(set(executions.values()))!=plan['count']:
        raise ValueError('active execution admission identities incomplete')
    if len(preparation['threads'])!=plan['count'] or {t['id'] for t in preparation['threads']}!={t['id'] for t in plan['fixture']['threads']}:
        raise ValueError('active preparation does not cover the existing card set')
    if any((t['observation'].get('latestExecution') or {}).get('status')!='running' for t in preparation['threads']):
        raise ValueError('all requested card executions must be running before timing')
    prepared={(t['observation'].get('latestExecution') or {}).get('executionId'):t['id'] for t in preparation['threads']}
    if set(executions.values())!=prepared.keys():raise ValueError('admitted executions did not reach the public preparation state')
    terminal={e['card']:e['text'] for e in plan['workload']['terminal']}
    if set(terminal)!=set(range(1,plan['count']+1)):raise ValueError('terminal payload identities incomplete')
    actual={t['id']:t['observation'].get('latestExecution') or {} for t in threads}
    if len(threads)!=plan['count'] or set(actual)!={t['id'] for t in plan['fixture']['threads']}:return False
    return all((row:=actual.get(prepared[execution],{})).get('executionId')==execution and
        row.get('status')=='completed' and row.get('summary')==terminal[int(card)] for card,execution in executions.items())


def calibration(root, mark):
    """Re-evaluate retained control evidence, not an asserted capability boolean."""
    directory=root.parent.parent/'calibration'
    unavailable={'pixelsPassed':False,'hitchesPassed':False}
    if not (directory/'manifest.json').is_file():
        mark('retained collector calibration absent','unsupported');return unavailable
    manifest=load(directory/'manifest.json')
    required={'capabilities.json','wrong-owner/launch.json','wrong-owner/hitch.json','wrong-owner/hitch-config.json',
              'wrong-owner/hitch-xcodebuild.log','stall/stall-events.jsonl'}
    required.update(name+'/manifest.json' for name in ('normal','frozen','wrong','delay','stall'))
    if manifest.get('version')!=1 or not required<=manifest['files'].keys():
        mark('calibration manifest lacks required control evidence','incomplete');return unavailable
    for name,digest in manifest['files'].items():
        path=directory/name
        if Path(name).is_absolute() or '..' in Path(name).parts or not path.resolve().is_relative_to(directory.resolve()):
            raise ValueError('calibration evidence path escapes control directory')
        if not path.is_file() or hash_file(path)!=digest:
            mark('calibration evidence absent or modified: '+name,'invalid');return unavailable
    capabilities=load(directory/'capabilities.json');identity=load(root/'identity.json')
    if any(capabilities.get(k)!=identity.get(k) for k in ('collectorSHA256','toolBuild')) or capabilities['host']['os']!=identity['host']['os']:
        mark('calibration belongs to another collector/toolchain/OS','unsupported');return unavailable
    reports={}
    for name in ('normal','frozen','wrong','delay','stall'):
        if load(directory/name/'plan.json').get('targetKind')!='control':raise ValueError('calibration target is not a control')
        reports[name]=analyze(directory/name)
    pixels=reports['normal']['product']=='passed' and all(
        reports[name]['product']==('wrong-result' if name=='wrong' else 'overloaded') for name in ('frozen','wrong','delay','stall'))
    normal=reports['normal'].get('metrics',{}).get('hitches',{}).get('measurements',[])
    stalled=reports['stall'].get('metrics',{}).get('hitches',{}).get('measurements',[])
    baseline={(v['identifier'],v['unit']):v['value'] for v in normal}
    increases=any(v['value']>baseline.get((v['identifier'],v['unit']),math.inf) for v in stalled)
    wrong=load(directory/'wrong-owner/hitch.json')
    expected=load(directory/'wrong-owner/hitch-config.json')
    actual=load(directory/'wrong-owner/launch.json')
    rejected=wrong['exitStatus']!=0 and not wrong['batches'] and not (directory/'wrong-owner/hitch-ready.json').exists() and (
        expected['pid']==actual['process']['pid'] and abs(expected['launchDate']-actual['launchDate'])>=1 and
        'Error Domain=benchmark-owner Code=1' in (directory/'wrong-owner/hitch-xcodebuild.log').read_text())
    faults=[loads(line) for line in (directory/'stall/stall-events.jsonl').read_text().splitlines()]
    boundaries=load(directory/'stall/observation.json')['boundaries']
    real_stall=len(faults)==2 and faults[1]['atNS']-faults[0]['atNS']>=1_000_000_000 and (
        boundaries['formalStart']<=faults[0]['atNS']<faults[1]['atNS']<=boundaries['formalEnd'])
    hitches=pixels and increases and rejected and real_stall
    if not pixels:mark('pixel normal/frozen/wrong/delayed/stall controls did not establish capability','unsupported')
    if not hitches:mark('native hitch sensitivity/ownership controls did not establish capability','unsupported')
    return {'pixelsPassed':pixels,'hitchesPassed':hitches,'wrongOwnerRejected':rejected}


def resources(plan, observation, times, result, mark):
    cpu_unit_known = observation.get('cpuTimeUnit') == 'nanoseconds'
    if not cpu_unit_known:
        mark('resource CPU units absent or unsupported; CPU metrics withheld','incomplete')
    coverage=observation['processCoverage']
    # Current external proc sampler cannot establish a complete lifecycle ledger.
    # A bare 'complete: true' from an edited/mismatched collector is not evidence.
    complete=False
    if coverage.get('complete') is True:
        mark('unsupported claim of complete process accounting','invalid')
    if not complete:
        mark('process lifecycle/exit CPU coverage incomplete','incomplete')
    samples=observation['resources']
    if not isinstance(samples,list) or len(samples)>25_000:raise ValueError('invalid resource stream size')
    previous=0; identities={}; roots={r['identity']:r['role'] for r in plan['processRoots']}
    if not samples:mark('resource sample stream empty','incomplete')
    for sample in samples:
        at=integer(sample['atNS'],'resource timestamp',previous+1);previous=at
        end=integer(sample['endNS'],'resource read end',at)
        if end-at>100_000_000: mark('resource sample uncertainty exceeds 100 ms','incomplete')
        seen=set()
        for p in sample['processes']:
            identity=text(p['identity'],'resource identity');integer(p['pid'],'resource pid',1)
            integer(p['cpuNS'],'cumulative CPU');integer(p['footprintBytes'],'physical footprint')
            if p['role'] not in ROLES or identity in seen: raise ValueError('duplicate/invalid process resource row')
            seen.add(identity)
            if identity in roots and roots[identity] != p['role']:
                mark('declared process root changed accounting role','invalid')
            if identity in identities:
                old=identities[identity]
                if p['cpuNS']<old['cpuNS'] or p['role'] != old['role'] or p['pid'] != old['pid']:
                    mark('process cumulative counter or identity changed','invalid')
            identities[identity]=p
        if not roots.keys() <= seen: mark('declared process root missing from sample','incomplete')
        if sample.get('ownerAlive') is False: mark('application owner disappeared',product='crash')
        if sample.get('frontmostPID') != plan['pid']: mark('application lost foreground during measurement','invalid')
    intervals=[('warmup',times[0],times[1]),('formal',times[1],times[2]),('tail',times[2],times[3]),('wholeObservation',times[0],times[3])]
    for name,start,end in intervals:
        rows=[s for s in samples if start<=s['atNS']<=end+100_000_000]
        if len(rows)<2 or rows[0]['atNS']-start>1.5e9/plan['sampleHz'] or end-rows[-1]['atNS']>1.5e9/plan['sampleHz']:
            mark(name+' resource boundary coverage absent','incomplete');continue
        if any(b['atNS']-a['atNS']>2.5e9/plan['sampleHz'] for a,b in zip(rows,rows[1:])):
            mark(name+' resource sampling gap','incomplete')
        first={p['identity']:p for p in rows[0]['processes']};last={p['identity']:p for p in rows[-1]['processes']}
        roles={};wall=(rows[-1]['atNS']-rows[0]['atNS'])/1e9
        for identity in first.keys()&last.keys():
            a,b=first[identity],last[identity]
            role=roles.setdefault(b['role'],{'sampledPeakFootprintBytes':0})
            if cpu_unit_known:
                delta=(b['cpuNS']-a['cpuNS'])/1e9
                role['observedCPUSeconds']=role.get('observedCPUSeconds',0)+delta
                role['singleCoreCPUPercent']=role.get('singleCoreCPUPercent',0)+100*delta/wall
        for key,role in roles.items():
            role['sampledPeakFootprintBytes']=max(sum(p['footprintBytes'] for p in s['processes'] if p['role']==key) for s in rows)
            role['finalSampledFootprintBytes']=sum(p['footprintBytes'] for p in rows[-1]['processes'] if p['role']==key)
        result['metrics'][name]={'sampledSeconds':wall,'roles':roles,'completeTaskCost':complete}


def pixels(root, plan, observation, frames, times, result, mark):
    raw=observation['frames']
    if not isinstance(raw,list) or len(raw)>25_000:raise ValueError('invalid capture stream size')
    if len(frames)!=len(raw): mark('OCR/capture ledger mismatch','incomplete')
    previous=0; rows=[]
    requests={}
    for frame, capture in zip(frames,raw):
        at=integer(frame['atNS'],'capture timestamp',previous+1);previous=at
        if any(frame.get(key)!=capture.get(key) for key in ('atNS','requestNS','image','width','height','pointsWidth','pointsHeight','windowBounds')):
            mark('OCR detached from capture record','invalid')
        if capture.get('windowBounds')!=plan.get('windowBounds'):
            mark('WindowServer bounds changed during collection','invalid')
        request=integer(frame['requestNS'],'capture request',1,at)
        requests[at]=request
        image=text(frame['image'],'image path')
        if Path(image).name!=image or not (root/image).is_file(): mark('raw frame absent','incomplete')
        if at-request>plan['maximumCaptureGapSeconds']*1e9: mark('capture request uncertainty exceeds declared budget','incomplete')
        width=integer(frame['width'],'frame width',1,16384);height=integer(frame['height'],'frame height',1,16384)
        if (root/image).is_file():
            with (root/image).open('rb') as stream:header=stream.read(24)
            if len(header)!=24 or header[:8]!=b'\x89PNG\r\n\x1a\n' or header[12:16]!=b'IHDR' or struct.unpack('!II',header[16:24])!=(width,height):
                mark('raw PNG dimensions/format disagree with capture','invalid')
        points=number(frame['pointsWidth'],'capture points width',1,16384)
        points_height=number(frame['pointsHeight'],'capture points height',1,16384)
        if points!=plan['windowBounds']['width'] or points_height!=plan['windowBounds']['height']:
            mark('capture point scale disagrees with the OS window','invalid')
        if abs(width/points-height/points_height)>max(1/points,1/points_height):
            mark('capture pixel scaling differs between axes','invalid')
        anchors={}
        for item in frame['texts']:
            text(item['text'],'recognized text',20_000)
            for key in ('x','y','width','height'): number(item[key],'OCR '+key,0,32768)
            number(item['confidence'],'OCR confidence',0,1)
            if item['x']+item['width']>width+1 or item['y']+item['height']>height+1: raise ValueError('OCR box outside pixel frame')
            if item['text'] in plan['anchors'] and item['confidence']>=.5 and not item.get('edgeClipped',False):
                if item['text'] in anchors: mark('ambiguous duplicated business anchor','incomplete')
                anchors[item['text']]=item
        rows.append((at,anchors,width/points,frame['texts']))
    relevant=[r for r in rows if times[1]<=r[0]<=times[3]+100_000_000]
    if not relevant or not any(r[1] for r in relevant):
        mark('no observable business-content anchor; no layout failure inferred','incomplete');return
    stamps=[times[1]]+[r[0] for r in relevant]+[max(times[3],relevant[-1][0])]
    if any(b-a>plan['maximumCaptureGapSeconds']*1e9 for a,b in zip(stamps,stamps[1:])):
        mark('continuous capture coverage gap','incomplete')
    result['continuousQuality']='observed'
    result['metrics']['pixels']={'capturedFrames':len(rows),'captureCadenceIsDisplayFPS':False}
    if plan['scenario'].startswith('reading.'):
        from reading.analysis import pixels as reading_pixels
        reading_pixels(root, plan, observation, frames, times, result, mark)
        return
    if any(e['kind'] == 'drag' for e in plan['events']):
        result['motionEvidence']=False
        drag=[i for i in observation['inputs'] if i['kind'] in ('down','drag','up')]
        if drag:
            start=drag[0];baseline=next((r for r in reversed(rows) if r[0]<start['postedNS'] and r[1]),None)
            if baseline is None: mark('pre-input business anchor absent','incomplete');return
            last_progress=start['postedNS'];maximum_stall=0;last_positions={k:(0,0) for k in baseline[1]};errors=[];first_response=None
            earliest_progress=latest_progress=start['postedNS']
            previous_request=requests[baseline[0]]
            stall_lower=stall_upper=0
            response_bounds=None
            correspondence=[start['postedNS']];last_anchor=baseline[0]
            for at,anchors,scale,_ in relevant:
                if at<start['postedNS']:continue
                occurred=[e for e in drag if e['postedNS']<=at]
                if not occurred:continue
                expected=occurred[-1]
                dx=(expected['x']-start['x'])*scale;dy=(expected['y']-start['y'])*scale
                common=anchors.keys()&baseline[1].keys()
                if not common: continue
                correspondence.append(at);last_anchor=at
                positions={k:(anchors[k]['x']-baseline[1][k]['x'],anchors[k]['y']-baseline[1][k]['y']) for k in common}
                moving=any(k not in last_positions or math.dist(p,last_positions[k])>1 for k,p in positions.items())
                # A changed frame brackets when progress resumed; its previous
                # frame only bounds the end of a stall. Keep both ends instead
                # of treating the next sample's arrival as a proven freeze.
                if latest_progress<drag[-1]['postedNS']:
                    same_until=previous_request if moving else requests[at]
                    stall_lower=max(stall_lower,max(0,min(same_until,drag[-1]['postedNS'])-latest_progress)/1e9)
                    stall_upper=max(stall_upper,max(0,min(at,drag[-1]['postedNS'])-earliest_progress)/1e9)
                if last_progress<drag[-1]['postedNS']:
                    maximum_stall=max(maximum_stall,max(0,min(at,drag[-1]['postedNS'])-last_progress)/1e9)
                if moving:
                    last_progress=at
                    # A mouse-down alone has no declared translation. OCR/body
                    # jitter before the first drag is not an input response.
                    if first_response is None and any(e['kind']=='drag' for e in occurred) and any(math.hypot(*p)>3 for p in positions.values()):
                        first_response=at
                        response_bounds={'lower':max(0,previous_request-start['postedNS'])/1e9,'upper':(at-start['postedNS'])/1e9}
                    earliest_progress=max(start['postedNS'],previous_request);latest_progress=at
                if start['postedNS']<at<drag[-1]['postedNS']:
                    maximum_stall=max(maximum_stall,(at-last_progress)/1e9)
                # The whole trajectory, including direction and return, is checked.
                # Input motion within the declared lag window can explain lagged positions.
                candidates=[e for e in drag if at-plan['maximumNoProgressSeconds']*1e9<=e['postedNS']<=at] or [expected]
                err=min(max(math.hypot(p[0]-(e['x']-start['x'])*scale,p[1]-(e['y']-start['y'])*scale) for p in positions.values()) for e in candidates)
                errors.append(err);last_positions=positions;previous_request=requests[at]
            result['metrics']['pan']={'firstVisibleResponseSeconds':None if first_response is None else (first_response-start['postedNS'])/1e9,
                'firstVisibleResponseSecondsBounds':response_bounds,'responseDisplacementThresholdPixels':3,
                'maximumNoProgressSeconds':maximum_stall,'noProgressSecondsBounds':{'lower':stall_lower,'upper':stall_upper},
                'maximumTrajectoryErrorPixels':max(errors,default=None)}
            coverage_end=min(times[3],drag[-1]['postedNS']+round(plan['maximumNoProgressSeconds']*1e9))
            stamps=[t for t in correspondence if t<=coverage_end]+[coverage_end]
            missing=any(b-a>plan['maximumCaptureGapSeconds']*1e9 for a,b in zip(stamps,stamps[1:]))
            if not errors or missing or last_anchor<drag[-1]['postedNS']:
                mark('motion anchor correspondence unavailable across the full gesture','incomplete')
            elif plan['targetKind']=='application' and 'inputPreparation' not in result:
                mark('unverified mouse-down target cannot establish canvas responsiveness','incomplete')
            elif first_response is None and plan['targetKind']=='application':
                # AX rectangles guide input; they are not a receipt that the
                # product's gesture recognizer accepted mouse-down. A completely
                # inert probe cannot distinguish a blocked target from a freeze.
                mark('no canvas motion established; input acceptance or product responsiveness is unknown','incomplete')
            elif first_response is None or stall_lower>plan['maximumNoProgressSeconds']:
                mark('input did not produce timely business motion',product='overloaded')
            elif max(errors)>plan['motionTolerancePixels']:
                mark('observed business displacement differs from the declared input trajectory',product='wrong-result')
            elif stall_upper>plan['maximumNoProgressSeconds']:
                mark('motion progress sampling uncertainty straddles the declared deadline','incomplete')
            else:
                result['motionEvidence']=True
                result['scenarioEvidence'] = True
            if plan['scenario'] in ('first-render','return'):
                onset = (load(root/'launch.json')['requestedNS'] if plan['scenario'] == 'first-render'
                         else next(e['postedNS'] for e in observation['inputs'] if e['kind']=='keyDown'))
                content = [r[0] for r in rows if r[0]>=onset and r[1]
                           and any('BENCH BODY' in t['text'] for t in r[3])]
                result['metrics']['presentation'] = {
                    'firstRecognizableBusinessContentSeconds': (min(content)-onset)/1e9 if content else None,
                    'firstSuccessfulInteractionProbeSeconds': (first_response-onset)/1e9
                        if first_response and result.get('scenarioEvidence') is True and result['product'] in ('unknown','passed') else None,
                    'usableTimeIsUpperBoundAtScheduledProbe': True,
                    'firstContentObservationIsUpperBound':True,
                    'firstContentLeftCensored':bool(content) and min(content)==next((r[0] for r in rows if r[0]>=onset),None)}
                if not content:
                    result['scenarioEvidence'] = False
                    mark('business title and body were not observed after entry','incomplete')
    if 'zoom' in plan['scenario']:
        mark('no validated system magnification injector','unsupported')
        result['scenarioEvidence'] = False
    if plan['scenario'].startswith('body'):
        body(root,plan,rows,times,requests,result,mark)
    if plan['targetKind']=='application' and any(e['kind']=='down' for e in plan['events']) and 'inputPreparation' not in result:
        result['scenarioEvidence']=False


def body(root,plan,rows,times,requests,result,mark):
    if not (root/'source.json').exists():
        result['scenarioEvidence']=False;mark('body source ledger absent','incomplete');return
    source=load(root/'source.json')
    if source.get('clock')!=CLOCK or source.get('workload')!=plan.get('workload') or source.get('startNS')!=times[1]:
        result['scenarioEvidence']=False;mark('source clock/workload does not match the predeclared plan','invalid');return
    from workload import schedule
    workload=plan['workload']
    canonical=schedule(plan['count'],plan['formalSeconds'],workload['pacing'],workload['chunkBytes'],workload['messageBytes'])
    if any(workload.get(k)!=v for k,v in canonical.items()):
        raise ValueError('body plan does not supply the declared per-card rate/content to the full fixed count')
    terminal=workload['terminal']
    if plan['targetKind']=='application' and (len(terminal)!=plan['count'] or {e['card'] for e in terminal}!=set(range(1,plan['count']+1))):
        raise ValueError('body terminal messages do not cover every existing card')
    events=plan['workload']['events']
    for e in events:
        integer(e['card'],'planned card',1,plan['count']);integer(e['sequence'],'planned sequence',1)
        integer(e['message'],'planned message',1);integer(e['part'],'planned part')
        integer(e['bytes'],'planned bytes',1,4096);number(e['atSeconds'],'planned source time',0,plan['formalSeconds'])
        text(e['text'],'body text',4096);text(e['sha256'],'body digest',64)
    planned={(e['card'],e['sequence']):e for e in events}
    if len(planned)!=len(events):raise ValueError('duplicate planned source work')
    expected=set(range(1,plan['count']+1));sent={};seen=set()
    for event in source['events']:
        card=integer(event['card'],'source card',1,plan['count']);seq=integer(event['sequence'],'source sequence',1)
        at=integer(event['sentNS'],'source sent',1);deadline=integer(event['plannedNS'],'source deadline',1)
        key=(card,seq)
        if key in seen or key not in planned:raise ValueError('duplicate or unplanned source event')
        seen.add(key)
        if any(event.get(k)!=v for k,v in planned[key].items()):raise ValueError('source payload differs from planned work')
        if deadline!=times[1]+round(planned[key]['atSeconds']*1e9):raise ValueError('source deadline differs from plan')
        if len(event['text'].encode())!=event['bytes'] or hashlib.sha256(event['text'].encode()).hexdigest()!=event['sha256']:
            raise ValueError('body bytes/digest mismatch')
        if at<deadline or at-deadline>50_000_000:mark('body source missed dispatch deadline','invalid')
        if event['part']==0:sent[card,event['message']]=at
    if seen!=planned.keys() or source.get('complete') is not True or set(source.get('done',[]))!=expected:
        result['scenarioEvidence']=False;mark('source did not supply all planned work','incomplete');return
    messages=workload['notes']+terminal
    expected_messages={(e['card'],e['kind'],e['message']):e for e in messages}
    if len(expected_messages)!=len(messages):raise ValueError('duplicate planned progress/terminal message')
    for message in messages:
        if len(message['text'].encode())!=message['bytes'] or hashlib.sha256(message['text'].encode()).hexdigest()!=message['sha256']:
            raise ValueError('planned progress/terminal bytes or digest mismatch')
    seen_messages=set()
    for event in source.get('messages',[]):
        key=(event['card'],event['kind'],event['message'])
        if key in seen_messages or key not in expected_messages:raise ValueError('unplanned or repeated progress/terminal message')
        seen_messages.add(key)
        if any(event.get(k)!=v for k,v in expected_messages[key].items()):raise ValueError('progress/terminal payload differs from plan')
        deadline=times[1]+round(event['atSeconds']*1e9)
        sent_at=integer(event['sentNS'],'message sent',deadline)
        if event['plannedNS']!=deadline or sent_at-deadline>50_000_000:mark('progress/terminal message deadline missed','invalid')
    if seen_messages!=expected_messages.keys():
        result['scenarioEvidence']=False;mark('progress/terminal message ledger incomplete','incomplete');return
    observed={};ages=[];last_progress=times[1];stall=0;card_progress={};card_seen={};card_stalls={}
    marker_frames=[];uncertainty=0
    for at,_,_,texts in rows:
        if not times[1]<=at<=times[3]:continue
        advanced=False;recognized=False
        for item in texts:
            if item['confidence']<.5 or item.get('edgeClipped',False):continue
            for match in re.finditer(r'CHECK (\d{2})[. ](\d{4})',item['text']):
                card,seq=map(int,match.groups());key=(card,seq)
                if key not in sent:mark('pixels contain an unplanned business marker',product='wrong-result');continue
                if at<sent[key]:mark('visible marker predates its source','invalid');continue
                recognized=True
                if at-card_seen.get(card,at)>plan['maximumCaptureGapSeconds']*1e9:
                    card_progress[card]=at
                elif card in card_seen:
                    uncertainty=max(uncertainty,(at-requests[card_seen[card]])/1e9)
                card_seen[card]=at
                if seq>observed.get(card,0):
                    observed[card]=seq;advanced=True;ages.append((at-sent[key])/1e9);card_progress[card]=at
                if at<=times[2]:card_stalls[card]=max(card_stalls.get(card,0),(at-card_progress.get(card,at))/1e9)
        if advanced:
            stall=max(stall,(at-last_progress)/1e9);last_progress=at
        if at<=times[2]:stall=max(stall,(at-last_progress)/1e9)
        if recognized and at<=times[2]:marker_frames.append(at)
    # Visible checkpoints mark natural message boundaries. Fragments may be
    # coalesced or clipped by the ordinary excerpt; they are not expected frames.
    budget=plan['workload']['messageIntervalSeconds']+plan['maximumNoProgressSeconds']
    held=max(card_stalls.values(),default=0)
    held_bounds={'lower':max(0,held-uncertainty),'upper':held+uncertainty}
    result['metrics']['body']={'observedCheckpointLatenciesSeconds':ages,'maximumVisibleNoProgressSeconds':stall,
        'checkpointLatenciesAreCaptureUpperBounds':True,'continuousCardStasisSecondsBounds':held_bounds,
        'expectedMessageIntervalSeconds':plan['workload']['messageIntervalSeconds'],
        'reasoningChunkEvents':len(source['events']),'reasoningChunkBytes':sum(e['bytes'] for e in source['events']),
        'progressAndTerminalMessages':len(source['messages']),'progressAndTerminalBytes':sum(e['bytes'] for e in source['messages']),
        'cardsWithPixelEvidence':sorted(observed),'perFragmentFrameRequired':False,
        'continuouslyObservedCardStallsSeconds':card_stalls}
    if not ages or len(ages)<2:
        result['scenarioEvidence']=False;mark('insufficient changing business body checkpoints observed','incomplete')
    elif not marker_frames or marker_frames[0]-times[1]>budget*1e9 or any(b-a>plan['maximumCaptureGapSeconds']*1e9
            for a,b in zip(marker_frames,marker_frames[1:]+[times[2]])):
        result['scenarioEvidence']=False;mark('business body checkpoint visibility has an observation gap','incomplete')
    elif held_bounds['lower']>budget:mark('supplied active body output stopped making visible progress',product='overloaded')
    elif held_bounds['upper']>budget:
        result['scenarioEvidence']=False;mark('body progress sampling uncertainty straddles the declared deadline','incomplete')
    elif 'pan' not in plan['scenario']:result['scenarioEvidence']=result.get('motionEvidence',True)


def hitch(root,plan,times,result,mark):
    if not (root/'hitch.json').exists():mark('application hitch collector unavailable','unsupported');return
    record=load(root/'hitch.json')
    if record['pid']!=plan['pid'] or record['processIdentity']!=plan['processIdentity']:
        mark('hitch collector targets another process','invalid');return
    if record.get('exitStatus')!=0:mark('XCTest hitch collection failed','unsupported');return
    if not (root/'hitch-owner.json').exists() or load(root/'hitch-owner.json').get('invocations')!=2:
        mark('XCTest lifecycle lacks warmup/measurement ownership receipt','incomplete')
    if not (root/record.get('xcresult','hitches.xcresult')).is_dir():
        mark('raw xcresult is absent','incomplete')
    capability=record.get('capability',{})
    if capability.get('passed') is not True or not all(capability.get(k) is True for k in ('normal','stall','wrongOwner')):
        mark('hitch capability lacks successful normal/stall/ownership controls','unsupported')
    batches=[]
    for batch in record['batches']:
        start=integer(batch['startNS'],'hitch start',1);end=integer(batch['endNS'],'hitch end',start+1)
        values=batch['measurements']
        for value in values:
            text(value['identifier'],'hitch identifier');text(value['unit'],'hitch unit',100)
            number(value['value'],'hitch value')
        if start<=times[1] and end>=times[2] and values:batches.append(batch)
    if len(batches)!=1:mark('hitch window absent, ambiguous or does not cover formal load','incomplete')
    else:
        result['metrics']['hitches']={**batches[0], 'capabilityValidated': capability.get('passed') is True}
        if capability.get('collectorSHA256') != load(root/'identity.json').get('collectorSHA256'):
            mark('hitch controls do not match this collector build','unsupported')


def write_report(directory):
    root=Path(directory)
    try:result=analyze(root)
    except (ValueError,KeyError,TypeError,OSError,ZeroDivisionError,OverflowError,AttributeError) as error:
        result={'version':1,'measurement':'invalid','product':'unknown','comparison':'not-comparable','reasons':[str(error)],'metrics':{}}
    result['analysisSHA256']=hash_file(Path(__file__))
    framework=Path(__file__).resolve().parent.parent
    result['analysisFiles']={name:hash_file(framework/name) for name in
        ('analysis/report.py','contracts/model.py','input_region.py','workload.py')}
    if result.get('scenario', '').startswith('reading.'):
        result['analysisFiles'].update({name: hash_file(framework/name) for name in
            ('reading/analysis.py', 'reading/contract.py', 'reading/corpus.py', 'reading/plan.py', 'reading/public.py')})
    (root/'report.json').write_text(json.dumps(result,indent=2)+'\n')
    title = 'Agent Thread reading benchmark' if result.get('scenario','').startswith('reading.') else 'External Overview benchmark'
    lines=['# '+title,'',f"Measurement: **{result['measurement']}** · Product: **{result['product']}** · Comparison: **{result['comparison']}**",'',
           'Measurements and scaling only. No layout score or statistical regression gate.','']
    lines += ['- '+reason for reason in result['reasons']]
    lines += ['','```json',json.dumps(result['metrics'],indent=2),'```','']
    (root/'report.md').write_text('\n'.join(lines))
    return result
