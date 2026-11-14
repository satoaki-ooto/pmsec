from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import run  # noqa: E402


class ConformanceEnvTest(unittest.TestCase):
    def test_composer_home_is_pinned_to_the_case_home_for_every_port(self):
        home = Path("/tmp/pmsec-conformance-home")
        for impl in ("bash", "node", "python", "powershell"):
            with self.subTest(impl=impl):
                env = run.env_for(impl, home)
                self.assertEqual(env["COMPOSER_HOME"], str(home / ".config" / "composer"))
                self.assertEqual(env["XDG_CONFIG_HOME"], str(home / ".config"))

    def test_mise_system_config_dir_is_pinned_to_the_case_home_for_every_port(self):
        home = Path("/tmp/pmsec-conformance-home")
        for impl in ("bash", "node", "python", "powershell"):
            with self.subTest(impl=impl):
                env = run.env_for(impl, home)
                self.assertEqual(env["MISE_SYSTEM_CONFIG_DIR"], str(home / "etc-mise"))

    def test_composer_cases_expect_the_pinned_composer_home(self):
        home = Path("/tmp/pmsec-conformance-home")
        expected = (home / ".config" / "composer" / "config.json").as_posix()
        cases = [json.loads(path.read_text()) for path in sorted(run.CASES_DIR.glob("*.json"))]
        composer_rows = [
            row
            for case in cases
            for row in case["expected_json"].get("rows", [])
            if row.get("tool") == "composer"
        ]
        self.assertTrue(composer_rows)
        for row in composer_rows:
            with self.subTest(path=row["path"]):
                self.assertEqual(row["path"].replace("<HOME>", home.as_posix()), expected)


class CaseEnvTest(unittest.TestCase):
    def test_home_placeholder_expands_to_the_case_home(self):
        home = Path("/tmp/pmsec-conf-home")
        env = run.case_env("python", home, {"MISE_CONFIG_DIR": "<HOME>/custom"})
        self.assertEqual(env["MISE_CONFIG_DIR"], f"{home}/custom")

    def test_overrides_win_over_runner_defaults(self):
        home = Path("/tmp/pmsec-conf-home")
        env = run.case_env("python", home, {"XDG_CONFIG_HOME": "/elsewhere"})
        self.assertEqual(env["XDG_CONFIG_HOME"], "/elsewhere")

    def test_values_without_placeholder_pass_through(self):
        home = Path("/tmp/pmsec-conf-home")
        env = run.case_env("python", home, {"MISE_CONFIG_DIR": "/plain/path"})
        self.assertEqual(env["MISE_CONFIG_DIR"], "/plain/path")


if __name__ == "__main__":
    unittest.main()
