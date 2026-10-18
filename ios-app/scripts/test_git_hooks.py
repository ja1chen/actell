#!/usr/bin/env python3
"""Exercise the signing guard against temporary Git indexes and real commits."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HOOKS = Path(__file__).resolve().parents[2] / ".githooks"
PROJECT = "App.xcodeproj/project.pbxproj"
BASE = '''// !$*UTF8*$!
{
 objects = {
  AAAAAAAAAAAAAAAAAAAAAAAA = {
   isa = PBXBuildConfiguration;
   buildSettings = {
    DEVELOPMENT_TEAM = "";
    PRODUCT_BUNDLE_IDENTIFIER = org.example.App;
    SWIFT_VERSION = 6.0;
   };
   name = Debug;
  };
 };
}
'''


class SigningHookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_")}
        self.git("init", "-q")
        self.git("config", "user.name", "Hook Test")
        self.git("config", "user.email", "hook-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.write_project(BASE)
        self.git("add", PROJECT)
        self.git("commit", "-qm", "Baseline")
        self.git("config", "core.hooksPath", str(HOOKS))

    def git(self, *args, check=True):
        return subprocess.run(["git", *args], cwd=self.root, env=self.env,
                              capture_output=True, check=check)

    def write_project(self, text):
        path = self.root / PROJECT
        path.parent.mkdir(exist_ok=True)
        path.write_text(text)

    def hook(self):
        return subprocess.run([str(HOOKS / "pre-commit")], cwd=self.root,
                              env=self.env, capture_output=True)

    def test_unstaged_local_overrides_do_not_block_other_changes(self):
        self.write_project(BASE.replace('DEVELOPMENT_TEAM = ""', 'DEVELOPMENT_TEAM = ABCDE12345'))
        (self.root / "note.txt").write_text("ordinary change\n")
        self.git("add", "note.txt")
        self.assertEqual(self.hook().returncode, 0)

    def test_team_and_bundle_changes_are_rejected_without_printing_values(self):
        for old, new, key, private_value in [
            ('DEVELOPMENT_TEAM = ""', 'DEVELOPMENT_TEAM = ABCDE12345', "DEVELOPMENT_TEAM", b"ABCDE12345"),
            ('org.example.App', 'org.private.LocalApp', "PRODUCT_BUNDLE_IDENTIFIER", b"org.private.LocalApp"),
        ]:
            with self.subTest(key=key):
                self.write_project(BASE.replace(old, new))
                self.git("add", PROJECT)
                result = self.hook()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(key.encode(), result.stderr)
                self.assertNotIn(private_value, result.stdout + result.stderr)

    def test_unrelated_staged_project_edit_uses_index_not_working_copy(self):
        staged = BASE.replace("SWIFT_VERSION = 6.0", "SWIFT_VERSION = 6.1")
        self.write_project(staged)
        self.git("add", PROJECT)
        self.write_project(staged.replace("org.example.App", "org.private.LocalApp"))
        self.assertEqual(self.hook().returncode, 0)

    def test_formatting_does_not_change_signing_identity(self):
        self.write_project(BASE.replace('DEVELOPMENT_TEAM = "";', 'DEVELOPMENT_TEAM="";').replace('org.example.App;', '"org.example.App";'))
        self.git("add", PROJECT)
        self.assertEqual(self.hook().returncode, 0)

    def test_invalid_staged_project_is_rejected(self):
        self.write_project("not a project\n")
        self.git("add", PROJECT)
        self.assertNotEqual(self.hook().returncode, 0)

    def test_real_commit_is_blocked_without_altering_index_or_local_files(self):
        changed = BASE.replace("org.example.App", "org.private.LocalApp")
        self.write_project(changed)
        self.git("add", PROJECT)
        head = self.git("rev-parse", "HEAD").stdout
        index = self.git("write-tree").stdout
        result = self.git("commit", "-m", "Must be blocked", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, head)
        self.assertEqual(self.git("write-tree").stdout, index)
        self.assertEqual((self.root / PROJECT).read_text(), changed)

    def test_added_and_deleted_projects_with_signing_settings_are_rejected(self):
        self.git("rm", PROJECT)
        self.assertNotEqual(self.hook().returncode, 0)
        self.git("reset", "--hard", "HEAD")
        extra = self.root / "Extra.xcodeproj/project.pbxproj"
        extra.parent.mkdir()
        extra.write_text(BASE)
        self.git("add", str(extra.relative_to(self.root)))
        self.assertNotEqual(self.hook().returncode, 0)


if __name__ == "__main__":
    unittest.main()
