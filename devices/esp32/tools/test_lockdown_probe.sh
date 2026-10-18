#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../../.."
mkdir -p .build/lockdown-fixtures
# Independent stdlib plistlib oracle; no third-party modules, device, secrets,
# pairing records, network services or complete upstream checkout are needed.
"${PYTHON:-python3}" - <<'PY'
from pathlib import Path
import plistlib

out = Path('.build/lockdown-fixtures')
rows, lines = [], ['/* Synthetic fixtures from Python stdlib plistlib. */']

def emit(name, data):
    lines.append(f'static const uint8_t {name}[] = {{' + ','.join(str(x) for x in data) + '};')

def add(value, expected='BRIDGE_OK', *, fmt=plistlib.FMT_BINARY, echo=False):
    data = plistlib.dumps(value, fmt=fmt, sort_keys=False)
    assert plistlib.loads(data) == value
    name = f'plist_{len(rows)}'
    emit(name, data)
    encoding = 'BRIDGE_LOCKDOWN_ENCODING_BINARY' if fmt == plistlib.FMT_BINARY else 'BRIDGE_LOCKDOWN_ENCODING_XML'
    rows.append(f'{{{name},sizeof {name},{expected},{encoding},{str(echo).lower()}}}')

for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
    add({'Type': 'com.apple.mobile.lockdown'}, fmt=fmt)
    add({'Request': 'QueryType', 'Type': 'com.apple.mobile.lockdown'}, fmt=fmt, echo=True)
    add({'Type': 'com.apple.mobile.lockdown', 'Result': 'Success', 'Request': 'QueryType'}, fmt=fmt, echo=True)
    add({'Request': 'QueryType'}, 'BRIDGE_E_NOT_FOUND', fmt=fmt)
    add({'Type': 'com.apple.mobile.lockdown.evil'}, 'BRIDGE_E_TYPE', fmt=fmt)
    add({'Type': 'com.apple.mobile.lockdown', 'Request': 'Pair'}, 'BRIDGE_E_TYPE', fmt=fmt)
    add({'Type': 'com.apple.mobile.lockdown', 'Error': 'PasswordProtected'}, 'BRIDGE_E_TYPE', fmt=fmt)
    add({'Type': 'com.apple.mobile.lockdown', 'Result': 'Failure'}, 'BRIDGE_E_TYPE', fmt=fmt)
    add({'Type': 'com.apple.mobile.lockdown', 'Unexpected': 'QueryType'}, 'BRIDGE_E_UNSUPPORTED', fmt=fmt)
    add({}, 'BRIDGE_E_NOT_FOUND', fmt=fmt)

# Binary primitives, nesting, unsupported objects and overlarge object graph.
for value in ({'Type': 1}, {'Type': b'com.apple.mobile.lockdown'},
              {'Type': ['com.apple.mobile.lockdown']}, ['com.apple.mobile.lockdown']):
    add(value, 'BRIDGE_E_TYPE')
add({'Type': 1.5}, 'BRIDGE_E_UNSUPPORTED')
add({'Type': 'com.apple.mobile.lockdown', 'Request': 'QueryType',
     'Result': 'Success', 'Fourth': 'x'}, 'BRIDGE_E_LIMIT')

# Hand-built duplicate keys cannot be represented by Python dict. Other custom
# cases exercise UTF16 ASCII, cyclic references and binary structural failures.
def binary(objects, root=0, refs=1):
    data = bytearray(b'bplist00')
    offsets = []
    for obj in objects:
        offsets.append(len(data))
        data.extend(obj)
    table = len(data)
    width = 1 if table < 256 else 2
    data.extend(b''.join(n.to_bytes(width, 'big') for n in offsets))
    data.extend(b'\0' * 6 + bytes([width, refs]) + len(objects).to_bytes(8, 'big') +
                root.to_bytes(8, 'big') + table.to_bytes(8, 'big'))
    return data

def string(s, utf16=False):
    raw = s.encode('utf-16-be' if utf16 else 'ascii')
    return bytes([(0x60 if utf16 else 0x50) | min(len(s), 15)]) + (bytes([0x10, len(s)]) if len(s) >= 15 else b'') + raw

def custom(data, expected, echo=False):
    name = f'plist_{len(rows)}'
    emit(name, data)
    rows.append(f'{{{name},sizeof {name},{expected},BRIDGE_LOCKDOWN_ENCODING_BINARY,{str(echo).lower()}}}')

base = binary([b'\xd1\x01\x02', string('Type'), string('com.apple.mobile.lockdown')])
assert plistlib.loads(base) == {'Type': 'com.apple.mobile.lockdown'}
custom(base, 'BRIDGE_OK')
utf16 = binary([b'\xd1\x01\x02', string('Type', True), string('com.apple.mobile.lockdown', True)])
assert plistlib.loads(utf16) == plistlib.loads(base)
custom(utf16, 'BRIDGE_OK')
# Root need not be zero, objects need not appear in reference-index order.
custom(binary([string('Type'), string('com.apple.mobile.lockdown'), b'\xd1\x00\x01'], root=2), 'BRIDGE_OK')
custom(binary([b'\xd2\x01\x01\x02\x02', string('Type'), string('com.apple.mobile.lockdown')]), 'BRIDGE_E_FORMAT')
custom(binary([b'\xd1\x01\x00', string('Type')]), 'BRIDGE_E_TYPE')
custom(binary([b'\xd1\x01\x09', string('Type'), string('com.apple.mobile.lockdown')]), 'BRIDGE_E_FORMAT')
custom(binary([b'\xd1\x01\x02', string('Type'), string('com.apple.mobile.lockdown'), string('unreferenced')]), 'BRIDGE_E_FORMAT')
custom(binary([b'\xd1\x01\x02', string('Type'), b'\x61\xd8\x00']), 'BRIDGE_E_UNSUPPORTED')
custom(binary([b'\xd1\x01\x02', string('Type'), b'\x51\0']), 'BRIDGE_E_FORMAT')
custom(binary([b'\xd1\x01\x02', string('Type'), b'\x5f\x13\xff\xff\xff\xff\xff\xff\xff\xff']), 'BRIDGE_E_FORMAT')
for index in range(6):
    corrupt = bytearray(base)
    corrupt[-32 + index] = 1
    custom(corrupt, 'BRIDGE_E_FORMAT')
# Duplicate object offsets and trailing bytes between offset table and trailer.
corrupt = bytearray(base)
table = int.from_bytes(corrupt[-8:], 'big')
corrupt[table + 2] = corrupt[table + 1]
custom(corrupt, 'BRIDGE_E_FORMAT')
custom(base[:-32] + b'\0' + base[-32:], 'BRIDGE_E_FORMAT')
# Fake Type in an unreachable object never turns a wrong root into success.
custom(binary([string('wrong-root'), string('Type'), string('com.apple.mobile.lockdown')]), 'BRIDGE_E_TYPE')
lines.append('static const fixture fixtures[] = {' + ',\n'.join(rows) + '};')
(out / 'lockdown_fixtures.h').write_text('\n'.join(lines))
print(f'Generated {len(rows)} synthetic XML/binary reply fixtures')
PY
cc=${CC:-gcc}
"$cc" -std=c11 -O1 -g -Wall -Wextra -Werror -Wconversion -Wshadow \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I devices/esp32/shared/protocol/include -I .build/lockdown-fixtures \
  devices/esp32/shared/protocol/bridge_io.c \
  devices/esp32/shared/protocol/bridge_bplist.c \
  devices/esp32/shared/protocol/bridge_lockdown_probe.c \
  devices/esp32/tests/protocol/test_lockdown_probe.c -o .build/test_lockdown_probe
ASAN_OPTIONS=detect_leaks=0 .build/test_lockdown_probe
"${PYTHON:-python3}" - <<'PY'
from pathlib import Path
import plistlib
import struct
wire = Path('.build/lockdown-fixtures/captured_query.bin').read_bytes()
assert struct.unpack('>I', wire[:4])[0] == len(wire) - 4
assert plistlib.loads(wire[4:]) == {'Label': 'esp32-iphone-bridge', 'Request': 'QueryType'}
print('PASS: captured wire independently decoded by plistlib as exactly Label + QueryType')
PY
