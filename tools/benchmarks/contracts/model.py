"""Untrusted JSON enters through this versioned, bounded contract."""
import json
import math
from pathlib import Path

VERSION = 1
CLOCK = 'macos.mach_absolute_time.nanoseconds'
SCENARIOS = ('first-render', 'idle.completed', 'idle.active', 'pan', 'zoom', 'return',
             'body', 'body.pan', 'body.zoom')
ROLES = ('application', 'runtime', 'helper', 'collector', 'source')


def number(value, name, minimum=0, maximum=1e30):
    if type(value) not in (int, float) or not math.isfinite(value) or not minimum <= value <= maximum:
        raise ValueError(f'{name}: expected finite number in [{minimum}, {maximum}]')
    return value


def integer(value, name, minimum=0, maximum=2**63-1):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f'{name}: expected integer in [{minimum}, {maximum}]')
    return value


def text(value, name, limit=4096):
    if not isinstance(value, str) or not value or len(value) > limit:
        raise ValueError(f'{name}: expected bounded nonempty string')
    return value


def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate JSON field: {key}')
        result[key] = value
    return result


def loads(raw):
    return json.loads(raw, object_pairs_hook=object_pairs,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f'nonfinite JSON: {value}')))


def load(path):
    path = Path(path)
    if path.stat().st_size > 128 * 1024 * 1024:
        raise ValueError('evidence JSON exceeds size bound')
    return loads(path.read_text())


def envelope(value, kind):
    if type(value) is not dict or type(value.get('version')) is not int or value['version'] != VERSION or value.get('kind') != kind:
        raise ValueError(f'unsupported {kind} envelope')
    if value.get('clock') != CLOCK:
        raise ValueError('clock/unit mismatch')
    return value


def plan(value):
    envelope(value, 'plan')
    reading = isinstance(value.get('scenario'), str) and value['scenario'].startswith('reading.')
    scenarios = SCENARIOS
    if reading:
        from reading.plan import SCENARIOS as reading_scenarios
        scenarios = reading_scenarios
    if value.get('scenario') not in scenarios or value.get('mode') not in ('observed', 'minimal'):
        raise ValueError('unknown scenario or observation mode')
    if type(value.get('count')) is not int or value['count'] not in ((1,) if reading else (5, 10, 20)):
        raise ValueError('unsupported existing thread count for this scenario family')
    if value.get('targetKind') not in ('application','control'):raise ValueError('unknown target kind')
    if value['targetKind']=='application':
        fixture=value['fixture']
        if fixture['count']!=value['count'] or fixture.get('runtimeInsertionDeletion') is not False:
            raise ValueError('fixture must have the fixed pre-existing card count')
        threads=fixture['threads']
        if len(threads)!=value['count'] or len({t['id'] for t in threads})!=value['count']:
            raise ValueError('fixture identities/count incomplete')
        if fixture.get('uiThreadIDs')!=sorted(t['id'] for t in threads):
            raise ValueError('pre-existing card set has not reached the public UI projection')
        for thread in threads:text(thread['id'],'fixture identity');text(thread['title'],'fixture title')
        integer(fixture['observedNS'],'fixture observation',1,value['startNS'])
    for key in ('pid', 'windowID', 'startNS'):
        integer(value[key], key, 1)
    text(value['processIdentity'], 'process identity')
    bounds=value['windowBounds']
    for axis in ('x','y'):number(bounds[axis],'window '+axis,-100_000,100_000)
    for dimension in ('width','height'):number(bounds[dimension],'window '+dimension,100,16384)
    for key in ('warmupSeconds', 'formalSeconds', 'tailSeconds'):
        number(value[key], key, .05, 120)
    for key in ('sampleHz', 'captureHz'):
        number(value[key], key, 1, 60)
    number(value['maximumNoProgressSeconds'], 'progress budget', .1, 30)
    number(value['maximumCaptureGapSeconds'], 'capture gap budget', .05, 5)
    number(value['motionTolerancePixels'], 'motion tolerance', 0, 100)
    anchors = value['anchors']
    if type(anchors) is not list or not 1 <= len(anchors) <= (2000 if reading else 20) or len(set(anchors)) != len(anchors):
        raise ValueError('distinct business anchors required; no visible-count constraint')
    for anchor in anchors:
        text(anchor, 'anchor', 100)
    roots = value['processRoots']
    if type(roots) is not list or not roots or len(roots) > 256:
        raise ValueError('bounded process roots required')
    for root in roots:
        integer(root['pid'], 'root pid', 1)
        text(root['identity'], 'root identity')
        if root['role'] not in ROLES:
            raise ValueError('invalid process role')
    if len({r['pid'] for r in roots}) != len(roots):
        raise ValueError('duplicate root pid')
    if not any(r['pid'] == value['pid'] and r['identity'] == value['processIdentity'] and r['role'] == 'application' for r in roots):
        raise ValueError('target application is not an identified resource root')
    events = value['events']
    if type(events) is not list or len(events) > 20_000:
        raise ValueError('bounded input schedule required')
    previous, down, pressed_key = -1, False, None
    for event in events:
        at = number(event['atSeconds'], 'input deadline', 0, value['formalSeconds'] + value['tailSeconds'])
        if at <= previous:
            raise ValueError('input deadlines must strictly increase')
        previous = at
        kind = event['kind']
        if kind not in ('move', 'down', 'drag', 'up', 'zoom', 'keyDown', 'keyUp', 'scroll'):
            raise ValueError('unsupported input kind')
        if kind == 'down':
            if down: raise ValueError('duplicate mouse down')
            down = True
        elif kind in ('drag', 'up'):
            if not down: raise ValueError('drag/up without down')
            if kind == 'up': down = False
        if kind in ('keyDown', 'keyUp'):
            key = integer(event.get('keyCode'), 'navigation key', 0, 127)
            if reading:
                raise ValueError('reading scenarios use pointer input only')
            elif key != 40:
                raise ValueError('only Command-K is an allowed navigation key')
            if kind == 'keyDown':
                if pressed_key is not None: raise ValueError('overlapping navigation keys')
                pressed_key = key
            else:
                if pressed_key != key: raise ValueError('navigation key release mismatch')
                pressed_key = None
        if kind == 'scroll':
            if not reading or type(event.get('phase')) is not int or event['phase'] not in (1, 2, 4):
                raise ValueError('unsupported pixel scroll phase/scenario')
            integer(event['deltaY'], 'pixel scroll delta', -20, 20)
        if kind == 'zoom':
            integer(event['delta'], 'wheel delta', -100, 100)
        for axis in ('x', 'y'):
            number(event[axis], axis, -100_000, 100_000)
    if down or pressed_key is not None:
        raise ValueError('input gesture lacks a release')
    keys=[e['kind'] for e in events if e['kind'] in ('keyDown','keyUp')]
    if keys and keys != ['keyDown','keyUp']:
        raise ValueError('navigation keyboard sequence incomplete')
    if 'pan' in value['scenario'] and not any(e['kind'] == 'drag' for e in events):
        raise ValueError('pan scenario lacks real drag inputs')
    if 'zoom' in value['scenario'] and not any(e['kind'] == 'zoom' for e in events):
        raise ValueError('zoom scenario lacks real zoom inputs')
    if reading:
        from reading.contract import validate
        validate(value)
    return value
