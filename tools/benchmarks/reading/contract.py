"""Reading additions to the shared plan boundary; no product state assumptions."""
import re
import hashlib

from contracts.model import integer, number, text
from reading.corpus import document
from reading.plan import SCENARIOS


def validate(plan):
    if plan["scenario"] not in SCENARIOS or plan["count"] != 1:
        raise ValueError("reading experiments require one existing Agent Thread")
    reading = plan["reading"]
    corpus = reading["corpus"]
    execution = integer(corpus["execution"], "prepared reply ordinal", 1, 1)
    target = integer(corpus["targetBytes"], "target body bytes", 8192, 131072)
    expected = document(execution, target // 1024).manifest()
    if corpus != expected or target % 1024:
        raise ValueError("reading corpus does not match its versioned workload")
    if plan["anchors"] != expected["anchors"]:
        raise ValueError("reading anchors do not identify the selected body")
    text(reading["executionId"], "selected public execution identity")
    trigger = reading["entryTrigger"]
    if plan["scenario"] in ("reading.first-open", "reading.reopen"):
        if type(trigger) is not dict or set(trigger) != {"kind", "atSeconds"} or trigger.get("kind") != "up":
            raise ValueError("entry must begin at the declared card click")
        if len([event for event in plan["events"]
            if all(event.get(key) == value for key, value in trigger.items())]) != 1:
            raise ValueError("entry trigger must identify exactly one planned system input")
    elif trigger is not None:
        raise ValueError("steady scroll cannot declare a navigation trigger")
    segments = reading["segments"]
    if type(segments) is not list or not 2 <= len(segments) <= 20:
        raise ValueError("reading requires bounded, bidirectional scroll segments")
    previous = 0
    directions = set()
    covered = set()
    for segment in segments:
        start = number(segment["startSeconds"], "scroll start", previous, plan["formalSeconds"])
        end = number(segment["endSeconds"], "scroll end", start + .2, plan["formalSeconds"])
        previous = end
        if type(segment["direction"]) is not int or segment["direction"] not in (-1, 1):
            raise ValueError("scroll direction must be signed")
        directions.add(segment["direction"])
        events = [(index, event) for index, event in enumerate(plan["events"])
                  if event["kind"] == "scroll" and start <= event["atSeconds"] <= end]
        if len(events) < 3 or covered.intersection(index for index, _ in events):
            raise ValueError("missing or overlapping scroll inputs")
        covered.update(index for index, _ in events)
        if events[0][1]["phase"] != 1 or events[-1][1]["phase"] != 4:
            raise ValueError("scroll gesture must have began/ended phases")
        if events[-1][1]["deltaY"] != 0 or events[-1][1]["atSeconds"] != end:
            raise ValueError("scroll ending must be zero at its declared boundary")
        for _, event in events[:-1]:
            integer(event["deltaY"], "scroll pixels", -20, 20)
            if event["deltaY"] * segment["direction"] <= 0:
                raise ValueError("input contradicts planned direction")
        if any(event["phase"] != 2 for _, event in events[1:-1]):
            raise ValueError("interior scroll phase must be changed")
        if sum(event["deltaY"] for _, event in events) != segment["inputPixels"]:
            raise ValueError("scroll workload differs from declared input volume")
        if segment["minimumTravelPoints"] != abs(segment["inputPixels"]):
            raise ValueError("pixel input and declared minimum scroll travel differ")
    if directions != {-1, 1}:
        raise ValueError("document scrolling must include both directions")
    if covered != {index for index, event in enumerate(plan["events"]) if event["kind"] == "scroll"}:
        raise ValueError("unaccounted scroll event")
    if plan["scenario"] == "reading.output-scroll":
        source = reading["source"]
        if not re.fullmatch(r"[a-f0-9]{32}", text(source["token"], "source token", 32)):
            raise ValueError("invalid source token")
        if source["durationSeconds"] != plan["formalSeconds"]:
            raise ValueError("source and measurement windows differ")
        validate_source(source)
        if source["terminal"]["text"] != document(2, target // 1024).markdown:
            raise ValueError("terminal output does not contain the declared next document")
    return plan


def terminal_fragment(source):
    return {**source["terminal"], "sequence": len(source["events"]) + 1, "part": 0}


def validate_source(source):
    messages, events = source["messages"], source["events"]
    if type(messages) is not list or not 2 <= len(messages) <= 100 or type(events) is not list or len(events) > 10000:
        raise ValueError("dynamic reading requires bounded settled business replies")
    previous = -1
    for event in [*events, *messages, source["terminal"]]:
        if event["card"] != 1:
            raise ValueError("reader output targets another thread")
        integer(event["message"], "source message", 1, 101)
        number(event["atSeconds"], "source deadline", 0, source["durationSeconds"])
        encoded = text(event["text"], "source text", 200000).encode("utf-8")
        if len(encoded) != event["bytes"] or hashlib.sha256(encoded).hexdigest() != event["sha256"]:
            raise ValueError("reading source payload length/digest mismatch")
    for index, event in enumerate(events, 1):
        if event["sequence"] != index or event["atSeconds"] <= previous:
            raise ValueError("source fragments are not uniquely ordered")
        previous = event["atSeconds"]
    covered = set()
    for index, message in enumerate(messages, 1):
        if message["message"] != index or message["kind"] != "settled":
            raise ValueError("settled replies are not uniquely ordered")
        pieces = [event for event in events if event["message"] == index]
        if (not pieces or [event["part"] for event in pieces] != list(range(len(pieces)))
                or "".join(event["text"] for event in pieces) != message["text"]
                or pieces[-1]["atSeconds"] > message["atSeconds"]
                or message["checkpoint"] not in message["text"]):
            raise ValueError("settled reply does not match its preceding fragments")
        covered.update(event["sequence"] for event in pieces)
    if covered != {event["sequence"] for event in events}:
        raise ValueError("source contains orphaned fragments")
    terminal = source["terminal"]
    if terminal["kind"] != "terminal" or terminal["message"] != len(messages) + 1 or terminal["atSeconds"] != source["durationSeconds"]:
        raise ValueError("terminal reply does not close the declared output window")
