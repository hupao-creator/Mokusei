"""Aggregate an exported Instruments Time Profiler XML table by thread and leaf symbol.

Usage: python3 summarize_time_profile.py trace-export.xml > summary.json
The export is produced with:
  xcrun xctrace export --input trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' --output export.xml
Rows are weighted samples; a frame's first entry is the sampled leaf. `ref` attributes
must be resolved against the first element carrying that id in the file.
"""
import json
import sys
import xml.etree.ElementTree as ET

def main():
    root = ET.parse(sys.argv[1]).getroot()
    ids = {}
    for element in root.iter():
        identifier = element.get("id")
        if identifier is not None and identifier not in ids:
            ids[identifier] = element

    def resolve(element):
        seen = set()
        while element is not None and element.get("ref") is not None:
            ref = element.get("ref")
            if ref in seen:
                return None
            seen.add(ref)
            element = ids.get(ref)
        return element

    threads = {}
    total_ns = 0
    for row in root.findall(".//row"):
        weight = resolve(row.find("weight"))
        if weight is None or not (weight.text or "").strip():
            continue
        ns = int(weight.text)
        thread = resolve(row.find("thread"))
        if thread is None or not (thread.get("fmt") or ""):
            continue
        name = thread.get("fmt")
        leaf = resolve(row.find("tagged-backtrace"))
        leaf_name = "unknown"
        if leaf is not None and leaf.tag == "tagged-backtrace":
            backtrace = resolve(leaf.find("backtrace"))
            if backtrace is not None:
                frame = resolve(backtrace.find("frame"))
                if frame is not None:
                    leaf_name = frame.get("name") or "unknown"
        thread_entry = threads.setdefault(name, {"ns": 0, "leaves": {}})
        thread_entry["ns"] += ns
        thread_entry["leaves"][leaf_name] = thread_entry["leaves"].get(leaf_name, 0) + ns
        total_ns += ns

    result = {"totalWeightedNs": total_ns, "threads": []}
    for name, entry in sorted(threads.items(), key=lambda item: -item[1]["ns"]):
        result["threads"].append({
            "thread": name,
            "weightedMs": round(entry["ns"] / 1e6, 3),
            "share": round(entry["ns"] / total_ns, 4) if total_ns else 0,
            "topLeaves": [{"symbol": symbol, "ms": round(ns / 1e6, 3)}
                          for symbol, ns in sorted(entry["leaves"].items(), key=lambda item: -item[1])[:15]],
        })
    json.dump(result, sys.stdout, indent=2)

if __name__ == "__main__":
    main()
