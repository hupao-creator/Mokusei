"""Portable adversarial replays of the actual external contract and scorer."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import struct
import zlib
import http.client
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from provider import Provider

from contracts.model import CLOCK, loads, plan as validate_plan
from analysis.report import seal, write_report, completed_executions
from lifecycle import save
from workload import schedule
from input_region import background_point, validate_preparation


def ownership_replay():
    import lifecycle
    original=lifecycle.native
    root={'pid':101,'ppid':1,'identity':'101:1000'}
    child={'pid':102,'ppid':101,'identity':'102:1001'}
    try:
        for mode in ('stable','reused','exited'):
            calls=0
            def boundary(helper,command,*args):
                nonlocal calls
                if command=='tree':return {'processes':[root,child]}
                calls+=1
                if calls>1 and mode=='exited':raise RuntimeError('process unavailable')
                return {**root,'identity':'101:2000'} if calls>1 and mode=='reused' else root
            lifecycle.native=boundary
            app=lifecycle.Application(Path('/synthetic.app'),Path('/synthetic'),5,Path('/collector'))
            app.owned={101:root}
            if mode=='reused':
                try:app.discover_owned()
                except RuntimeError:pass
                else:raise AssertionError('reused root adopted another process tree')
            else:app.discover_owned()
            assert (102 in app.owned)==(mode=='stable')
            assert app.owned[101]['identity']==root['identity']
    finally:lifecycle.native=original


def fixture(root):
    # Synthetic protocol evidence; this verifies analysis, never host capability.
    pid=101;identity='101:1000';start=10_000_000_000;formal=start+1_000_000_000
    p={'version':1,'kind':'plan','clock':CLOCK,'scenario':'pan','count':5,'mode':'observed','targetKind':'control',
       'pid':pid,'windowID':2,'processIdentity':identity,'startNS':start,
       'windowBounds':{'x':0,'y':0,'width':1000,'height':700},
       'warmupSeconds':1.0,'formalSeconds':4.0,'tailSeconds':1.0,'sampleHz':10.0,'captureHz':10.0,
       'maximumNoProgressSeconds':.5,'maximumCaptureGapSeconds':.3,'motionTolerancePixels':5,
       'anchors':['BENCH CARD 01'], 'processRoots':[{'pid':pid,'identity':identity,'role':'application'}],
       'events':[{'kind':'down','atSeconds':.1,'x':700,'y':500}]+
          [{'kind':'drag','atSeconds':.1+n*.1,'x':700-2*n,'y':500} for n in range(1,36)]+
          [{'kind':'up','atSeconds':3.7,'x':630,'y':500}]}
    inputs=[{**e,'plannedNS':formal+round(e['atSeconds']*1e9),'postedNS':formal+round(e['atSeconds']*1e9)} for e in p['events']]
    resources=[];frames=[]
    for i in range(61):
        at=start+i*100_000_000
        resources.append({'atNS':at,'endNS':at+1_000_000,'ownerAlive':True,'frontmostPID':pid,
             'processes':[{'pid':pid,'identity':identity,'role':'application','cpuNS':i*1_000_000,'footprintBytes':1024}]})
        happened=[e for e in inputs if e['postedNS']<=at]
        x=200+(happened[-1]['x']-700 if happened else 0)
        frames.append({'atNS':at,'requestNS':at-1_000_000,'image':'frame.png','width':1000,'height':700,
            'pointsWidth':1000,'pointsHeight':700,'windowBounds':p['windowBounds'],'texts':[{'text':'BENCH CARD 01','x':x,'y':100,'width':120,'height':20,'confidence':1}]})
    def chunk(kind,data):return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)
    image=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',1000,700,8,0,0,0,0))+chunk(b'IDAT',zlib.compress(b'\x00'*(1001*700)))+chunk(b'IEND',b'')
    (root/'frame.png').write_bytes(image)
    observation={'version':1,'kind':'observation','clock':CLOCK,'owner':{'pid':pid,'identity':identity},
        'windowBounds':p['windowBounds'],'boundaries':{'warmupStart':start,'formalStart':formal,'formalEnd':formal+4_000_000_000,'tailEnd':formal+5_000_000_000},
        'inputs':inputs,'resources':resources,'processCoverage':{'complete':False,'gaps':['polling cannot capture all exits']},
        'frames':[{k:v for k,v in f.items() if k!='texts'} for f in frames],'captureErrors':[],'productExited':False}
    save(root/'plan.json',p);save(root/'observation.json',observation)
    save(root/'outcome.json',{'status':'passed'});save(root/'cleanup.json',{'errors':[]})
    save(root/'collector-exit.json',{'exitStatus':0})
    save(root/'identity.json',{'owner':{'identity':identity},'collectorSHA256':'synthetic'})
    save(root/'clock.json',{'observations':[{'beforeNS':x-1,'afterNS':x+1,'helper':{'nowNS':x,'machNS':x,'clock':CLOCK}} for x in (start-100,formal+6_000_000_000)]})
    save(root/'hitch.json',{'pid':pid,'processIdentity':identity,'exitStatus':0,'batches':[],
                          'capability':{'passed':False,'normal':True,'stall':False,'wrongOwner':True}})
    (root/'frames.jsonl').write_text(''.join(json.dumps(f)+'\n' for f in frames))
    return p,observation,frames


def provider_replay(directory):
    directory.mkdir()
    provider=Provider(directory,5);provider.model='fixture-model';provider.effort='low'
    try:
        workload=schedule(5,2,'sustained')
        token=provider.prepare_stream(workload)
        def receive(card):
            connection=http.client.HTTPConnection('127.0.0.1',provider.server.server_port,timeout=8)
            request={'model':'fixture-model','stream':True,'input':[{'role':'user','content':[
                {'type':'input_text','text':f'BENCH ITEM {card:02d}: BENCH STREAM {card:02d} {token}'}]}]}
            connection.request('POST','/v1/responses',json.dumps(request),{'Authorization':'Bearer fixture-only','Content-Type':'application/json'})
            response=connection.getresponse()
            assert response.status==200
            events=[json.loads(line[6:]) for line in response.read().decode().splitlines() if line.startswith('data: ')]
            connection.close()
            assert [e['sequence_number'] for e in events]==list(range(len(events)))
            assert events[-1]['type']=='response.completed'
            final=events[-1]['response']['output'][-1]
            assert token in final['content'][0]['text']
            assert any(e.get('item',{}).get('phase')=='commentary' for e in events)
            return events
        with ThreadPoolExecutor(max_workers=5) as pool:
            futures=[pool.submit(receive,n) for n in range(1,6)]
            deadline=time.monotonic()+3
            while len(provider.streams[token]['ready'])!=5 and time.monotonic()<deadline:time.sleep(.01)
            provider.arm(token,time.monotonic_ns()+100_000_000)
            rows=[future.result() for future in futures]
        evidence=provider.source_evidence(token)
        assert evidence['complete'] and not provider.failures
        assert len(evidence['events'])==len(workload['events'])
        assert len(evidence['messages'])==len(workload['notes'])+len(workload['terminal'])
        for event in evidence['events']+evidence['messages']:
            assert event['sentNS']>=event['plannedNS']
        metadata=provider.respond({'model':'fixture-model','stream':True,'input':[{'role':'user','content':[{
            'type':'input_text','text':'BENCH ITEM 01'}]}], 'text':{'format':{'schema':{'properties':{'title':{},'emoji':{}}}}}})
        assert json.loads(metadata[-1]['response']['output'][0]['content'][0]['text'])['title']=='BENCH CARD 01'
        try:provider.respond({'model':'wrong-model','stream':True})
        except ValueError:pass
        else:raise AssertionError('provider accepted the wrong discovered model')
    finally:provider.close()


def cancellation_replay(directory,control):
    directory.mkdir();provider=Provider(directory,5);provider.model='fixture-model';provider.effort='low'
    gate=threading.Event();respond=provider.respond
    def delayed(request):
        events=respond(request)
        def send():
            for index,event in enumerate(events):
                if index==1:assert gate.wait(5),'disconnect control did not release the source'
                yield event
        return send()
    provider.respond=delayed
    try:
        request={'model':'fixture-model','stream':True,'input':[{'role':'user','content':[
            {'type':'input_text','text':'BENCHMARK CREATE 5' if control else 'BENCH ITEM 01'}]}],
            'tools':[{'type':'function','name':'create_thread'}] if control else []}
        body=json.dumps(request).encode()
        connection=socket.create_connection(('127.0.0.1',provider.server.server_port),timeout=5)
        connection.sendall(b'POST /v1/responses HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer fixture-only\r\nContent-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body)
        received=b''
        while b'event: response.created' not in received:
            block=connection.recv(4096)
            assert block and len(received)<1024*1024,'disconnect control lost the initial response'
            received+=block
        connection.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('ii',1,0));connection.close();gate.set()
        deadline=time.monotonic()+3
        while not (provider.failures or provider.cancellations) and time.monotonic()<deadline:time.sleep(.01)
        assert bool(provider.cancellations)==control
        assert bool(provider.failures)!=control
    finally:gate.set();provider.close()


def shutdown_replay(directory):
    directory.mkdir();provider=Provider(directory,5);provider.model='fixture-model';provider.effort='low'
    token=provider.prepare_stream(schedule(5,2,'sustained'))
    connection=http.client.HTTPConnection('127.0.0.1',provider.server.server_port,timeout=5)
    try:
        connection.request('POST','/v1/responses',json.dumps({'model':'fixture-model','stream':True,
            'input':[{'role':'user','content':[{'type':'input_text','text':f'BENCH ITEM 01: BENCH STREAM 01 {token}'}]}]}),
            {'Authorization':'Bearer fixture-only','Content-Type':'application/json'})
        response=connection.getresponse()
        assert response.status==200
        provider.close()
        # The still-gated producer must finish and retain its failure before
        # close returns; a later evidence seal must have no live request writer.
        assert b'response.completed' not in response.read()
        receipt=json.loads((directory/'provider-outcome.json').read_text())
        assert receipt['failures'] and receipt['failures']==provider.failures
        assert json.loads((directory/'provider-errors.json').read_text())==receipt['failures']
    finally:
        connection.close()
        if not provider.stopping.is_set():provider.close()


def main():
    count=0
    with tempfile.TemporaryDirectory(prefix='overview-contract-') as temp:
        base=Path(temp)
        def run(name, mutate=None, expected_product=None, invalid=False, reseal=True):
            nonlocal count
            root=base/name;root.mkdir();p,o,f=fixture(root)
            if mutate:mutate(root,p,o,f)
            seal(root)
            if not reseal:(root/'outcome.json').write_text('{"status":"wrong-result"}')
            result=write_report(root)
            if expected_product is not None:assert result['product']==expected_product,(name,result)
            if invalid:assert result['measurement']=='invalid',(name,result)
            assert result['comparison']!='passed',(name,result)
            count+=1
            return result
        normal=run('normal',expected_product='passed')
        assert normal['measurement']=='incomplete'
        assert normal['metrics']['formal']['completeTaskCost'] is False
        def frames_change(root,p,o,f,change):
            for frame in f:change(frame)
            (root/'frames.jsonl').write_text(''.join(json.dumps(v)+'\n' for v in f))
        jitter=run('before-first-drag-jitter',lambda r,p,o,f:frames_change(r,p,o,f,
            lambda x:x['texts'][0].update(x=204) if x['atNS']==11_100_000_000 else None),expected_product='passed')
        assert jitter['metrics']['pan']['firstVisibleResponseSeconds']>=.2
        uncertain=run('motion-deadline-inside-sampling-interval',lambda r,p,o,f:frames_change(r,p,o,f,
            lambda x:x['texts'][0].update(x=196) if 11_300_000_000<=x['atNS']<=11_700_000_000 else None),expected_product='unknown')
        assert uncertain['metrics']['pan']['noProgressSecondsBounds']['lower']<.5<uncertain['metrics']['pan']['noProgressSecondsBounds']['upper']
        assert 'motion progress sampling uncertainty straddles the declared deadline' in uncertain['reasons']
        run('frozen',lambda r,p,o,f:frames_change(r,p,o,f,lambda x:x['texts'][0].update(x=200)),expected_product='overloaded')
        run('wrong-direction',lambda r,p,o,f:frames_change(r,p,o,f,lambda x:x['texts'][0].update(x=400-x['texts'][0]['x'])),expected_product='wrong-result')
        run('missing-frames',lambda r,p,o,f:(r/'frames.jsonl').unlink(),expected_product='unknown')
        run('missing-middle-motion',lambda r,p,o,f:frames_change(r,p,o,f,lambda x:x.update(texts=[])
            if 12_000_000_000<x['atNS']<14_000_000_000 else None),expected_product='unknown')
        run('tampered',reseal=False,invalid=True)
        run('invalid-png',lambda r,p,o,f:(r/'frame.png').write_bytes(b'not an image'),invalid=True)
        run('nonfinite',lambda r,p,o,f:(r/'plan.json').write_text((r/'plan.json').read_text().replace('0.5','NaN')),invalid=True)
        run('wrong-clock',lambda r,p,o,f:save(r/'observation.json',{**o,'clock':'milliseconds'}),invalid=True)
        run('wrong-owner',lambda r,p,o,f:save(r/'observation.json',{**o,'owner':{'pid':102,'identity':'102:1000'}}),invalid=True)
        run('wrong-role',lambda r,p,o,f:save(r/'observation.json',{**o,'resources':[{**x,'processes':[{**v,'role':'collector'} for v in x['processes']]} for x in o['resources']]}),invalid=True)
        run('negative-cpu',lambda r,p,o,f:save(r/'observation.json',{**o,'resources':[{**x,'processes':[{**v,'cpuNS':-1} for v in x['processes']]} for x in o['resources']]}),invalid=True)
        run('dishonest-coverage',lambda r,p,o,f:save(r/'observation.json',{**o,'processCoverage':{'complete':True,'gaps':[]}}),invalid=True)
        run('wrong-input',lambda r,p,o,f:save(r/'observation.json',{**o,'inputs':[{**e,'x':0} for e in o['inputs']]}),invalid=True)
        run('late-input',lambda r,p,o,f:save(r/'observation.json',{**o,'inputs':[{**e,'postedNS':e['postedNS']+1_000_000_000} for e in o['inputs']]}),invalid=True)
        run('reordered-capture',lambda r,p,o,f:(r/'frames.jsonl').write_text(''.join(json.dumps(v)+'\n' for v in reversed(f))),invalid=True)
        run('out-of-bounds-ocr',lambda r,p,o,f:frames_change(r,p,o,f,lambda x:x['texts'][0].update(width=10000)),invalid=True)
        run('detached-point-scale',lambda r,p,o,f:frames_change(r,p,o,f,lambda x:x.update(pointsWidth=500)),invalid=True)
        def wrong_scale(root,p,o,f):
            for frame in o['frames']:frame['pointsWidth']=500
            save(root/'observation.json',o)
            frames_change(root,p,o,f,lambda x:x.update(pointsWidth=500))
        run('wrong-window-point-scale',wrong_scale,invalid=True)
        run('crash',lambda r,p,o,f:save(r/'observation.json',{**o,'productExited':True}),expected_product='crash')
        run('failed-outcome',lambda r,p,o,f:save(r/'outcome.json',{'status':'wrong-result'}),expected_product='wrong-result')
        run('minimal',lambda r,p,o,f:save(r/'plan.json',{**p,'mode':'minimal'}),expected_product='unknown')
        run('missing-body-source',lambda r,p,o,f:save(r/'plan.json',{**p,'scenario':'body.pan'}),expected_product='unknown')
        def body_case(root,p,o,f,change=None):
            p['scenario']='body';p['workload']=schedule(5,4,'sustained',64,512);p['workload']['terminal']=[]
            save(root/'plan.json',p)
            source={'version':1,'clock':CLOCK,'startNS':o['boundaries']['formalStart'],'workload':p['workload'],
                    'complete':True,'done':[1,2,3,4,5],
                    'events':[{**e,'plannedNS':o['boundaries']['formalStart']+round(e['atSeconds']*1e9),
                               'sentNS':o['boundaries']['formalStart']+round(e['atSeconds']*1e9)} for e in p['workload']['events']]}
            source['messages']=[{**e,'plannedNS':source['startNS']+round(e['atSeconds']*1e9),
                                 'sentNS':source['startNS']+round(e['atSeconds']*1e9)} for e in p['workload']['notes']]
            for frame in f:
                seconds=(frame['atNS']-o['boundaries']['formalStart'])/1e9
                if 0<=seconds<4:
                    frame['texts'].append({'text':f'CHECK 01.{int(seconds)+1:04d}', 'x':200,'y':130,
                                           'width':120,'height':20,'confidence':1})
            if change:change(source,f)
            save(root/'source.json',source)
            (root/'frames.jsonl').write_text(''.join(json.dumps(v)+'\n' for v in f))
        run('body-complete',body_case,expected_product='passed')
        for observation in ({'confidence':.1},{'edgeClipped':True}):
            run('ineligible-body-marker-'+str(observation),lambda r,p,o,f,change=observation:body_case(r,p,o,f,
                lambda s,frames:[item.update(**change) for frame in frames for item in frame['texts']
                    if item['text'].startswith('CHECK')]),expected_product='unknown')
        run('body-progress-cannot-erase-uncertain-pan',lambda r,p,o,f:(body_case(r,p,o,f),frames_change(r,p,o,f,
            lambda x:x['texts'][0].update(x=196) if 11_300_000_000<=x['atNS']<=11_700_000_000 else None)),expected_product='unknown')
        absent=run('body-marker-observation-gap',lambda r,p,o,f:body_case(r,p,o,f,
            lambda s,frames:[frame.update(texts=[t for t in frame['texts'] if not t['text'].startswith('CHECK')])
                for frame in frames if 11_500_000_000<frame['atNS']<13_500_000_000]),expected_product='unknown')
        assert 'business body checkpoint visibility has an observation gap' in absent['reasons']
        def uncertain_body(source,frames):
            for frame in frames:
                if any(t['text'].startswith('CHECK') for t in frame['texts']):
                    seq=1 if frame['atNS']<12_500_000_000 else int((frame['atNS']-11_000_000_000)/1e9)+1
                    frame['texts'].append({'text':f'CHECK 02.{seq:04d}','x':400,'y':130,'width':120,'height':20,'confidence':1})
        uncertain=run('body-deadline-inside-sampling-interval',lambda r,p,o,f:body_case(r,p,o,f,uncertain_body),expected_product='unknown')
        assert 'body progress sampling uncertainty straddles the declared deadline' in uncertain['reasons']
        run('body-partial',lambda r,p,o,f:body_case(r,p,o,f,lambda s,f:s['events'].pop()),expected_product='unknown')
        run('body-wrong-bytes',lambda r,p,o,f:body_case(r,p,o,f,lambda s,f:s['events'][0].update(bytes=1)),invalid=True)
        run('body-late',lambda r,p,o,f:body_case(r,p,o,f,lambda s,f:s['events'][0].update(sentNS=s['events'][0]['sentNS']+1_000_000_000)),invalid=True)
        def omit_planned_card(root,p,o,f):
            body_case(root,p,o,f)
            p['workload']['events']=[e for e in p['workload']['events'] if e['card']!=5]
            save(root/'plan.json',p)
            source=json.loads((root/'source.json').read_text());source['workload']=p['workload']
            source['events']=[e for e in source['events'] if e['card']!=5];save(root/'source.json',source)
        run('source-plan-omits-card',omit_planned_card,invalid=True)
        run('body-frozen',lambda r,p,o,f:body_case(r,p,o,f,lambda s,f:[item.update(text='CHECK 01.0001') for frame in f for item in frame['texts'] if item['text'].startswith('CHECK')]),expected_product='unknown')
        def one_card_frozen(source,frames):
            for frame in frames:
                if any(item['text'].startswith('CHECK') for item in frame['texts']):
                    frame['texts'].append({'text':'CHECK 02.0001','x':400,'y':130,'width':120,'height':20,'confidence':1})
        run('one-card-freezes-among-progress',lambda r,p,o,f:body_case(r,p,o,f,one_card_frozen),expected_product='overloaded')
        def application_case(root,p,o,f,status='completed'):
            fixture={'count':5,'threads':[{'id':str(n),'title':f'BENCH CARD {n:02d}'} for n in range(1,6)],
                     'uiThreadIDs':[str(n) for n in range(1,6)],
                     'observedNS':p['startNS']-1,'runtimeInsertionDeletion':False}
            p.update(targetKind='application',fixture=fixture)
            save(root/'plan.json',p);save(root/'existing-fixture.json',fixture)
            save(root/'artifact.json',{});save(root/'native-cli.json',{})
            save(root/'outcome.json',{'status':'passed','threads':fixture['threads']})
            save(root/'tail-outcome.json',{'beforeNS':o['boundaries']['tailEnd']+1,'afterNS':o['boundaries']['tailEnd']+2,'status':status})
        run('uncalibrated-application',application_case,expected_product='unknown')
        unprepared=run('unprepared-mouse-down',lambda r,p,o,f:(application_case(r,p,o,f),
            frames_change(r,p,o,f,lambda x:x['texts'][0].update(x=200))),expected_product='unknown')
        assert 'unverified mouse-down target cannot establish canvas responsiveness' in unprepared['reasons']
        assert 'input did not produce timely business motion' not in unprepared['reasons']
        def pending_projection(root,p,o,f):
            application_case(root,p,o,f);p['fixture']['uiThreadIDs'].pop();save(root/'plan.json',p)
        run('cards-not-projected-before-timing',pending_projection,invalid=True)
        late=run('work-beyond-tail',lambda r,p,o,f:application_case(r,p,o,f,'pending'))
        assert 'business work still pending beyond the declared catch-up tail' in late['reasons']
        changed=run('changed-card-set',lambda r,p,o,f:(application_case(r,p,o,f),save(r/'outcome.json',{'status':'passed','threads':[]})))
        assert 'pre-existing card count/identity/title changed' in changed['reasons']
        for raw in ('{"x":1,"x":2}','{"x":Infinity}','{"x":-Infinity}'):
            try:loads(raw)
            except ValueError:count+=1
            else:raise AssertionError('malformed JSON accepted')
        for pacing in ('sparse','sustained','burst'):
            w=schedule(5,8,pacing)
            for n in range(1,6):
                events=[e for e in w['events'] if e['card']==n]
                assert events[0]['text'].startswith(f'CHECK {n:02d}.0001 ')
                assert all(len(e['text'].encode())==64 for e in events)
                assert all(e['sha256']==hashlib.sha256(e['text'].encode()).hexdigest() for e in events)
            count+=1
        provider_replay(base/'provider-http');count+=1
        for control in (False,True):cancellation_replay(base/('disconnect-'+str(control)),control);count+=1
        shutdown_replay(base/'shutdown-gated-stream');count+=1
        ownership_replay();count+=3
        fixed={'threads':[{'id':str(n)} for n in range(5)]}
        owner={'active':True,'axTruncated':False,'windowID':2,'process':{'identity':'101:1000'},
               'bounds':{'x':50,'y':60,'width':1000,'height':700},'accessibility':[
                   {'AXIdentifier':'overview.canvas','bounds':{'x':50,'y':160,'width':1000,'height':600}}]+[
                   {'AXIdentifier':f'overview-card-{n}','bounds':{'x':50+300*(n%3),'y':160+190*(n//3),'width':280,'height':180}}
                   for n in range(5)]}
        point=background_point(owner,fixed)
        record={'beforeNS':1,'afterNS':2,'owner':owner,'context':'same-window','point':point}
        planned={'scenario':'pan','processIdentity':'101:1000','windowID':2,'windowBounds':owner['bounds'],
                 'fixture':fixed,'startNS':3,'events':[{'kind':'down','x':50+point['x'],'y':60+point['y']}]}
        assert validate_preparation(record,planned)=='same-window';count+=1
        for change in ('missing-card','covered','wrong-point','late-preparation'):
            changed=copy.deepcopy(record)
            if change=='missing-card':changed['owner']['accessibility'].pop()
            elif change=='covered':changed['owner']['accessibility'].append({'AXRole':'AXTextArea','bounds':owner['bounds']})
            elif change=='wrong-point':changed['point']['x']+=10
            else:changed['afterNS']=4
            try:validate_preparation(changed,planned)
            except ValueError:count+=1
            else:raise AssertionError('unverified input target accepted: '+change)
        from runner import trajectory,reanchor
        offsets={'x':point['x']-(1000-70),'y':point['y']-(700-110)}
        relative=reanchor(trajectory({'x':70,'y':110,'width':0,'height':0},6),offsets,{'x':0,'y':0})
        down=next(e for e in relative if e['kind']=='down')
        assert down['x']+(1000-70)==point['x'] and down['y']+(700-110)==point['y'];count+=1
        p={'count':5,'fixture':{'threads':[{'id':str(n)} for n in range(1,6)]},
           'workload':{'terminal':[{'card':n,'text':f'actual result {n}'} for n in range(1,6)]}}
        threads=[{'id':str(n),'observation':{'latestExecution':{'executionId':f'new-{n}','status':'completed','summary':f'actual result {n}'}}} for n in range(1,6)]
        preparation={'executions':{str(n):f'new-{n}' for n in range(1,6)},'threads':copy.deepcopy(threads)}
        for row in preparation['threads']:row['observation']['latestExecution']['status']='running'
        assert completed_executions(p,preparation,threads);count+=1
        threads[0]['observation']['latestExecution']['executionId']='previous-completed-execution'
        assert not completed_executions(p,preparation,threads);count+=1
        threads[0]['observation']['latestExecution'].update(executionId='new-1',summary='actual result 2')
        assert not completed_executions(p,preparation,threads);count+=1
        preparation['threads'][0]['observation']['latestExecution']['status']='completed'
        try:completed_executions(p,preparation,threads)
        except ValueError:count+=1
        else:raise AssertionError('inactive card accepted as prepared running work')
        sustained=schedule(5,8,'sustained');burst=schedule(5,8,'burst')
        assert [(e['text'],e['bytes']) for e in sustained['events']]==[(e['text'],e['bytes']) for e in burst['events']]
        assert [e['atSeconds'] for e in sustained['events']]!=[e['atSeconds'] for e in burst['events']]
    print(f'External benchmark conformance: {count} adverse/contract replays passed; no host capability certified.')
    return 0
