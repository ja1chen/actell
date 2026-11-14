#!/usr/bin/env python3
"""Package one audited ARM64 runtime into an app, then sign after conversion."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

from prepare_python_runtime import DEFAULT_CACHE, ROOT, inspect_binary


def package(cache, app, platform, identity):
    assert (cache / 'audit.json').is_file(), 'Run prepare_python_runtime.py first'
    framework = cache / 'support/Python.xcframework'
    slice_name = 'ios-arm64' if platform == 'iphoneos' else 'ios-arm64_x86_64-simulator'
    selected = framework / slice_name
    lib = app / 'python/lib'
    lib.mkdir(parents=True, exist_ok=True)
    shutil.copytree(framework / 'lib', lib, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('libpython*.dylib', '__pycache__'))
    shutil.copytree(selected / 'lib-arm64', lib, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('libpython*.dylib', '__pycache__'))
    packages = app / 'python/site-packages'
    shutil.copytree(cache / platform / 'site-packages', packages, dirs_exist_ok=True)
    # NumPy ships these link-time SDK archives for downstream extension builds.
    # All executable extensions are already linked; neither archive is dlopened.
    for relative in ('numpy/_core/lib/libnpymath.a', 'numpy/random/lib/libnpyrandom.a'):
        (packages / relative).unlink(missing_ok=True)
    app_resources = app / 'python/app'
    if app_resources.exists():
        shutil.rmtree(app_resources)
    shutil.copytree(ROOT / 'ios-app/PythonRuntime/Resources', app_resources,
                    ignore=shutil.ignore_patterns('__pycache__'))
    frameworks = app / 'Frameworks'
    frameworks.mkdir(exist_ok=True)
    pyframework = frameworks / 'Python.framework'
    shutil.copytree(selected / 'Python.framework', pyframework, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('Headers', 'Modules', '_CodeSignature'))
    binary = pyframework / 'Python'
    arches = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
    if len(arches) > 1:
        subprocess.run(['lipo', str(binary), '-thin', 'arm64', '-output', str(binary) + '.arm64'], check=True)
        Path(str(binary) + '.arm64').replace(binary)
    inspect_binary(binary, platform)
    for base in (lib / 'python3.13/lib-dynload', packages):
        for source in sorted(base.rglob('*.so')):
            inspect_binary(source, platform)
            module = '.'.join((*source.relative_to(base).parts[:-1], source.name.split('.')[0]))
            folder = frameworks / (module + '.framework')
            folder.mkdir(exist_ok=True)
            executable = folder / module
            shutil.move(source, executable)
            subprocess.run(['install_name_tool', '-id', f'@rpath/{folder.name}/{module}', str(executable)], check=True)
            marker = source.with_suffix('.fwork')
            marker.write_text(str(executable.relative_to(app)) + '\n')
            (folder / (module + '.origin')).write_text(str(marker.relative_to(app)) + '\n')
            privacy = source.parent / (source.name.split('.')[0] + '.xcprivacy')
            if privacy.exists():
                shutil.copy2(privacy, folder / 'PrivacyInfo.xcprivacy')
            metadata = dict(CFBundleExecutable=module, CFBundleIdentifier='org.actell.python.' + module.replace('_', '-'),
                            CFBundleName=module, CFBundlePackageType='FMWK', CFBundleVersion='1',
                            CFBundleShortVersionString='1.0', MinimumOSVersion='27.0',
                            CFBundleSupportedPlatforms=['iPhoneOS' if platform == 'iphoneos' else 'iPhoneSimulator'])
            (folder / 'Info.plist').write_bytes(plistlib.dumps(metadata))
    # Keep licenses and runtime modules. Do not prune libraries based on filenames.
    # Other app targets can legitimately contain Xcode's debug dylib and their
    # own native resources. This validator owns only the Python resource tree.
    for candidate in (app / 'python').rglob('*'):
        assert not candidate.is_symlink(), ('Unexpected bundle symlink', candidate)
        if candidate.is_file() and candidate.suffix in ('.so', '.a', '.dylib'):
            raise ValueError(f'Unpackaged native file: {candidate}')
    if identity:
        for folder in sorted(frameworks.glob('*.framework')):
            subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', str(folder)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=DEFAULT_CACHE)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--platform', choices=['iphoneos', 'iphonesimulator'], required=True)
    parser.add_argument('--identity', default='')
    args = parser.parse_args()
    package(args.cache.resolve(), args.app.resolve(), args.platform, args.identity)
