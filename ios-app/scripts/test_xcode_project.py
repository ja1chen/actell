#!/usr/bin/env python3
"""Check Xcode save compatibility and localized generation diffs without building."""
import contextlib
import difflib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("actell_project_generator", ROOT / "scripts/generate_xcode_project.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


def parse(text):
    return json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", "-"], input=text.encode()))


class ProjectGenerationTests(unittest.TestCase):
    def test_defaults_generates_defaults_even_with_invalid_overrides(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "ios-app"
            root.mkdir()
            with patch.object(generator, "ROOT", root), contextlib.redirect_stdout(io.StringIO()):
                with patch.dict(os.environ, {}, clear=True):
                    generator.objects.clear()
                    generator.main([])
                    expected = (root / "PhoneAgent.xcodeproj/project.pbxproj").read_text()
                overrides = {"ACTELL_BUNDLE_ID_PREFIX": "invalid bundle id", "ACTELL_DEVELOPMENT_TEAM": "ABCDE12345"}
                with patch.dict(os.environ, overrides):
                    for flag in ("-d", "--defaults"):
                        with self.subTest(flag=flag):
                            generator.objects.clear()
                            generator.main([flag])
                            self.assertEqual({key: os.environ[key] for key in overrides}, overrides)
                            self.assertEqual((root / "PhoneAgent.xcodeproj/project.pbxproj").read_text(), expected)
                actual = (root / "PhoneAgent.xcodeproj/project.pbxproj").read_text()
                self.assertEqual(actual, expected)
                settings = [obj["buildSettings"] for obj in parse(actual)["objects"].values()
                            if obj["isa"] == "XCBuildConfiguration" and "PRODUCT_BUNDLE_IDENTIFIER" in obj["buildSettings"]]
                self.assertEqual(len(settings), 8)
                self.assertTrue(all(setting["DEVELOPMENT_TEAM"] == "" for setting in settings))
                self.assertEqual({setting["PRODUCT_BUNDLE_IDENTIFIER"] for setting in settings}, {
                    "com.ja1chen.PhoneAgent", "com.ja1chen.PhoneAgent.LiveActivity",
                    "com.ja1chen.PhoneAgentTests", "com.ja1chen.PhoneAgentUITests",
                })

    def test_xcode_saved_layout_round_trips_without_text_changes(self):
        project = ROOT / "PhoneAgent.xcodeproj/project.pbxproj"
        source = project.read_text()
        result = generator.serialize_project(parse(source), project.parent.stem)
        # A failure must not print signing configuration from the local project.
        self.assertTrue(result == source, "Project formatting differs from the Xcode-compatible serializer")

    def test_team_edit_changes_only_eight_configuration_lines(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "ios-app"
            root.mkdir()
            with patch.object(generator, "ROOT", root), patch.dict(os.environ, ACTELL_BUNDLE_ID_PREFIX="org.example.Actell"):
                def generate(team):
                    with patch.dict(os.environ, ACTELL_DEVELOPMENT_TEAM=team), contextlib.redirect_stdout(io.StringIO()):
                        generator.objects.clear()
                        generator.generate()
                    return (root / "PhoneAgent.xcodeproj/project.pbxproj").read_text()

                before = generate("ABCDE12345")
                after = generate("F012345678")
                changes = [line for line in difflib.ndiff(before.splitlines(), after.splitlines()) if line.startswith(("- ", "+ "))]
                self.assertEqual(len(changes), 16)
                self.assertTrue(all("DEVELOPMENT_TEAM =" in line for line in changes))
                self.assertEqual(generate("F012345678"), after)
                objects = parse(after)["objects"]
                ids = {}
                for target in objects.values():
                    if target["isa"] != "PBXNativeTarget":
                        continue
                    configs = objects[target["buildConfigurationList"]]["buildConfigurations"]
                    ids[target["name"]] = {objects[config]["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"] for config in configs}
                self.assertEqual(ids, {
                    "PhoneAgent": {"org.example.Actell"},
                    "PhoneAgentLiveActivity": {"org.example.Actell.LiveActivity"},
                    "PhoneAgentTests": {"org.example.ActellTests"},
                    "PhoneAgentUITests": {"org.example.ActellUITests"},
                })


if __name__ == "__main__":
    unittest.main()
