"""Link a visual-only fixture to the current Release production Dock. Never builds/runs tests."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess

repo = Path(__file__).resolve().parents[2]
package = repo / 'app/macos'
production = package / '.build/arm64-apple-macosx/release'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--label', default='candidate')
options = parser.parse_args()
if not options.label or any(not (char.isalnum() or char in '-_') for char in options.label):
    parser.error('Use letters, digits, dashes or underscores for the label')
application = repo / '.build/note-dismiss' / options.label / 'MokuNoteTransitionPreview.app'
executable = application / 'Contents/MacOS/MokuNoteTransitionPreview'
executable.parent.mkdir(parents=True, exist_ok=True)
resources = application / 'Contents/Resources'
resources.mkdir(exist_ok=True)
for bundle in production.glob('*.bundle'):
    shutil.copytree(bundle, resources / bundle.name, dirs_exist_ok=True)
frameworks = application / 'Contents/Frameworks'
frameworks.mkdir(exist_ok=True)
if (frameworks / 'LiveKitWebRTC.framework').exists():
    shutil.rmtree(frameworks / 'LiveKitWebRTC.framework')
shutil.copytree(production / 'LiveKitWebRTC.framework', frameworks / 'LiveKitWebRTC.framework',
                dirs_exist_ok=True, symlinks=True)
objects = [line.strip().strip('"') for line in (production / 'Mokusei.product/Objects.LinkFileList').read_text().splitlines()
           if '/Mokusei.build/' not in line]
args = ['xcrun', 'swiftc', '-O', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
        '-target', 'arm64-apple-macosx26.0', '-I', str(production / 'Modules'), '-F', str(frameworks),
        '-framework', 'LiveKitWebRTC', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
        '-module-cache-path', str(application.parent / 'ModuleCache')]
for relative in ['swift-cmark/src/include', 'swift-cmark/extensions/include',
                 'swift-markdown/Sources/CAtomic/include', 'swift-system/Sources/CSystem/include']:
    include = package / '.build/checkouts' / relative
    args += ['-I', str(include), '-Xcc', '-fmodule-map-file=' + str(include / 'module.modulemap')]
result = subprocess.run([*args, str(Path(__file__).with_name('main.swift')), *objects, '-o', str(executable)])
if result.returncode:
    raise SystemExit(result.returncode)
with (application / 'Contents/Info.plist').open('wb') as output:
    plistlib.dump({'CFBundleIdentifier': 'com.mokusei.note-transition-preview',
                  'CFBundleName': executable.name, 'CFBundleExecutable': executable.name,
                  'CFBundlePackageType': 'APPL', 'NSHighResolutionCapable': True,
                  'LSMinimumSystemVersion': '26.0'}, output)
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(application)], check=True)
metadata = {
    'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
    'sourceSHA256': hashlib.sha256(b''.join(path.read_bytes() for path in sorted((package / 'Sources').rglob('*.swift')))).hexdigest(),
    'previewSHA256': hashlib.sha256(Path(__file__).with_name('main.swift').read_bytes()).hexdigest(),
    'binarySHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
    'productionDiff': subprocess.check_output(['git', 'diff', 'HEAD', '--', 'app/macos/Sources'], cwd=repo, text=True),
}
(application.parent / 'build.json').write_text(json.dumps(metadata, indent=2))
print(application)
