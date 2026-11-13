"""Bake checked-in Overview assets from the production field, palette and shader."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
DESIGN = ROOT / 'app/macos/Sources/Shared/PluginUI/Design'
SHADER = ROOT / 'app/macos/Sources/Shared/PluginUI/Shaders/CloudLoading.metal'
OUTPUT = ROOT / 'app/macos/Sources/Shared/PluginUI/Resources/OverviewCloud'
INPUTS = [Path(__file__).with_name('Bake.swift'), Path(__file__), SHADER,
          DESIGN / 'NativeCloudField.swift', DESIGN / 'NativeCloudLoopStyle.swift']


def main():
    with tempfile.TemporaryDirectory(prefix='mokusei-cloud-bake-') as directory:
        work = Path(directory)
        library = work / 'Cloud.metallib'
        executable = work / 'bake'
        subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-std=metal3.0',
                        '-mmacosx-version-min=26.0', str(SHADER), '-o', str(library)], check=True)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-O', '-parse-as-library',
                        str(INPUTS[0]), str(INPUTS[3]), str(INPUTS[4]), '-o', str(executable)], check=True)
        generated = work / 'assets'
        subprocess.run([str(executable), str(library), str(generated)], check=True)
        OUTPUT.mkdir(parents=True, exist_ok=True)
        for path in generated.iterdir():
            (OUTPUT / path.name).write_bytes(path.read_bytes())
        digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        manifest = {'version': 1, 'inputSHA256': {str(p.relative_to(ROOT)): digest(p) for p in INPUTS},
                    'assetSHA256': {p.name: digest(p) for p in sorted(generated.iterdir())}}
        (OUTPUT / 'OverviewCloudSources.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    main()
