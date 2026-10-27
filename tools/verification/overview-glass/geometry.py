"""Link the real production geometry probe against the prepared Release objects."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

source = Path(__file__).resolve().parent
repo = source.parents[2]
output = repo / ".build/overview-glass"
bundle = Path((output / "bundle.txt").read_text())
build = json.loads((bundle.parent / "performance/build.json").read_text())
original = build["linkCommand"]
prefix = original[:original.index(str(output / "driver/environment.swift"))]
frameworks = prefix[prefix.index("-F") + 1]
prefix = [frameworks if arg == "@executable_path/../Frameworks" else arg for arg in prefix]
objects = [arg for arg in original if arg.endswith(".o")]
executable = output / "geometry-probe"
command = [*prefix, str(source / "geometry.swift"), *objects, "-o", str(executable)]
subprocess.run(command, check=True)
result = subprocess.check_output([str(executable)], env={**os.environ, "MOKUSEI_PERFORMANCE": "off"})
(output / "geometry.json").write_bytes(result)
(output / "geometry-build.json").write_text(json.dumps({"command": command,
    "sourceSHA256": hashlib.sha256((source / "geometry.swift").read_bytes()).hexdigest(),
    "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
    "productionBuild": build}, indent=2))
print(result.decode(), end="")
