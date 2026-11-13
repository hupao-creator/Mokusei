"""Choose a mouse-down point from public AX geometry before measurement."""
import math

from contracts.model import integer, number


def background_point(owner, fixture):
    if owner.get('axTruncated') is not False:
        raise ValueError('complete accessibility geometry unavailable for drag preparation')
    window=owner['bounds']
    def rectangle(value):
        return tuple(number(value[k], 'accessibility '+k, -100_000 if k in ('x','y') else 0, 100_000)
                     for k in ('x','y','width','height'))
    wx,wy,ww,wh=rectangle(window)
    rows=owner['accessibility']
    canvas=[r for r in rows if r.get('AXIdentifier')=='overview.canvas']
    if len(canvas)!=1 or 'bounds' not in canvas[0]:
        raise ValueError('public Overview canvas accessibility surface unavailable')
    cx,cy,cw,ch=rectangle(canvas[0]['bounds'])
    expected={'overview-card-'+t['id'] for t in fixture['threads']}
    cards={}
    blocked=[]
    for row in rows:
        identifier=row.get('AXIdentifier')
        if identifier in expected:
            if identifier in cards or 'bounds' not in row:
                raise ValueError('ambiguous or unavailable card accessibility geometry')
            cards[identifier]=rectangle(row['bounds'])
        elif row.get('AXRole') in ('AXButton','AXTextField','AXTextArea','AXComboBox','AXPopUpButton'):
            if 'bounds' not in row:raise ValueError('interactive control geometry unavailable')
            blocked.append(rectangle(row['bounds']))
    if cards.keys()!=expected:
        raise ValueError('card accessibility geometry does not cover the existing fixture')
    if any(w<=0 or h<=0 for _,_,w,h in cards.values()):
        raise ValueError('card accessibility geometry has no extent')
    blocked+=list(cards.values())
    # Only the down point needs a gap: the mouse gesture owns subsequent drag
    # events. Leave room for the unchanged 120pt leftward trajectory and chrome.
    left,right,top,bottom=max(wx+150,cx+3),min(wx+ww-24,cx+cw-3),max(wy+160,cy+3),min(wy+wh-100,cy+ch-3)
    if left>=right or top>=bottom:raise ValueError('window has no safe drag input region')
    xs=sorted({left,right,*[max(left,min(right,v)) for x,_,w,_ in blocked for v in (x,x+w)]})
    ys=sorted({top,bottom,*[max(top,min(bottom,v)) for _,y,_,h in blocked for v in (y,y+h)]})
    candidates=[((a+b)/2,(c+d)/2) for a,b in zip(xs,xs[1:]) for c,d in zip(ys,ys[1:])]
    def clearance(point):
        x,y=point
        return min(math.hypot(max(bx-x,0,x-bx-bw),max(by-y,0,y-by-bh)) for bx,by,bw,bh in blocked)
    point=max(candidates,key=lambda p:(clearance(p),p[0],p[1]),default=None)
    if point is None or clearance(point)<3:
        raise ValueError('no externally verified background gap for mouse-down')
    return {'x':point[0]-wx,'y':point[1]-wy}


def validate_preparation(record, plan):
    integer(record['beforeNS'],'input preparation start',1)
    integer(record['afterNS'],'input preparation end',record['beforeNS'],plan['startNS'])
    owner=record['owner']
    if owner.get('active') is not True:raise ValueError('input preparation target was not foreground')
    context=record['context']
    expected_context='reopen' if plan['scenario']=='first-render' else 'same-window'
    if context!=expected_context:raise ValueError('input preparation context differs from scenario')
    if context!='reopen' and owner['process']['identity']!=plan['processIdentity']:
        raise ValueError('input preparation belongs to another application owner')
    if context!='reopen' and owner['windowID']!=plan['windowID']:
        raise ValueError('input preparation belongs to another OS window')
    if any(owner['bounds'][k]!=plan['windowBounds'][k] for k in ('width','height')):
        raise ValueError('input preparation viewport differs from measured viewport')
    point=background_point(owner,plan['fixture'])
    if point!=record['point']:raise ValueError('input preparation point differs from retained AX evidence')
    down=next(e for e in plan['events'] if e['kind']=='down')
    if any(abs(down[k]-plan['windowBounds'][k]-point[k])>1e-6 for k in ('x','y')):
        raise ValueError('mouse-down does not use the prepared background point')
    return context
