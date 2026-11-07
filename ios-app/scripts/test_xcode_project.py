#!/usr/bin/env python3
"""Check project generation and local signing configuration."""
import contextlib
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
    def test_local_overrides_do_not_change_project(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(generator, "ROOT", root), patch.dict(os.environ, {}, clear=True), contextlib.redirect_stdout(io.StringIO()):
                generator.objects.clear()
                generator.main([])
                project = root / "PhoneAgent.xcodeproj/project.pbxproj"
                before = project.read_text()
                self.assertFalse((root / "Config/Local.xcconfig").exists())
                with patch.dict(os.environ, {"ACTELL_BUNDLE_ID_PREFIX": "org.example.Actell", "ACTELL_DEVELOPMENT_TEAM": "ABCDE12345"}):
                    generator.objects.clear()
                    generator.main([])
                self.assertEqual(before, project.read_text())
                local = root / "Config/Local.xcconfig"
                self.assertIn("ACTELL_BUNDLE_ID_PREFIX = org.example.Actell", local.read_text())
                self.assertIn("ACTELL_DEVELOPMENT_TEAM = ABCDE12345", local.read_text())
                with patch.dict(os.environ, {"ACTELL_DEVELOPMENT_TEAM": "F012345678"}):
                    generator.main([])
                self.assertIn("ACTELL_BUNDLE_ID_PREFIX = org.example.Actell", local.read_text())
                self.assertIn("ACTELL_DEVELOPMENT_TEAM = F012345678", local.read_text())
                with patch.dict(os.environ, {"ACTELL_BUNDLE_ID_PREFIX": "bad value"}):
                    with self.assertRaises(ValueError):
                        generator.main([])
                self.assertIn("ACTELL_DEVELOPMENT_TEAM = F012345678", local.read_text())
                configs = [obj for obj in parse(before)["objects"].values() if obj["isa"] == "XCBuildConfiguration" and "PRODUCT_BUNDLE_IDENTIFIER" in obj["buildSettings"]]
                self.assertEqual(len(configs), 8)
                self.assertTrue(all("baseConfigurationReference" in config for config in configs))

    def test_xcode_saved_layout_round_trips_without_text_changes(self):
        project = ROOT / "PhoneAgent.xcodeproj/project.pbxproj"
        source = project.read_text()
        self.assertEqual(generator.serialize_project(parse(source), project.parent.stem), source)


if __name__ == "__main__":
    unittest.main()
