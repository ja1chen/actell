#!/usr/bin/env python3
"""Inspect linked ELF descriptors and actual build graph; not hardware acceptance."""
import hashlib, json, pathlib, struct
from elftools.elf.elffile import ELFFile
ROOT=pathlib.Path(__file__).resolve().parents[3]

def symbol_bytes(path,name):
    with path.open('rb') as file:
        elf=ELFFile(file)
        symbols=elf.get_section_by_name('.symtab').get_symbol_by_name(name)
        assert symbols and len(symbols)==1, (name,symbols)
        symbol=symbols[0]; section=elf.get_section(symbol['st_shndx'])
        start=symbol['st_value']-section['sh_addr']
        return section.data()[start:start+symbol['st_size']]

results=[]
for mode,hid in [('ncm',False),('hid',True),('diagnostic',False)]:
    build=ROOT/'.build'/f'esp32-{mode}'
    config=(build/'sdkconfig').read_text()
    description=json.loads((build/'project_description.json').read_text())
    components=description['build_components']
    assert 'esp_wifi' not in components and 'bt' not in components
    assert '# CONFIG_LWIP_IP_FORWARD is not set' in config
    assert '# CONFIG_LWIP_DHCPS is not set' in config
    assert f'CONFIG_TINYUSB_HID_COUNT={int(hid)}' in config
    assert 'CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y' in config
    assert ('CONFIG_USB_CONTROL_ENABLED=y' in config)==(mode!='diagnostic')
    elf=build/'phoneagent_usb_device.elf'
    raw=symbol_bytes(elf,'configuration'); device=symbol_bytes(elf,'device')
    assert device[4:7]==bytes([0xef,2,1]) # Composite IAD common class.
    assert struct.unpack_from('<H',raw,2)[0]==len(raw)
    assert raw[4]==(3 if hid else 2)
    assert raw[7]==0x80 and raw[8]==50 # Bus powered, 100mA, no remote wakeup claim.
    descriptors=[]; pos=0
    while pos<len(raw):
        size=raw[pos]; assert size>=2 and pos+size<=len(raw)
        descriptors.append(raw[pos:pos+size]); pos+=size
    eps=[d[2] for d in descriptors if d[1]==5]
    assert sorted(eps)==sorted([0x81,0x02,0x82,0x83] if hid else [0x81,0x02,0x82]),eps
    interfaces=[d[2] for d in descriptors if d[1]==4]
    assert set(interfaces)==set(range(3 if hid else 2))
    if hid:
        reports=symbol_bytes(elf,'reports')
        assert bytes([0x85,1]) in reports and bytes([0x85,2]) in reports
    binary=build/'phoneagent_usb_device.bin'
    results.append(dict(mode=mode,endpoints=[hex(e) for e in eps],interfaces=raw[4],
        binary=str(binary.relative_to(ROOT)),bytes=binary.stat().st_size,sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        radios_linked=False,dhcp=False,forwarding=False))
print(json.dumps(results,indent=2))
