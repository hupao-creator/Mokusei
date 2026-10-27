"""Exercise the production reporter against real Go pass/fail/skip/build/panic runs."""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--go", default="go")
args = parser.parse_args()
go = str(Path(args.go).resolve()) if "/" in args.go else args.go
reporter = Path(__file__).with_name("go-tests.py").resolve()
cases = {
    "mixed": ('func TestPass(t *testing.T) {}\nfunc TestSkip(t *testing.T) { t.Skip("fixture") }\nfunc TestTree(t *testing.T) { t.Run("pass", func(t *testing.T) {}); t.Run("skip", func(t *testing.T) { t.Skip("fixture") }) }', 0, 0),
    "failed-subtest": ('func TestTree(t *testing.T) { t.Run("fail", func(t *testing.T) { t.Error("fixture") }) }', 1, 1),
    "all-skipped": ('func TestSkip(t *testing.T) { t.Skip("fixture") }', 0, 1),
    "panic": ('func TestPanic(t *testing.T) { panic("fixture") }', 1, 1),
    "package-failure": ('func TestMain(m *testing.M) { panic("fixture before tests") }\nfunc TestUnused(t *testing.T) {}', 1, 1),
    "build-failure": ('func TestBuild(t *testing.T) { missingSymbol() }', 1, 1),
    "no-tests": ('', 0, 1),
}

with tempfile.TemporaryDirectory(prefix="mokusei-ci-reporting-") as temp:
    root = Path(temp)
    reports = {}
    for name, (source, run_code, report_code) in cases.items():
        package = root / name
        package.mkdir()
        (package / "go.mod").write_text("module example.com/ci-fixture\n\ngo 1.24.0\n")
        if source:
            (package / "fixture_test.go").write_text('package fixture\nimport "testing"\n' + source + "\n")
        else:
            (package / "fixture.go").write_text("package fixture\n")
        prefix = package / "capture"
        result = subprocess.run([sys.executable, str(reporter), "run", str(prefix), "--", go,
                                 "test", "-json", "-count=1", "./..."], cwd=package, capture_output=True, text=True)
        assert result.returncode == run_code, (name, result.stdout, result.stderr)
        destination = package / "report.json"
        result = subprocess.run([sys.executable, str(reporter), "report", "--output", str(destination), str(prefix)],
                                capture_output=True, text=True)
        assert result.returncode == report_code, (name, result.stdout, result.stderr)
        reports[name] = json.loads(destination.read_text())[0]
    mixed = reports["mixed"]
    assert (mixed["tests"], mixed["suites"], mixed["failures"], mixed["skipped"]) == (5, 1, 0, 2), mixed
    failed = reports["failed-subtest"]
    assert failed["tests"] == 2 and failed["failures"] == 2 and len(failed["failed_packages"]) == 1, failed
    assert reports["all-skipped"]["skipped"] == 1
    assert reports["no-tests"]["tests"] == 0 and len(reports["no-tests"]["no_test_packages"]) == 1
    for name in ("panic", "package-failure", "build-failure"):
        assert reports[name]["failed_packages"] or reports[name]["failed_builds"], reports[name]

    # Damage real output rather than duplicating the parser's event generation.
    original = root / "mixed" / "capture"
    for name in ("truncated", "malformed", "missing"):
        prefix = root / name
        if name != "missing":
            shutil.copyfile(original.with_suffix(".status.json"), prefix.with_suffix(".status.json"))
            lines = original.with_suffix(".jsonl").read_text().splitlines()
            text = "\n".join(lines[:-1]) + "\n" if name == "truncated" else "\n".join(lines) + "\nnot json\n"
            prefix.with_suffix(".jsonl").write_text(text)
        destination = root / (name + "-report.json")
        result = subprocess.run([sys.executable, str(reporter), "report", "--output", str(destination), str(prefix)],
                                capture_output=True, text=True)
        assert result.returncode == 1, (name, result.stdout, result.stderr)
        assert json.loads(destination.read_text())[0]["errors"]
print("PASS Go reporter: real pass/subtests/skip/failure/panic/package/build/no-test runs; truncated, malformed and missing captures rejected.")
