"""Absolute-clock system inputs; preparation never counts as measured work."""

SCENARIOS = ("reading.first-open", "reading.reopen", "reading.scroll", "reading.active-open",
             "reading.output-scroll")
ENTRY_SCENARIOS = ("reading.first-open", "reading.reopen", "reading.active-open")


def click(point, at):
    return [{"kind": "move", "atSeconds": at - .05, **point},
            {"kind": "down", "atSeconds": at, **point},
            {"kind": "up", "atSeconds": at + .04, **point}]


def scroll(point, start, direction):
    # The native control checks delivered pixel volume and optical travel.
    # AppKit may add settling movement after the supplied gesture ends.
    events = [{"kind": "move", "atSeconds": start - .05, **point}]
    for index in range(72):
        events.append({"kind": "scroll", "atSeconds": start + index / 60,
                       "deltaY": direction * 5, "phase": 1 if index == 0 else 2, **point})
    events.append({"kind": "scroll", "atSeconds": start + 1.2,
                   "deltaY": 0, "phase": 4, **point})
    segment = {"startSeconds": start, "endSeconds": start + 1.2,
               "direction": direction, "inputPixels": direction * 360,
               "minimumTravelPoints": 360}
    return events, segment


def interaction(scenario, document_point, card_point=None):
    if scenario not in SCENARIOS:
        raise ValueError("unknown reading scenario")
    events, segments = [], []
    trigger = None
    if scenario in ENTRY_SCENARIOS:
        if card_point is None:
            raise ValueError("entry requires the observed card position")
        events.extend(click(card_point, .2))
        trigger = {"kind": "up", "atSeconds": events[-1]["atSeconds"]}
        starts = ((4.0, -1), (5.8, 1), (7.6, -1))
    else:
        starts = ((.4, -1), (2.2, 1), (4.0, -1), (5.8, 1), (7.6, -1))
    for start, direction in starts:
        motion, segment = scroll(document_point, start, direction)
        events.extend(motion); segments.append(segment)
    return {"events": sorted(events, key=lambda event: event["atSeconds"]),
            "segments": segments, "entryTrigger": trigger,
            "formalSeconds": 10.0, "tailSeconds": 3.0}
