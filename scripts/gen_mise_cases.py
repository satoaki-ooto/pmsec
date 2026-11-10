#!/usr/bin/env python3
"""Generate mise new-mode conformance cases from the node port's output.

Run once while adding cases: `python3 scripts/gen_mise_cases.py`. The generated
JSON files under conformance/cases/ are the committed contract; this script is
a convenience so the expected bytes come from a running implementation instead
of being hand-copied.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
NEW_MODE = {"PMSEC_MISE_VERSION": "2026.11.0"}

# name, setup, setup_from (copy expected_files of an earlier case first),
# env overrides, args
CASES = [
    ("enable_mise_new_mode_fresh", {}, None, NEW_MODE, ["--tool", "mise", "--days", "1", "--json"]),
    (
        "enable_mise_new_mode_selector_inherit",
        {".config/mise/miserc.local.toml": 'env = [\n  "work", # keep\n  "outside",\n]\nother = 1\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_forward_migration",
        {".config/mise/config.toml": '[settings]\nminimum_release_age = "7d"\nexperimental = true\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_forward_force",
        {".config/mise/config.toml": '[settings]\nminimum_release_age = "7d"\nexperimental = true\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--force", "--json"],
    ),
    (
        "enable_mise_new_mode_distinct_base",
        {
            ".config/mise/config.toml": '[settings]\nminimum_release_age = "7d"\n',
            "mise-custom/config.toml": '[settings]\nminimum_release_age = "9d"\n',
        },
        None,
        {**NEW_MODE, "MISE_CONFIG_DIR": "<HOME>/mise-custom"},
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "check_mise_new_mode_wired",
        {},
        "enable_mise_new_mode_fresh",
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--check", "--json"],
    ),
    (
        "check_mise_new_mode_mise_env_work",
        {},
        "enable_mise_new_mode_fresh",
        {**NEW_MODE, "MISE_ENV": "work"},
        ["--tool", "mise", "--days", "1", "--check", "--json"],
    ),
    (
        "check_mise_new_mode_mise_env_pmsec",
        {},
        "enable_mise_new_mode_fresh",
        {**NEW_MODE, "MISE_ENV": "work,pmsec"},
        ["--tool", "mise", "--days", "1", "--check", "--json"],
    ),
    (
        "enable_mise_new_mode_mise_env_warns",
        {},
        "enable_mise_new_mode_fresh",
        {**NEW_MODE, "MISE_ENV": "work"},
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "check_mise_new_mode_selector_only",
        {".config/mise/miserc.local.toml": 'env = ["work", "pmsec"]\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--check", "--json"],
    ),
    (
        "enable_mise_new_mode_invalid_env",
        {".config/mise/miserc.local.toml": "env = [1]\n"},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "disable_mise_new_mode",
        {
            ".config/mise/config.pmsec.toml": '[settings]\nminimum_release_age = "3d"\nparanoid = true\nexperimental = true\n',
            ".config/mise/miserc.local.toml": 'env = ["work", "pmsec"]\nother = 1\n',
        },
        None,
        NEW_MODE,
        ["--tool", "mise", "--disable", "--json"],
    ),
    (
        "check_mise_legacy_conflict",
        {
            ".config/mise/config.pmsec.toml": '[settings]\nminimum_release_age = "1d"\n',
            ".config/mise/miserc.local.toml": 'env = ["pmsec"]\n',
        },
        None,
        {"PMSEC_MISE_VERSION": "2026.10.25"},
        ["--tool", "mise", "--check", "--json"],
    ),
    (
        "enable_mise_reverse_migration_unknown",
        {
            ".config/mise/config.pmsec.toml": '[settings]\nminimum_release_age = "3d"\nexperimental = true\n',
            ".config/mise/miserc.local.toml": 'env = ["work", "pmsec"]\nother = 1\n',
        },
        None,
        {"PMSEC_MISE_VERSION": "none"},
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_reverse_migration_old",
        {
            ".config/mise/config.pmsec.toml": '[settings]\nminimum_release_age = "3d"\n',
            ".config/mise/miserc.local.toml": 'env = ["pmsec"]\n',
        },
        None,
        {"PMSEC_MISE_VERSION": "2026.10.25"},
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_reverse_migration_config_dir",
        {
            "mise-custom/config.pmsec.toml": '[settings]\nminimum_release_age = "3d"\n',
            "mise-custom/miserc.local.toml": 'env = ["pmsec"]\n',
        },
        None,
        {"PMSEC_MISE_VERSION": "2026.10.25", "MISE_CONFIG_DIR": "<HOME>/mise-custom"},
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_reverse_migration_global_file",
        {
            ".config/mise/config.pmsec.toml": '[settings]\nminimum_release_age = "3d"\n',
            ".config/mise/miserc.local.toml": 'env = ["pmsec"]\n',
        },
        None,
        {"PMSEC_MISE_VERSION": "2026.11.0", "MISE_GLOBAL_CONFIG_FILE": "<HOME>/custom-global.toml"},
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_shared_env_inherit",
        {".config/mise/miserc.toml": 'env = ["shared"]\nkept = true\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_system_env_inherit",
        {"etc-mise/miserc.toml": 'env = ["system-wide"]\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_multiline_env",
        {".config/mise/miserc.local.toml": 'note = """\nenv = ["ghost"]\n"""\nenv = ["work"]\nother = 1\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_multiline_section",
        {".config/mise/miserc.local.toml": 'note = """\n[settings]\nenv = ["ghost"]\n"""\nother = 1\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_moves_pmsec_last",
        {".config/mise/miserc.local.toml": 'env = ["pmsec", "work"]\nother = 1\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_idempotent",
        {},
        "enable_mise_new_mode_fresh",
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
        {"pre": [["--tool", "mise", "--days", "1", "--json"]]},
    ),
    (
        "disable_mise_selector_only",
        {".config/mise/miserc.local.toml": 'env = ["work", "pmsec"]\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--disable", "--json"],
    ),
    (
        "enable_mise_reverse_migration_selector_only",
        {".config/mise/miserc.local.toml": 'env = ["pmsec"]\n'},
        None,
        {"PMSEC_MISE_VERSION": "none"},
        ["--tool", "mise", "--days", "1", "--json"],
        {"missing": [".config/mise/miserc.local.toml"]},
    ),
    (
        "enable_mise_legacy_global_file_no_artifacts",
        {},
        None,
        {"PMSEC_MISE_VERSION": "2026.11.0", "MISE_GLOBAL_CONFIG_FILE": "<HOME>/custom-global.toml"},
        ["--tool", "mise", "--days", "1", "--json"],
        {"missing": [".config/mise/config.pmsec.toml", ".config/mise/miserc.local.toml"]},
    ),
    (
        "check_mise_after_reverse_migration",
        {
            ".config/mise/config.pmsec.toml": '[settings]\nminimum_release_age = "3d"\n',
            ".config/mise/miserc.local.toml": 'env = ["pmsec"]\n',
        },
        None,
        {"PMSEC_MISE_VERSION": "none"},
        ["--tool", "mise", "--days", "1", "--check", "--json"],
        {"pre": [["--tool", "mise", "--days", "1", "--json"]],
         "missing": [".config/mise/config.pmsec.toml", ".config/mise/miserc.local.toml"]},
    ),
]


def env_for(home: Path, overrides: dict[str, str]) -> dict[str, str]:
    env = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "COMPOSER_HOME": str(home / ".config" / "composer"),
        "MISE_SYSTEM_CONFIG_DIR": str(home / "etc-mise"),
        "PMSEC_MISE_VERSION": "none",
    }
    for key, value in overrides.items():
        env[key] = value.replace("<HOME>", str(home))
    return env


def normalize(value, home: Path):
    if isinstance(value, str):
        return value.replace(str(home), "<HOME>")
    if isinstance(value, list):
        return [normalize(v, home) for v in value]
    if isinstance(value, dict):
        return {k: normalize(v, home) for k, v in value.items()}
    return value


def run_case(name, setup, setup_from, env_overrides, args, generated, pre=(), missing=()):
    home = Path(tempfile.mkdtemp(prefix="pmsec-gen-"))
    try:
        effective = dict(setup)
        if setup_from:
            effective.update(generated[setup_from]["expected_files"])
        for rel, body in effective.items():
            target = home / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(body.replace("<HOME>", str(home)))
        env = env_for(home, env_overrides)
        for step in pre:
            subprocess.run(
                ["node", str(REPO / "node" / "bin" / "cli.mjs"), *step],
                env=env, cwd=REPO, capture_output=True, text=True, check=True,
            )
        proc = subprocess.run(
            ["node", str(REPO / "node" / "bin" / "cli.mjs"), *args],
            env=env, cwd=REPO, capture_output=True, text=True,
        )
        out = proc.stdout[proc.stdout.index("{"):]
        files = {}
        for path in sorted(home.rglob("*")):
            if not path.is_file() or path.name.endswith(".bak"):
                continue
            files[path.relative_to(home).as_posix()] = normalize(path.read_text(), home)
        gone = [rel for rel in missing if not (home / rel).exists()]
        if len(gone) != len(missing):
            raise SystemExit(f"{name}: expected missing files were present: {sorted(set(missing) - set(gone))}")
        case = {
            "setup": effective,
            "env": env_overrides,
            "args": args,
        }
        if pre:
            case["pre"] = list(pre)
        case.update({
            "expected_exit": proc.returncode,
            "expected_json": normalize(json.loads(out), home),
            "expected_files": files,
        })
        if missing:
            case["expected_missing"] = list(missing)
        return case
    finally:
        shutil.rmtree(home, ignore_errors=True)


def main():
    generated = {}
    for name, setup, setup_from, env_overrides, args, *rest in CASES:
        case = run_case(name, setup, setup_from, env_overrides, args, generated, **(rest[0] if rest else {}))
        path = REPO / "conformance" / "cases" / f"{name}.json"
        path.write_text(json.dumps(case, indent=2) + "\n")
        generated[name] = case
        print(path.name, "exit", case["expected_exit"])


if __name__ == "__main__":
    main()