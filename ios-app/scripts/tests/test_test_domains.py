"""Verify test-domain isolation without running App or Muse business tests."""
from contextlib import redirect_stdout
import importlib.util
import io
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET


SCRIPTS = Path(__file__).resolve().parents[1]


class TestDomainIsolation(unittest.TestCase):
    def generator(self, root):
        spec = importlib.util.spec_from_file_location("project_generator", SCRIPTS / "generate_xcode_project.py")
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        generator.ROOT = root
        return generator

    def test_misplaced_remote_files_cannot_join_default_targets(self):
        for folder in ["PhoneAgentTests", "PhoneAgentUITests"]:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                path = root / folder / "MuseNewFeatureTests.swift"
                path.parent.mkdir(parents=True)
                path.write_text("import XCTest\n")
                with self.assertRaisesRegex(ValueError, "Remote-domain test"):
                    self.generator(root).generate()

    def test_shared_fixtures_cannot_hide_test_classes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "TestSupport/HiddenTests.swift"
            path.parent.mkdir()
            path.write_text("final class HiddenTests: XCTestCase {}\n")
            with self.assertRaisesRegex(ValueError, "fixtures only"):
                self.generator(root).generate()

    def test_generated_targets_and_schemes_keep_remote_sources_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            generator = self.generator(Path(directory))
            for folder, filename in [
                ("PhoneAgentTests", "CoreSmoke.swift"),
                ("RemoteTests", "NewRemoteFeature.swift"),
                ("PhoneAgentUITests", "CoreUISmoke.swift"),
                ("RemoteTests/UI", "NewRemoteUI.swift"),
                ("TestSupport", "SharedFixture.swift"),
            ]:
                path = generator.ROOT / folder / filename
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("// Synthetic source membership fixture.\n")
            with redirect_stdout(io.StringIO()):
                generator.generate()
            graph = generator.objects
            expected_sources = {
                "PhoneAgentTests": {"PhoneAgentTests/CoreSmoke.swift", "TestSupport/SharedFixture.swift"},
                "PhoneAgentUITests": {"PhoneAgentUITests/CoreUISmoke.swift"},
                "RemoteTests": {"RemoteTests/NewRemoteFeature.swift", "TestSupport/SharedFixture.swift"},
                "RemoteUITests": {"RemoteTests/UI/NewRemoteUI.swift"},
            }
            for target_name, expected in expected_sources.items():
                phase = graph[generator.uid(target_name + "Sources")]
                sources = {graph[graph[file]["fileRef"]]["path"] for file in phase["files"]}
                self.assertEqual(sources, expected)
            ui_group = generator.uid("RemoteUITestsGroup")
            self.assertIn(ui_group, graph[generator.uid("RemoteTestsGroup")]["children"])
            self.assertEqual(graph[ui_group]["name"], "UI")
            self.assertNotIn(ui_group, graph[generator.uid("RootGroup")]["children"])
            schemes = generator.ROOT / "PhoneAgent.xcodeproj/xcshareddata/xcschemes"
            for name, expected in [
                ("PhoneAgent", {"PhoneAgentTests", "PhoneAgentUITests"}),
                ("PhoneAgentRemote", {"RemoteTests", "RemoteUITests"}),
            ]:
                xml = ET.parse(schemes / (name + ".xcscheme"))
                actual = {ref.attrib["BlueprintName"] for ref in xml.findall(".//TestableReference/BuildableReference")}
                self.assertEqual(actual, expected)

    def runner_arguments(self, script, selectors=(), ui=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            capture = root / "arguments"
            executable = root / "xcodebuild"
            executable.write_text('#!/bin/bash\nprintf "%s\\0" "$@" > "$DOMAIN_TEST_ARGUMENTS"\n')
            executable.chmod(0o755)
            python = root / "python3"
            python.write_text('#!/bin/bash\nif [[ "${1:-}" = */prepare_ui_fixtures.py ]]; then exit 0; fi\n'
                              + 'exec ' + shlex.quote(sys.executable) + ' "$@"\n')
            python.chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       DOMAIN_TEST_ARGUMENTS=str(capture), RUN_UI_TESTS="1" if ui else "0")
            result = subprocess.run(["bash", str(SCRIPTS / script), "synthetic-simulator", *selectors],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return capture.read_bytes().decode().strip("\0").split("\0")

    def test_default_command_never_selects_remote_tests_even_with_ui(self):
        for ui in [False, True]:
            args = self.runner_arguments("test_core.sh", ui=ui)
            self.assertEqual(args[args.index("-scheme") + 1], "PhoneAgent")
            self.assertIn("-only-testing:PhoneAgentTests", args)
            self.assertFalse(any("Remote" in arg for arg in args))
            self.assertEqual("-only-testing:PhoneAgentUITests" in args, ui)

    def test_core_selector_stays_within_core_target(self):
        args = self.runner_arguments("test_core.sh", ["AttachmentStoreTests/testText"])
        self.assertIn("-only-testing:PhoneAgentTests/AttachmentStoreTests/testText", args)
        self.assertNotIn("-only-testing:PhoneAgentTests", args)
        self.assertFalse(any("Remote" in arg for arg in args))

    def test_remote_requires_its_explicit_command(self):
        for ui in [False, True]:
            args = self.runner_arguments("test_remote.sh", ["RemoteStrictJSONTests"], ui=ui)
            self.assertEqual(args[args.index("-scheme") + 1], "PhoneAgentRemote")
            self.assertIn("-only-testing:RemoteTests/RemoteStrictJSONTests", args)
            self.assertNotIn("-only-testing:PhoneAgentTests", args)
            self.assertEqual("-only-testing:RemoteUITests" in args, ui)


if __name__ == "__main__":
    unittest.main()
