#!/usr/bin/env python3
"""Check Swift syntax and project configuration; runtime safety lives in XCTest."""
import json
import os
from pathlib import Path
import plistlib
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[1]
files = sorted(p for folder in ('PhoneAgent', 'PhoneAgentTests', 'PhoneAgentUITests')
               for p in (ROOT / folder).rglob('*.swift'))
env = os.environ.copy()
env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
# Use the compiler that understands the project's Swift language version.
# Parsing alone does not resolve imports or perform type checking.
subprocess.run(['xcrun', 'swiftc', '-frontend', '-parse', *map(str, files)],
               env=env, check=True)
project = yaml.safe_load((ROOT / 'project.yml').read_text())
assert project['packages']['SwiftAgentKit']['path'] == 'Vendor/SwiftAgentKit'
assert project['packages']['ProviderKit']['path'] == 'ProviderKit'
assert '../coredevice/swift/Sources/CoreDeviceBackend' in project['targets']['PhoneAgent']['sources']
upstream = json.loads((ROOT / 'Vendor/SwiftAgentKit/UPSTREAM.json').read_text())
assert upstream['revision'] == '84ddf324fd2a223834323537eb3f8746d669753b'
assert 'PhoneAgentTests' in project['targets']
plistlib.loads((ROOT / 'PhoneAgent/PrivacyInfo.xcprivacy').read_bytes())
info = plistlib.loads((ROOT / 'PhoneAgent/Info.plist').read_bytes())
assert set(info['UIBackgroundModes']) == {'screen-capture', 'processing', 'audio', 'location'}
assert info['BGTaskSchedulerPermittedIdentifiers'] == [
    '$(PRODUCT_BUNDLE_IDENTIFIER).backgroundRun.*',
    '$(PRODUCT_BUNDLE_IDENTIFIER).pairing',
]
print(f'PASS: {len(files)} Swift files parsed; project paths, plist and source pin checked')
print('Run test_core.sh and an iPhoneOS build for runtime regression and type checking.')
