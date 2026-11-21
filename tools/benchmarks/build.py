"""Build only independent collectors and controls; never build the target app."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

SOURCE = Path(__file__).resolve().parent


def build(directory):
    directory.mkdir(parents=True, exist_ok=True)
    source_files = sorted([Path(__file__), *SOURCE.glob('native/*'), *SOURCE.glob('calibration/*.swift'),
                           *SOURCE.glob('calibration/*.c')])
    toolchain = subprocess.check_output(['xcodebuild', '-version'], text=True)
    digest = hashlib.sha256(toolchain.encode())
    for path in source_files:
        digest.update(path.name.encode()); digest.update(path.read_bytes())
    identity = digest.hexdigest()
    stamp = directory / 'build.json'
    if stamp.exists() and json.loads(stamp.read_text()).get('sourceHash') == identity:
        return directory
    subprocess.run(['xcrun', 'clang', '-O2', '-c', str(SOURCE/'native/Support.c'), '-o', str(directory/'Support.o')], check=True)
    subprocess.run(['xcrun', 'clang', '-O2', '-I', str(SOURCE/'native'), str(SOURCE/'calibration/CPUClock.c'),
                    str(directory/'Support.o'), '-o', str(directory/'cpu-clock-check')], check=True)
    cpu_clock = json.loads(subprocess.check_output([str(directory/'cpu-clock-check')], text=True, timeout=15))
    (directory/'cpu-clock-check.json').write_text(json.dumps(cpu_clock, indent=2) + '\n')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-parse-as-library', '-import-objc-header',
                    str(SOURCE/'native/Support.h'), str(SOURCE/'native/Collector.swift'), str(directory/'Support.o'),
                    '-o', str(directory/'collector')], check=True)
    app = directory/'Control.app'
    (app/'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.chief.external-benchmark.control',
        'CFBundleName':'Benchmark Control','CFBundleExecutable':'Control','CFBundlePackageType':'APPL',
        'NSHighResolutionCapable':True,'LSMinimumSystemVersion':'26.0'}))
    subprocess.run(['xcrun','swiftc','-swift-version','5','-O','-parse-as-library',str(SOURCE/'calibration/Control.swift'),
                    '-o',str(app/'Contents/MacOS/Control')],check=True)
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
    stamp.write_text(json.dumps({'sourceHash':identity,'toolchain':toolchain,'cpuClockCheck':cpu_clock,
                                'nativeHitchTargetBuilt':False},indent=2))
    return directory
