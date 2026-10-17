#!/usr/bin/env python3
"""Validate catalogs and Swift literals. Optionally check compiler stringsdata too."""
from pathlib import Path
import argparse
import collections
import json
import os
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
HAN = re.compile(r"[\u3400-\u9fff]")
FORMAT = re.compile(r"%(?:(\d+)\$)?[-+#0 ]*\d*(?:\.\d+)?((?:hh|ll|h|l|q|z|t|j)?[@diuoxXfFeEgGaAcCsSp])")

def signature(value):
    result = collections.Counter()
    for i, match in enumerate(FORMAT.finditer(value.replace("%%", "")), 1):
        result[int(match[1] or i), match[2]] += 1
    return result

def units(value):
    if isinstance(value, dict):
        if "stringUnit" in value:
            yield value["stringUnit"]
        for key, item in value.items():
            if key != "stringUnit":
                yield from units(item)

def check_catalogs(errors):
    tables = collections.defaultdict(set)
    count = 0
    for directory in ("PhoneAgent", "PhoneAgentLiveActivity", "Shared"):
        for path in sorted((ROOT / directory).rglob("*.xcstrings")):
            catalog = json.loads(path.read_text())
            if catalog.get("sourceLanguage") != "en":
                errors.append(f"{path}: sourceLanguage must be en")
            for key, entry in catalog["strings"].items():
                count += 1
                tables[path.stem].add(key)
                # A pure interpolation is a language-neutral format, such as
                # ActivityKit's body containing an already-localized status.
                neutral_format = FORMAT.fullmatch(key) is not None
                if HAN.search(key) or not re.search(r"[A-Za-z]", key) and not neutral_format:
                    errors.append(f"{path}: key must be English: {key!r}")
                for language in ("en", "zh-Hans"):
                    localized = entry.get("localizations", {}).get(language, {})
                    values = list(units(localized))
                    if not values:
                        errors.append(f"{path}: missing {language}: {key!r}")
                    for unit in values:
                        value = unit.get("value", "")
                        if not value or unit.get("state") != "translated":
                            errors.append(f"{path}: incomplete {language}: {key!r}")
                        if signature(value) != signature(key):
                            errors.append(f"{path}: format mismatch in {language}: {key!r} -> {value!r}")
                        if collections.Counter(re.findall(r"\$\{[^}]+\}", key)) != collections.Counter(re.findall(r"\$\{[^}]+\}", value)):
                            errors.append(f"{path}: intent parameter mismatch in {language}: {key!r}")
                        if language == "en" and HAN.search(value):
                            errors.append(f"{path}: Chinese text in English translation: {key!r}")
                    plural = localized.get("variations", {}).get("plural", {})
                    if plural and ("other" not in plural or language == "en" and "one" not in plural):
                        errors.append(f"{path}: incomplete plural forms in {language}: {key!r}")
    return tables, count

def swift_inventory():
    developer = Path(os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
    toolchain = developer / "Toolchains/XcodeDefault.xctoolchain/usr"
    host = toolchain / "lib/swift/host"
    cache = ROOT.parent / ".build/localization-audit"
    cache.mkdir(parents=True, exist_ok=True)
    source = ROOT / "scripts/localization_inventory.swift"
    binary = cache / "inventory"
    if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
        subprocess.run([str(toolchain / "bin/swiftc"), "-sdk", str(developer / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"),
                        "-I", str(host), "-L", str(host), "-Xlinker", "-rpath", "-Xlinker", str(host),
                        "-module-cache-path", str(cache / "modules"), str(source), "-o", str(binary)], check=True)
    paths = [str(p) for directory in ("PhoneAgent", "PhoneAgentLiveActivity", "Shared") for p in sorted((ROOT / directory).rglob("*.swift"))]
    return json.loads(subprocess.check_output([str(binary), *paths]))

def non_ui_literal(item):
    contexts, literal, name = item["context"], item["literal"], Path(item["path"]).name
    # Persisted enum values and diagnostic matching must not depend on language.
    if "enumRaw" in contexts:
        return True
    if name == "Providers.swift":
        if "var:reasons" in contexts and "type:LLMDiagnostics" in contexts:
            return True
        if any("type:" + kind in contexts for kind in ("ReasoningFixtureProvider", "SkillFixtureProvider", "ToolErrorFixtureProvider", "TaskPiPProbeProvider")):
            return True
    if name == "RemoteConnectionController.swift" and ("func:runLANPairingUIFixture" in contexts or "func:make" in contexts and literal == '"书桌上的 Muse"'):
        return True  # Synthetic peer identity and fixture errors; never production copy.
    if name == "PhoneAgentRuntime.swift" and any("func:" + fn in contexts for fn in ("makeModel", "invokeSiriFixtureIfNeeded", "completeBackgroundUIFixtureIfNeeded")):
        return True  # Synthetic user/model history used by UI tests.
    if name == "AgentViewModel.swift" and "func:sendDraft" in contexts and "<attachment_content>" in literal:
        return True  # Model input envelope, never a UI label.
    if name == "SkillTools.swift" and literal.startswith('"技能是内置或用户导入的任务参考'):
        return True  # Model instructions, not display copy.
    if name == "SkillStore.swift" and literal == '"未标注"' and "type:SkillPackage" in contexts:
        return True  # Existing archive sentinel; displayVersion localizes it.
    if name == "ModelRequestErrorLabel.swift" and literal == '"模型请求超过 24 MiB 限制"':
        return True  # Match a legacy provider diagnostic before localizing it.
    return False

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extracted-root", type=Path, action="append", default=[], help="Build intermediates containing compiler-generated .stringsdata (repeat for simulator/device)")
    args = parser.parse_args()
    errors = []
    tables, count = check_catalogs(errors)
    inventory = swift_inventory()
    normalized_keys = {FORMAT.sub(lambda m: "{}", key) for key in tables["Localizable"]}
    source_bytes = {}
    for item in inventory:
        path = Path(item["path"])
        if path not in source_bytes:
            source_bytes[path] = path.read_bytes()
        data = source_bytes[path]
        prefix = data[max(0, item["start"] - 100):item["start"]].decode("utf-8", errors="ignore")
        if re.search(r"String\s*\(\s*localized\s*:\s*$", prefix):
            template = "".join(segment.get("text", "{}") for segment in item["segments"])
            for escaped, decoded in [(r"\n", "\n"), (r"\r", "\r"), (r"\t", "\t"), (r'\"', '"'), (r"\\", chr(92))]:
                template = template.replace(escaped, decoded)
            if template not in normalized_keys:
                line = data[:item["start"]].count(b"\n") + 1
                errors.append(f"{path}:{line}: missing localization key: {template!r}")
        if HAN.search(item["literal"]) and not item["nested"] and not non_ui_literal(item):
            path = Path(item["path"])
            line = path.read_bytes()[:item["start"]].count(b"\n") + 1
            errors.append(f"{path}:{line}: unlocalized Chinese literal: {item['literal'][:100]}")
    extracted_count = 0
    for directory in args.extracted_root:
        files = list(directory.rglob("*.stringsdata"))
        if not files:
            errors.append(f"{directory}: no compiler stringsdata found; build with SWIFT_EMIT_LOC_STRINGS=YES")
        for path in files:
            data = json.loads(path.read_text())
            source = data.get("source", "")
            if not any(str(ROOT / name) + "/" in source for name in ("PhoneAgent", "PhoneAgentLiveActivity", "Shared")):
                continue
            for table, strings in data.get("tables", {}).items():
                for item in strings:
                    key = item["key"]
                    if not key or not re.search(r"[A-Za-z\u3400-\u9fff]", key):
                        continue  # Empty titles and invariant selection symbols.
                    extracted_count += 1
                    if key not in tables[table]:
                        errors.append(f"{source}: missing compiler key in {table}: {key!r}")
    if errors:
        print("\n".join(sorted(set(errors))), file=sys.stderr)
        return 1
    print(f"Localization audit passed: {count} entries, en + zh-Hans; {len(inventory)} Swift literals checked; {extracted_count} compiler entries checked.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
