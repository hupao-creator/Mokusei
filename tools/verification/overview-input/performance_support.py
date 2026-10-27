"""Shared host-interference classification; ps ucomm may truncate to 15 characters."""


def interfering_process(process, own_pid):
    if process["pid"] == own_pid:
        return False
    name = process["name"].strip().lower()
    native = any(part in name for part in (
        "replay", "xctest", "overviewinput", "readingpresent", "mokuseinativepa", "probe", "xctrace")) or name.endswith(".test")
    compiler = name in {"swift-frontend", "clang", "compile", "link"} or name.startswith("clang-")
    return native or (compiler and process["cpu"] >= 20)
