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
