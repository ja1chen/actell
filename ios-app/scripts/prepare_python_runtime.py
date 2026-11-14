#!/usr/bin/env python3
"""Fetch locked iOS artifacts and audit them before any application integration."""
import argparse
import base64
import csv
import hashlib
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile

if not __debug__:
    raise RuntimeError('Runtime validation must not run with Python assertion checks disabled')

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / 'ios-app/PythonRuntime/runtime-lock.json'
DEFAULT_CACHE = ROOT / '.build/python-runtime'


def run(*args):
    return subprocess.check_output(args, text=True)


def digest(path):
    checksum = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(block)
    return checksum.hexdigest()


def inspect_binary(path, platform):
    # A filename/CPU alone cannot establish Mach-O platform compatibility.
    assert run('lipo', '-archs', str(path)).strip() == 'arm64', path
    commands = run('otool', '-l', str(path))
    expected = '7' if platform == 'iphonesimulator' else '2'
    platforms = [line.split()[-1] for line in commands.splitlines()
                 if line.strip().startswith('platform ')]
    assert platforms and all(p == expected for p in platforms), (path, platforms)
    minimums = [line.split()[-1] for line in commands.splitlines()
                if line.strip().startswith('minos ')]
    assert minimums and all(tuple(map(int, v.split('.'))) <= (27, 0, 0)
                            for v in minimums), (path, minimums)
    lines = run('otool', '-L', str(path)).splitlines()[2:]  # skip LC_ID_DYLIB
    dependencies = [line.strip().split(' (')[0] for line in lines]
    assert all(d.startswith(('/usr/lib/', '/System/Library/')) or d == '@rpath/Python.framework/Python'
               for d in dependencies), (path, dependencies)
    return dict(binary=path.name, dependencies=dependencies, platform=platform)


def prepare(cache):
    lock = json.loads(LOCK.read_text())
    cache.mkdir(parents=True, exist_ok=True)
    for asset in lock['assets']:
        target = cache / asset['filename']
        if not target.exists():
            partial = target.with_suffix(target.suffix + '.partial')
            with urllib.request.urlopen(asset['url'], timeout=120) as source, partial.open('wb') as dest:
                shutil.copyfileobj(source, dest)
            assert digest(partial) == asset['sha256'], target
            partial.replace(target)
        assert digest(target) == asset['sha256'], target
    support = cache / lock['assets'][0]['filename']
    unpacked = cache / 'support'
    unpacked.mkdir(exist_ok=True)
    with tarfile.open(support) as archive:
        archive.extractall(unpacked, filter='data')
    framework = unpacked / 'Python.xcframework'
    info = plistlib.loads((framework / 'Info.plist').read_bytes())
    assert {x['SupportedPlatform'] for x in info['AvailableLibraries']} == {'ios'}
    reports = []
    for platform in ('iphoneos', 'iphonesimulator'):
        packages = cache / platform / 'site-packages'
        if packages.exists():
            shutil.rmtree(packages)
        packages.mkdir(parents=True)
        for asset in lock['assets']:
            if asset['platform'] != platform:
                continue
            with zipfile.ZipFile(cache / asset['filename']) as wheel:
                names = wheel.namelist()
                assert all(not n.startswith('/') and '..' not in Path(n).parts for n in names)
                assert all((i.external_attr >> 16) & 0o170000 != 0o120000 for i in wheel.infolist())
                metadata = wheel.read(next(n for n in names if n.endswith('.dist-info/METADATA'))).decode()
                assert not any(line.startswith('Requires-Dist:') and ';' not in line
                               for line in metadata.splitlines()), 'Unreviewed dependency'
                tags = wheel.read(next(n for n in names if n.endswith('.dist-info/WHEEL'))).decode()
                assert f'Tag: cp313-cp313-ios_13_0_arm64_{platform}' in tags
                record = next(n for n in names if n.endswith('.dist-info/RECORD'))
                rows = list(csv.reader(io.StringIO(wheel.read(record).decode())))
                assert {r[0] for r in rows} == set(names), 'Incomplete wheel RECORD'
                for name, checksum, size in rows:
                    if not checksum:
                        assert name == record
                        continue
                    algorithm, value = checksum.split('=', 1)
                    data = wheel.read(name)
                    assert algorithm == 'sha256'
                    assert base64.urlsafe_b64encode(hashlib.sha256(data).digest()).decode().rstrip('=') == value
                    assert len(data) == int(size)
                wheel.extractall(packages)
        for binary in packages.rglob('*.so'):
            reports.append(inspect_binary(binary, platform))
        assert not list(packages.rglob('*.dylib')), 'Additional libraries need packaging review'
    (cache / 'audit.json').write_text(json.dumps(reports, indent=2) + '\n')
    # SwiftPM requires a local binary target inside the package. Keep downloaded
    # binaries ignored; prepare before package resolution, never during launch.
    artifacts = ROOT / 'ios-app/CommandKit/Artifacts/Python.xcframework'
    shutil.copytree(framework, artifacts, dirs_exist_ok=True)
    print(f'Validated {len(reports)} wheel binaries; cache: {cache}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=DEFAULT_CACHE)
    prepare(parser.parse_args().cache.resolve())
