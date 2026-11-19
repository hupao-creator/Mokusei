"""Exercise pressure, return selection, promotion and the two-cell release margin."""
import subprocess

from adapter import wait_for
from report import save


def enable_reports(session, enabled):
    state = session.runtime.state()
    settings = state["settings"]
    entry = next(value for value in settings["pluginSettings"] if value["id"] == "report.settings")
    entry["value"]["enabled"] = enabled
    result = session.runtime.invoke("app:update-settings", [{"settings": settings,
                                    "expectedSettingsRevision": state["settingsRevision"]}])
    if result.get("status") == "conflict":
        raise RuntimeError("isolated report settings conflicted")


def prepare(session):
    projects = [str(path.resolve()) for path in session.peer.collection_projects]

    def catalog():
        if session.peer.failures:
            raise RuntimeError(f"report fixture failed: {session.peer.failures}")
        return [r for r in session.runtime.state()["applicationThreads"] if r["ref"]["typeId"] == "report.document"]

    reports = wait_for(catalog, lambda rows: len(rows) >= 8, 90)
    assert len(reports) == 8 and all(sum(r["scope"] == p for r in reports) == 4 for p in projects)
    save(session.output / "collection-catalog.json", reports)
    return sorted(reports, key=lambda r: r["createdAt"])


def journey(desktop, reports):
    output = desktop.session.output
    refs = [r["ref"] for r in reports]
    def overview(filter_id=None):
        return desktop.stable(lambda s: s["page"] == "overview" and s["selectedFilterId"] == filter_id
                              and not s["overview"]["layingOut"] and s["overview"]["cards"]
                              and set(s["overview"]["mountedCardIds"]) == {c["id"] for c in s["overview"]["cards"]})

    def observe(name, expected_cells, expected_members, filter_id=None):
        state = overview(filter_id)
        save(output / f"collection-{name}.json", state)
        cards = state["overview"]["cards"]
        assert sum(c["columns"] * c["rows"] for c in cards) == expected_cells
        groups = [c for c in cards if "members" in c]
        assert [c["members"] for c in groups] == ([expected_members] if expected_members else [])
        assert all(not item["eligibility"]["defaultsToCollection"] and item["eligibility"]["collected"]
                   for group in groups for item in group["memberEligibility"])
        return state

    # Activate only the unique isolated application. The control socket checks
    # its PID on every observation, and reading must actually own the key window.
    bundle = desktop.session.app.args[0]
    subprocess.run(["/usr/bin/open", "-a", bundle.rsplit("/Contents/", 1)[0]], check=True, timeout=10)
    initial = observe("initial", 16, refs[:2])
    directory = next(f for f in initial["overview"]["filters"] if f["scope"] == reports[0]["scope"]
                     and f["kind"] == "directory")
    desktop.request({"name": "filter.select", "filterId": directory["id"]})
    observe("directory", 9, [], directory["id"])
    desktop.request({"name": "filter.select", "filterId": None})
    observe("grouped", 16, refs[:2])

    def visit(qualify):
        desktop.request({"name": "thread.open", **refs[1]})
        desktop.stable(lambda s: s["page"] == "thread" and s["selectedThread"] == refs[1]
                       and s["reading"]["foreground"])
        if qualify:
            wait_for(desktop.request, lambda s: s["reading"]["collectionEligibility"]["lastQualifiedAt"] is not None, 50)
        desktop.request({"name": "overview.show"})

    visit(False)
    closed = observe("closed", 16, refs[:2])
    group = next(c for c in closed["overview"]["cards"] if "members" in c)
    assert group["ref"] == refs[1]
    visit(True)
    returned = observe("return", 16, [refs[0], refs[2]])
    promoted = next(c for c in returned["overview"]["cards"] if c.get("id") == refs[1]["threadId"])
    assert promoted["collectionEligibility"]["lastQualifiedAt"]

    def archive(ref, archived):
        desktop.session.runtime.invoke("application:archive", [ref, archived])
        desktop.stable(lambda s: any(c.get("ref") == ref for c in s["overview"]["cards"]) != archived)

    archive(refs[-1], True)
    observe("at-budget", 14, [refs[0], refs[2]])
    archive(refs[-2], True)
    observe("released", 14, [])
    archive(refs[-2], False)
    archive(refs[-1], False)
    observe("restored", 16, [refs[0], refs[2]])
