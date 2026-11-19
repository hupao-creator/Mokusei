"""Exercise the selected space and the real five-minute close deadline."""
import time

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
    return sorted((r for r in reports if r["scope"] == projects[0]), key=lambda r: r["createdAt"])[:3]


def journey(desktop, reports):
    output = desktop.session.output
    refs = [r["ref"] for r in reports]
    ids = [ref["threadId"] for ref in refs]

    def overview(filter_id=None):
        return desktop.stable(lambda s: s["page"] == "overview" and s["selectedFilterId"] == filter_id
                              and not s["overview"]["layingOut"] and len(s["overview"]["cards"]) > 0
                              and set(s["overview"]["mountedCardIds"]) == {c["id"] for c in s["overview"]["cards"]})

    def cells(cards):
        return sum(card["columns"] * card["rows"] for card in cards)

    def open_and_close(ref):
        desktop.request({"name": "thread.open", **ref})
        desktop.stable(lambda s: s["page"] == "thread" and s["selectedThread"] == ref)
        desktop.request({"name": "overview.show"})
        return overview()

    def check_grouped(state):
        cards = state["overview"]["cards"]
        groups = [c for c in cards if "members" in c]
        assert len(groups) == 1 and groups[0]["members"] == refs[:2] and cells(cards) == 16
        assert all(item["eligibility"]["eligible"] and item["eligibility"]["collected"]
                   for item in groups[0]["memberEligibility"])
        third = next(c for c in cards if c["id"] == ids[2])["collectionEligibility"]
        assert third["eligible"] and not third["collected"]
        unread = [c["collectionEligibility"] for c in cards if "collectionEligibility" in c and c["id"] not in ids]
        assert len(unread) == 5 and all(not c["eligible"] and c["lastClosedAt"] is None for c in unread)
        assert {r["threadId"] for r in state["threads"]} == initial_ids

    initial = overview()
    save(output / "collection-initial.json", initial)
    cards = initial["overview"]["cards"]
    initial_ids = {c["id"] for c in cards}
    assert len(cards) == 10 and cells(cards) == 18 and all("members" not in c for c in cards)
    unrelated = next(c["ref"] for c in cards if c.get("ref", {}).get("typeId") == "report.document"
                     and c["ref"] not in refs)
    directory = next(f for f in initial["overview"]["filters"] if f["scope"] == reports[0]["scope"] and f["kind"] == "directory")
    assert directory["count"] == 5
    for ref in refs:
        state = open_and_close(ref)
    save(output / "collection-closed.json", state)
    closed = [c["collectionEligibility"] for c in state["overview"]["cards"] if c["id"] in ids]
    assert len(closed) == 3 and all(c["lastClosedAt"] and not c["eligible"] for c in closed)
    # No clock injection or background polling. Reconnect after the real policy
    # interval so the idle socket lifetime is independent of reading evidence.
    deadline = max(c["lastClosedAt"] / 1000 for c in closed) + 300
    time.sleep(max(0, deadline - time.time()))
    desktop.reconnect()
    grouped = desktop.stable(lambda s: s["page"] == "overview" and any(
        c["id"] == ids[2] and c["collectionEligibility"]["eligible"] for c in s["overview"]["cards"]))
    save(output / "collection-grouped.json", grouped)
    check_grouped(grouped)

    desktop.request({"name": "filter.select", "filterId": directory["id"]})
    narrow = overview(directory["id"])
    save(output / "collection-directory.json", narrow)
    cards = narrow["overview"]["cards"]
    assert len(cards) == 5 and cells(cards) == 9
    singles = {c["id"]: c["collectionEligibility"] for c in cards if "collectionEligibility" in c}
    assert len(singles) == 4 and {key for key, value in singles.items() if value["eligible"]} == set(ids)
    assert all(not value["collected"] for value in singles.values())

    desktop.request({"name": "filter.select", "filterId": None})
    check_grouped(overview())
    returned = open_and_close(refs[1])
    save(output / "collection-return.json", returned)
    check_grouped(returned)
    group = next(c for c in returned["overview"]["cards"] if "members" in c)
    assert any(m["ref"] == refs[1] and m["eligibility"]["retainsEligibility"] for m in group["memberEligibility"])

    # Change the current projection through the Runtime while the same filter
    # stays mounted. The three reading records must survive both transitions.
    def change_archive(archived):
        desktop.session.runtime.invoke("application:archive", [unrelated, archived])
        def updated(s):
            overview = s["overview"]
            present = any(c.get("ref") == unrelated for c in overview["cards"])
            return (s["page"] == "overview" and s["selectedFilterId"] is None
                    and not overview["layingOut"] and present == (not archived))
        return desktop.stable(updated)

    at_budget = change_archive(True)
    save(output / "collection-at-budget.json", at_budget)
    visible = at_budget["overview"]["cards"]
    assert cells(visible) == 16 and {c["id"] for c in visible} == initial_ids - {unrelated["threadId"]}
    assert all("members" not in c for c in visible)
    assert all(c["collectionEligibility"]["eligible"] and not c["collectionEligibility"]["collected"]
               for c in visible if c["id"] in ids)
    restored = change_archive(False)
    save(output / "collection-restored.json", restored)
    check_grouped(restored)
