#!/usr/bin/env python3
"""Check Swift syntax and project configuration; runtime safety lives in XCTest."""
import re
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
assert project['packages']['AgentKit']['path'] == 'AgentKit'
assert project['packages']['ProviderKit']['path'] == 'ProviderKit'
assert '../coredevice/swift/Sources/CoreDeviceBackend' in project['targets']['PhoneAgent']['sources']
# The retired engine must not return through imports, products or local paths.
retired = "Swift" + "AgentKit"
assert not (ROOT / 'Vendor' / retired).exists(), 'Retired dependency directory exists'
scan = files + [ROOT / 'project.yml', ROOT / 'PhoneAgent.xcodeproj/project.pbxproj']
scan += [p for package in ('AgentKit', 'ProviderKit') for p in (ROOT / package).rglob('*.swift') if '.build' not in p.parts]
for path in scan:
    assert retired not in path.read_text(), f'Retired dependency reference: {path.relative_to(ROOT)}'
for package in ('AgentKit', 'ProviderKit'):
    manifest = (ROOT / package / 'Package.swift').read_text()
    assert '.macro(' not in manifest and 'SwiftSyntax' not in manifest, f'Unexpected macro dependency in {package}'
assert 'ProviderCore' in (ROOT / 'AgentKit/Package.swift').read_text()
for path in (ROOT / 'AgentKit/Sources').rglob('*.swift'):
    assert not re.search(r'^import (?:SwiftUI|UIKit|OpenAI|OpenAIAdapter|PhoneAgent)\b', path.read_text(), re.MULTILINE), f'AgentKit imports a host or adapter module: {path.relative_to(ROOT)}'
assert 'PhoneAgentTests' in project['targets']
plistlib.loads((ROOT / 'PhoneAgent/PrivacyInfo.xcprivacy').read_bytes())
info = plistlib.loads((ROOT / 'PhoneAgent/Info.plist').read_bytes())
assert set(info['UIBackgroundModes']) == {'screen-capture', 'processing', 'audio', 'location'}
assert info['BGTaskSchedulerPermittedIdentifiers'] == [
    '$(PRODUCT_BUNDLE_IDENTIFIER).backgroundRun.*',
    '$(PRODUCT_BUNDLE_IDENTIFIER).pairing',
]
print(f'PASS: {len(files)} Swift files parsed; project paths, plist and runtime dependency boundaries checked')
print('Run test_core.sh and an iPhoneOS build for runtime regression and type checking.')
