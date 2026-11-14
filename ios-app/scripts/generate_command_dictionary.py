#!/usr/bin/env python3
"""Register commands exported by the pinned, bundled ios_system modules."""
import argparse
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "ios-app/CommandKit"
MODULES = ("ios_system", "files", "text", "shell")


def symbols(binary):
    result = subprocess.run(["nm", "-arch", "arm64", "-gU", str(binary)],
                            check=True, capture_output=True, text=True)
    return {parts[-1].removeprefix("_") for line in result.stdout.splitlines()
            if len(parts := line.split()) == 3}


def generate(artifacts):
    exports = {}
    for module in MODULES:
        framework = artifacts / module / f"{module}.xcframework"
        device = symbols(framework / "ios-arm64" / f"{module}.framework" / module)
        simulator = symbols(framework / "ios-arm64_x86_64-simulator" / f"{module}.framework" / module)
        exports[module] = device & simulator
    upstream = {}
    for name in ("commandDictionary", "extraCommandsDictionary"):
        upstream.update(plistlib.loads((PACKAGE / "THIRD_PARTY" / f"ios_system-{name}.plist").read_bytes()))
    commands = {}
    for name, entry in upstream.items():
        preferred = entry[0].split(".")[0]
        owner = next((m for m in dict.fromkeys((preferred, *MODULES))
                      if entry[1] in exports.get(m, set())), None)
        if owner:
            library = "SELF" if owner == "ios_system" else f"{owner}.framework/{owner}"
            commands[name] = [library, *entry[1:]]
    registered = {entry[1] for entry in commands.values()}
    for module, names in exports.items():
        for function in sorted(names):
            if function.endswith("_main") and function not in registered:
                library = "SELF" if module == "ios_system" else f"{module}.framework/{module}"
                commands[function.removesuffix("_main")] = [library, function, "", "no"]
    output = ROOT / "ios-app/PhoneAgent/Resources/commandDictionary.plist"
    output.write_bytes(plistlib.dumps(commands, sort_keys=True))
    print(f"Registered {len(commands)} commands/aliases from {len(MODULES)} bundled modules.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, default=ROOT / ".build/SourcePackages/artifacts/commandkit")
    generate(parser.parse_args().artifacts)
