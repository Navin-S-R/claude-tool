from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SKILL = REPO / "codex" / "skills" / "ct-pr-description"
SKILL_MD = SKILL / "SKILL.md"
COMMAND_MD = REPO / "commands" / "pr-description.md"
MARKER = "# ct-upload-path"

SHARED_STRINGS = [
    "--cache",
    "screenshot not uploaded (see author)",
    'width="280"',
    "### Issue Description",
    "### Steps to Reproduce",
    "### Solution Provided",
    "### Impact Analysis – Proof That Existing Flows Are Not Affected",
    "### Before and After Screenshots",
    "Keep it short",
    "LOGIN",
    "--login --terminal",
]


def path_loop():
    """The skill's marked lines, from the marker to the `done` that ends the loop."""
    lines = [line.strip() for line in SKILL_MD.read_text().splitlines()]
    start = lines.index(MARKER)
    end = lines.index("done", start)
    return "\n".join(lines[start : end + 1])


class UploadPathTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)

    def resolve(self):
        script = path_loop() + '\nprintf %s "$UPLOAD"\n'
        result = subprocess.run(
            ["bash", "-c", script],
            cwd=self.home,
            env={"HOME": str(self.home), "PATH": "/usr/bin:/bin"},
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout

    def test_symlinked_user_install_resolves_to_checkout_tool(self):
        skills = self.home / ".agents" / "skills"
        skills.mkdir(parents=True)
        (skills / "ct-pr-description").symlink_to(SKILL)
        expected = REPO / "tools" / "gh-image-upload" / "upload.mjs"
        self.assertEqual(self.resolve(), str(expected.resolve()))

    def test_no_install_finds_no_candidate(self):
        self.assertEqual(self.resolve(), "")


class DriftTests(unittest.TestCase):
    def test_shared_strings_exist_in_both_files(self):
        for path in (COMMAND_MD, SKILL_MD):
            text = path.read_text()
            for string in SHARED_STRINGS:
                with self.subTest(file=path.name, string=string):
                    self.assertIn(string, text)
