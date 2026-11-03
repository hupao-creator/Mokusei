"""Build and compare windowless production Note CPU/layout probes; never run tests."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[2]
PACKAGE = REPO / 'app/macos'
SCRATCH = REPO / '.build/note-native'
OUTPUT = REPO / '.build/moku-note-performance'


def fingerprint():
    digest = hashlib.sha256()
    paths = sorted(path for path in (PACKAGE / 'Sources').rglob('*') if path.is_file() and path.suffix != '.md')
    for path in [*paths, PACKAGE / 'Package.swift', PACKAGE / 'Package.resolved']:
        digest.update(str(path.relative_to(REPO)).encode() + b'\0' + path.read_bytes())
    return digest.hexdigest()


def build(label, skip_build):
    destination = OUTPUT / label
    destination.mkdir(parents=True, exist_ok=False)
    before = fingerprint()
    command = ['xcrun', 'swift', 'build', '--package-path', str(PACKAGE),
               '--scratch-path', str(SCRATCH), '--product', 'Mokusei', '-c', 'release', '--disable-sandbox',
               '--cache-path', '/tmp/mokusei-swiftpm-cache',
               '-Xswiftc', '-enable-testing', '-Xswiftc', '-warnings-as-errors']
    if not skip_build:
        subprocess.run(command, cwd=REPO, check=True)
    binary = Path(subprocess.check_output([*command, '--show-bin-path'], cwd=REPO, text=True).strip())
    objects = [line.strip('"') for line in (binary / 'Mokusei.product/Objects.LinkFileList').read_text().splitlines()
               if '/Mokusei.build/' not in line]
    probe = (SOURCE / 'main.swift').read_bytes()
    (destination / 'main.swift').write_bytes(probe)
    args = ['xcrun', 'swiftc', '-O', '-g', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
            '-target', f'{platform.machine()}-apple-macosx26.0', '-I', str(binary / 'Modules'), '-F', str(binary),
            '-framework', 'LiveKitWebRTC', '-Xlinker', '-rpath', '-Xlinker', str(binary),
            '-module-cache-path', str(OUTPUT / 'ModuleCache')]
    for relative in ['swift-cmark/src/include', 'swift-cmark/extensions/include',
                     'swift-markdown/Sources/CAtomic/include', 'swift-system/Sources/CSystem/include']:
        include = SCRATCH / 'checkouts' / relative
        args += ['-I', str(include), '-Xcc', '-fmodule-map-file=' + str(include / 'module.modulemap')]
    subprocess.run([*args, str(destination / 'main.swift'), *objects, '-o', str(destination / 'probe')], cwd=REPO, check=True)
    if fingerprint() != before:
        raise RuntimeError('Production sources changed while building')
    metadata = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip(),
                'diff': subprocess.check_output(['git', 'diff', 'HEAD', '--', 'app/macos'], cwd=REPO, text=True),
                'sourceSHA256': before, 'probeSHA256': hashlib.sha256(probe).hexdigest(),
                'binarySHA256': hashlib.sha256((destination / 'probe').read_bytes()).hexdigest(),
                'buildCommand': command, 'skipBuild': skip_build,
                'toolchain': subprocess.check_output(['xcrun', 'swift', '--version'], text=True)}
    (destination / 'build.json').write_text(json.dumps(metadata, indent=2))


def measure(labels, repetitions, series):
    metadata = {label: json.loads((OUTPUT / label / 'build.json').read_text()) for label in labels}
    if len({item['probeSHA256'] for item in metadata.values()}) != 1:
        raise RuntimeError('Workload sources differ')
    for label, item in metadata.items():
        if hashlib.sha256((OUTPUT / label / 'probe').read_bytes()).hexdigest() != item['binarySHA256']:
            raise RuntimeError('Preserved binary changed: ' + label)
    # All binaries must be built first. Serial AB/BA avoids compiler interference.
    for repetition in range(repetitions):
        for label in labels if repetition % 2 == 0 else labels[::-1]:
            destination = OUTPUT / label / f'{series}-{repetition + 1}.json'
            if destination.exists():
                raise RuntimeError('Refusing to overwrite evidence: ' + str(destination))
            with destination.with_suffix('.log').open('w') as log:
                subprocess.run([str(OUTPUT / label / 'probe'), str(destination)], cwd=REPO,
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)
            records = json.loads(destination.read_text())['records']
            layouts = [record for record in records if record['scenario'] == 'unchanged-execution-layout']
            if len(layouts) != 3 or any(record['hosts'] != record['links'] or not record['textViews'] for record in layouts):
                raise RuntimeError('Measured controls did not mount: ' + str(destination))
            observation = next(record for record in records if record['scenario'] == 'interaction-observations')
            if observation['windowVisible'] or observation['applicationActive']:
                raise RuntimeError('Probe became visible/active: ' + str(destination))
            for record in records:
                value = statistics.median(record['elapsedMs']) if 'elapsedMs' in record else record.get('cpuMs')
                if value is not None:
                    print(label, repetition + 1, record['scenario'], record.get('links', record.get('iteration')),
                          round(value, 3), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    compiler = commands.add_parser('build')
    compiler.add_argument('--label', required=True)
    compiler.add_argument('--skip-build', action='store_true', help='Link just-built current Release objects')
    runner = commands.add_parser('measure')
    runner.add_argument('--labels', default='baseline,candidate')
    runner.add_argument('--repetitions', type=int, default=4)
    runner.add_argument('--series', default='run', help='Unique prefix for retained measurement files')
    args = parser.parse_args()
    labels = [args.label] if args.command == 'build' else args.labels.split(',')
    if not all(label and all(char.isalnum() or char in '-_' for char in label) for label in labels):
        parser.error('Labels must contain only letters, digits, dashes or underscores')
    if args.command == 'build':
        build(args.label, args.skip_build)
    else:
        if args.repetitions < 1:
            parser.error('Repetitions must be positive')
        if not args.series or not all(char.isalnum() or char in '-_' for char in args.series):
            parser.error('Series must contain only letters, digits, dashes or underscores')
        measure(labels, args.repetitions, args.series)


if __name__ == '__main__':
    main()
