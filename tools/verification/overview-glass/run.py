"""Prepare a disposable production-source variant; never patch the product checkout."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[2]
LEGACY = SOURCE.parent / "overview-input"
OUTPUT = REPO / ".build/overview-glass"


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f"Research patch drift: expected one occurrence of {old!r}")
    return text.replace(old, new, 1)


def prepare(reuse=False):
    OUTPUT.mkdir(parents=True, exist_ok=reuse)
    package = OUTPUT / "package"
    original = REPO / "app/macos"
    audited = [original / "Sources/Host/Overview/NativeOverviewCanvas.swift"]
    audited += list((original / "Sources/Shared/PluginUI/Cards").glob("*.swift"))
    audited += list((original / "Sources/Plugins/Applications/Report").glob("*.swift"))
    sites = {str(p.relative_to(original)): len(re.findall(r"\.glassEffect\s*\(", p.read_text())) for p in audited}
    sites = {name: count for name, count in sites.items() if count}
    if sites != {"Sources/Host/Overview/NativeOverviewCanvas.swift": 1,
                 "Sources/Shared/PluginUI/Cards/ThreadCardBrand.swift": 1,
                 "Sources/Shared/PluginUI/Cards/ThreadCardSections.swift": 1}:
        raise RuntimeError("Glass API sites changed; review the complete-card cancellation boundary")
    if any(re.search(r"NSGlassEffect|\.buttonStyle\s*\(\s*\.glass", p.read_text()) for p in audited):
        raise RuntimeError("New card glass API requires a research boundary review")
    shutil.copytree(original, package, dirs_exist_ok=reuse, ignore=shutil.ignore_patterns(".build", ".swiftpm"))
    patches = []
    paths = ["Sources/Shared/PluginUI/Cards/ThreadCardBrand.swift",
             "Sources/Shared/PluginUI/Cards/ThreadCardSections.swift"]
    for relative in paths:
        path = package / relative
        before = path.read_text()
        after = before
        if relative.endswith("ThreadCardBrand.swift"):
            after += """
// Research-only injection into the copied package, never shipped.
private struct ResearchCardGlassDisabledKey: EnvironmentKey { static let defaultValue = false }
public extension EnvironmentValues {
    var researchCardGlassDisabled: Bool {
        get { self[ResearchCardGlassDisabledKey.self] }
        set { self[ResearchCardGlassDisabledKey.self] = newValue }
    }
}
"""
            after = replace_once(after, "private struct ThreadCardProviderStatusBody: View {",
                "private struct ThreadCardProviderStatusBody: View {\n    @Environment(\\.researchCardGlassDisabled) private var researchCardGlassDisabled")
            after = replace_once(after, ".glassEffect(.regular.interactive(action != nil), in: Circle())",
                ".background(researchCardGlassDisabled ? NativePalette.overview.surface.swiftUI : .clear, in: Circle())\n        .glassEffect(researchCardGlassDisabled ? .identity : .regular.interactive(action != nil), in: Circle())")
        else:
            after = replace_once(after, "private struct CardPlanRow: View {",
                "private struct CardPlanRow: View {\n    @Environment(\\.researchCardGlassDisabled) private var researchCardGlassDisabled")
            after = replace_once(after, ".glassEffect(.regular.tint(palette.accent.swiftUI.opacity(0.08)), in: .rect(cornerRadius: CardPlanGeometry.cornerRadius))",
                ".background(researchCardGlassDisabled ? palette.surfaceStrong.swiftUI : .clear, in: .rect(cornerRadius: CardPlanGeometry.cornerRadius))\n                    .glassEffect(researchCardGlassDisabled ? .identity : .regular.tint(palette.accent.swiftUI.opacity(0.08)), in: .rect(cornerRadius: CardPlanGeometry.cornerRadius))")
        path.write_text(after)
        patches.extend(difflib.unified_diff(before.splitlines(True), after.splitlines(True), fromfile=relative, tofile=relative))
    (OUTPUT / "research.patch").write_text("".join(patches))
    generated = OUTPUT / "driver"
    generated.mkdir(exist_ok=reuse)
    for path in LEGACY.iterdir():
        if path.is_file() and path.suffix in {".swift", ".py"}:
            shutil.copy2(path, generated / path.name)
    support = (generated / "performance_support.py").read_text()
    # Apple's ReplayKit daemon is not a Mokusei GUI verification replay. The
    # inherited broad substring rule otherwise prevents every launch on hosts
    # where that system daemon is present, even at zero CPU.
    support = replace_once(support, 'name = process["name"].strip().lower()',
        'name = process["name"].strip().lower()\n    if name == "replayd":\n        return False')
    support = replace_once(support, '{"swift-frontend", "clang", "compile", "link"}',
        '{"swift-frontend", "swift-package", "swift-build", "swift-test", "swiftc", "clang", "compile", "link", "ld"}')
    (generated / "performance_support.py").write_text(support)
    launcher = (generated / "performance_run.py").read_text()
    launcher = replace_once(launcher, 'idle >= 30 and not busy', 'idle >= 120 and not busy')
    (generated / "performance_run.py").write_text(launcher)
    fixture = (generated / "glass-fixture.swift").read_text()
    fixture = replace_once(fixture, "var glassWorld = true", "var glassWorld = true\n    var cardGlassCondition = \"all-on\"\n    var refreshTick = 0\n    @ObservationIgnored var observedRefreshTick = 0\n    let cardCount = Bundle.main.object(forInfoDictionaryKey: \"ResearchCardCount\") as? Int ?? 5")
    begin = fixture.index("    var items: [NativeOverviewItem] {")
    end = fixture.index("    let report:", begin)
    fixture = fixture[:begin] + """    var items: [NativeOverviewItem] {
        (0..<cardCount).map { index in
            let kind = ["codex", "claude", "pi", "opencode", "report"][index % 5]
            return .init(id: "\\(kind)-\\(index)", columns: kind == "codex" ? plan.size.cols : 1,
                rows: kind == "codex" ? plan.size.rows : 1,
                presentationID: index == 0 ? String(refreshTick) : "", completed: kind == "codex" || kind == "pi")
        }
    }
""" + fixture[end:]
    fixture = replace_once(fixture, "card(item.id)", "card(item.id)\n                    .environment(\\.researchCardGlassDisabled, fixture.cardGlassCondition == \"all-off\")\n                    .onChange(of: item.presentationID) { _, value in\n                        if item.id == fixture.items.first?.id { fixture.observedRefreshTick = Int(value) ?? 0 }\n                    }")
    fixture = replace_once(fixture, "switch id {", "switch id.split(separator: \"-\").first.map(String.init) ?? id {")
    # Only one stable card changes text. The actual shared card renders the change.
    fixture = replace_once(fixture, 'harness("Codex · Canvas material",', 'harness("Codex · Canvas material · \\(id == fixture.items.first?.id ? fixture.refreshTick : 0)",')
    for harness in ["Codex", "Claude", "Pi", "OpenCode"]:
        marker = f'logo: AnyView({harness}HarnessPlugin().logo(size: 12)))'
        fixture = replace_once(fixture, marker,
            marker + f'\n                .environment(\\.threadCardCloudPalette, {harness}Logo.threadCardCloudPalette)')
    (generated / "glass-fixture.swift").write_text(fixture)
    helpers = (LEGACY / "performance.swift").read_text().split("@MainActor private func runPerformance() async throws {")[0]
    helpers = replace_once(helpers, "dynamic: Bool, seconds: Int", "dynamic: Bool, zoom: Bool = false, refresh: Bool = false, seconds: Int")
    helpers = replace_once(helpers, "let frequency = dynamic ? 60 : 20", "let frequency = dynamic ? 60 : 20\n    let initialTick = fixture.refreshTick\n    var catchUpSteps = 0\n    var actionsApplied = 0\n    var refreshActionsApplied = 0")
    helpers = replace_once(helpers, "        if dynamic {\n", "        if wake >= deadline + UInt64(1e9 / Double(frequency)) { catchUpSteps += 1 }\n        if refresh && !step.isMultiple(of: 2) { fixture.refreshTick = initialTick + (step + 1) / 2; refreshActionsApplied += 1 }\n        if dynamic {\n            actionsApplied += 1\n")
    helpers = replace_once(helpers, "                scale: origin.scale * (1 + 0.035 * sin(phase)),", "                scale: zoom ? origin.scale * (1 + 0.035 * sin(phase)) : origin.scale,")
    helpers = replace_once(helpers, "    let end = NativePerformance.now()", "    let end = NativePerformance.now()\n    if refresh { try await Task.sleep(for: .milliseconds(30)) }")
    helpers = replace_once(helpers, '"deliveredActions": dynamic ? steps : 0,', '"deliveredActions": actionsApplied, "catchUpSteps": catchUpSteps, "refreshActions": refreshActionsApplied, "observedRefreshTick": fixture.observedRefreshTick,')
    helpers = replace_once(helpers, '    if total == 0 || 100 * Double(total - UInt64(ticks[2])) / Double(total) > 40 {\n        invalid.insert("host-busy-over-40-percent")\n    }',
        '    let hostBusyPercent = total == 0 ? 0 : 100 * Double(total - UInt64(ticks[2])) / Double(total)')
    helpers = replace_once(helpers, '    if resources.contains(where: { ($0["thermalState"] as! Int) >= 2 }) { invalid.insert("serious-thermal-pressure") }',
        '    let seriousThermalPressure = resources.contains(where: { ($0["thermalState"] as! Int) >= 2 })')
    helpers = replace_once(helpers, '    if (wakeLatenessMs.max() ?? 0) > 250 || Double(late) / Double(steps) > 0.05 { invalid.insert("disrupted-scheduling") }',
        '    let schedulingOverload = (wakeLatenessMs.max() ?? 0) > 250 || Double(late) / Double(steps) > 0.05')
    helpers = replace_once(helpers, '"wakeLatenessMs": wakeLatenessMs, "resources": resources,',
        '"wakeLatenessMs": wakeLatenessMs, "resources": resources, "hostBusyPercent": hostBusyPercent,\n        "seriousThermalPressure": seriousThermalPressure, "schedulingOverload": schedulingOverload,')
    helpers = replace_once(helpers, 'pointer == currentPointer && busy <= 40 && ProcessInfo.processInfo.thermalState.rawValue < 2',
        'pointer == currentPointer')
    (generated / "performance.swift").write_text(helpers + (SOURCE / "trial.swift").read_text())
    driver = (generated / "run.py").read_text()
    driver = replace_once(driver, "repo = source.parents[2]", f"repo = Path({str(REPO)!r})")
    driver = replace_once(driver, 'package = repo / "app/macos"', f"package = Path({str(package)!r})")
    (generated / "run.py").write_text(driver)
    inputs = list(SOURCE.glob("*")) + list(LEGACY.glob("*"))
    inputs += [p for p in original.rglob("*") if p.is_file() and ".build" not in p.parts]
    manifest = {str(p.relative_to(REPO)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs if p.is_file()}
    (OUTPUT / "inputs.json").write_text(json.dumps(manifest, indent=2))
    command = [sys.executable, str(generated / "run.py"), "--glass-performance", str(OUTPUT / "not-launched"), "--build-only"]
    subprocess.run(command, check=True)
    bundle = Path((REPO / ".build/overview-input/app-path.txt").read_text())
    shutil.copytree(generated, bundle.parent / "measurement-sources", ignore=shutil.ignore_patterns("__pycache__"))
    (OUTPUT / "bundle.txt").write_text(str(bundle))
    print(f"Prepared {bundle}; no window launched")


def measure(count, stage, destination):
    import plistlib
    import uuid
    # Each measured count owns a new bundle and run directory; keep the prepared binary immutable.
    sys.path.insert(0, str(OUTPUT / "driver"))
    from performance_run import run_performance
    source_bundle = Path((OUTPUT / "bundle.txt").read_text())
    prepared = json.loads((source_bundle.parent / "performance/build.json").read_text())
    original_executable = source_bundle / "Contents/MacOS/OverviewInputReplay"
    if hashlib.sha256(original_executable.read_bytes()).hexdigest() != prepared["executableSHA256"]:
        raise RuntimeError("Prepared executable changed before trial cloning")
    import tempfile
    private = Path(tempfile.mkdtemp(prefix="mokusei-overview-", dir="/private/tmp"))
    bundle = private / source_bundle.name
    shutil.copytree(source_bundle, bundle, symlinks=True)
    plist = bundle / "Contents/Info.plist"
    info = plistlib.loads(plist.read_bytes())
    raw = private / "performance"
    raw.mkdir()
    info.update(ResearchCardCount=count, ResearchStage=stage, MokuseiGlassPerformanceDirectory=str(raw),
                MokuseiReplayResult=str(private / "result.txt"),
                CFBundleIdentifier="com.mokusei.overview-swiftui-replay." + uuid.uuid4().hex)
    plist.write_bytes(plistlib.dumps(info))
    build = prepared.copy()
    build["preparedBundle"] = build["bundle"]
    build["bundle"] = str(bundle)
    # performance_run verifies the signed executable and generated source hashes.
    subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
    # Info.plist changes require re-signing, which changes the Mach-O signature
    # bytes. Preserve both identities rather than comparing the new signature to
    # the prepared binary's hash, or weakening the actual launcher's hash check.
    build["preparedExecutableSHA256"] = prepared["executableSHA256"]
    build["executableSHA256"] = hashlib.sha256((bundle / "Contents/MacOS/OverviewInputReplay").read_bytes()).hexdigest()
    build["researchLauncherSHA256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    (raw / "research-launcher.py").write_bytes(Path(__file__).read_bytes())
    shutil.copy2(OUTPUT / "research.patch", raw / "research.patch")
    shutil.copy2(OUTPUT / "inputs.json", raw / "inputs.json")
    shutil.copytree(source_bundle.parent / "measurement-sources", raw / "measurement-sources")
    (raw / "build.json").write_text(json.dumps(build, indent=2))
    run_performance(bundle, destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["build", "rebuild", "measure"])
    parser.add_argument("--count", type=int, choices=[1, 5, 12, 30], default=5)
    parser.add_argument("--stage", choices=["baseline", "extended"], default="baseline")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.command in ["build", "rebuild"]:
        prepare(reuse=args.command == "rebuild")
    else:
        if not args.output or args.output.exists():
            parser.error("measure requires a new --output directory")
        measure(args.count, args.stage, args.output.resolve())
