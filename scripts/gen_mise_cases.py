#!/usr/bin/env python3
"""Generate mise new-mode conformance cases from the node port's output.

Run once while adding cases: `python3 scripts/gen_mise_cases.py`. The generated
JSON files under conformance/cases/ are the committed contract; this script is
a convenience so the expected bytes come from a running implementation instead
of being hand-copied.

Scope note: recording node's output as the expectation proves byte-parity
across the four ports, not that mise itself loads the selected layer — that
contract rests on mise's documented config.pmsec.toml/miserc behavior and
would need a real-mise integration check outside this harness.
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
DQ = '"'
SQ = "'"

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
        "check_mise_new_mode_mise_env_pmsec_not_last",
        {},
        "enable_mise_new_mode_fresh",
        {**NEW_MODE, "MISE_ENV": "pmsec,work"},
        ["--tool", "mise", "--days", "1", "--check", "--json"],
    ),
    (
        "check_mise_new_mode_mise_env_spaced_pmsec",
        {},
        "enable_mise_new_mode_fresh",
        {**NEW_MODE, "MISE_ENV": "work, pmsec"},
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
        "check_mise_legacy_residual_pmsec_file",
        {".config/mise/config.pmsec.toml": '[settings]\nexperimental = true\n'},
        None,
        {"PMSEC_MISE_VERSION": "2026.10.25"},
        ["--tool", "mise", "--days", "1", "--check", "--json"],
        {"pre": [["--tool", "mise", "--days", "1", "--json"]]},
    ),
    (
        "enable_mise_legacy_residual_pmsec_file",
        {
            ".config/mise/config.toml": '[settings]\nminimum_release_age = "7d"\n',
            ".config/mise/config.pmsec.toml": '[settings]\nexperimental = true\n',
        },
        None,
        {"PMSEC_MISE_VERSION": "2026.10.25"},
        ["--tool", "mise", "--days", "1", "--json"],
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
        {"missing": [".config/mise/config.pmsec.toml", ".config/mise/miserc.local.toml"]},
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
        {"missing": ["mise-custom/config.pmsec.toml", "mise-custom/miserc.local.toml"]},
    ),
    (
        "enable_mise_reverse_migration_aliased_global",
        {"mise-custom/config.pmsec.toml": '[settings]\nminimum_release_age = "3d"\n'},
        None,
        {
            "PMSEC_MISE_VERSION": "2026.10.25",
            "MISE_CONFIG_DIR": "<HOME>/mise-custom",
            "MISE_GLOBAL_CONFIG_FILE": "<HOME>/mise-custom/config.pmsec.toml",
        },
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "check_mise_legacy_aliased_global_after_migration",
        {
            "mise-custom/config.pmsec.toml": '[settings]\nminimum_release_age = "3d"\n',
            "mise-custom/miserc.local.toml": 'env = ["pmsec"]\n',
        },
        None,
        {
            "PMSEC_MISE_VERSION": "2026.10.25",
            "MISE_CONFIG_DIR": "<HOME>/mise-custom",
            "MISE_GLOBAL_CONFIG_FILE": "<HOME>/mise-custom/config.pmsec.toml",
        },
        ["--tool", "mise", "--days", "1", "--check", "--json"],
        {"pre": [["--tool", "mise", "--days", "1", "--json"]],
         "missing": ["mise-custom/miserc.local.toml"]},
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
        {"missing": [".config/mise/config.pmsec.toml", ".config/mise/miserc.local.toml"]},
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
        "enable_mise_new_mode_escaped_env",
        {".config/mise/miserc.local.toml": 'env = ["\\u0077ork"]\nkept = 1\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_quoted_env_key",
        {".config/mise/miserc.local.toml": '"env" = ["work"]\nother = 1\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_selector_missing_comma",
        {".config/mise/miserc.local.toml": 'env = ["pmsec" "work"]\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
        {"missing": [".config/mise/config.pmsec.toml"]},
    ),
    (
        "enable_mise_selector_leading_comma",
        {".config/mise/miserc.local.toml": 'env = [, "work"]\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
        {"missing": [".config/mise/config.pmsec.toml"]},
    ),
    (
        "enable_mise_new_mode_env_layer_preservation",
        {
            ".config/mise/miserc.local.toml": 'env = ["work"]\n',
            ".config/mise/config.work.toml": '[settings]\nminimum_release_age = "30d"\n',
        },
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_mise_env_keeps_inherited_layer",
        {
            ".config/mise/miserc.local.toml": 'env = ["work"]\n',
            ".config/mise/config.work.toml": '[settings]\nminimum_release_age = "30d"\n',
        },
        None,
        {**NEW_MODE, "MISE_ENV": "pmsec"},
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_mise_env_unsafe_inherited_name",
        {".config/mise/miserc.local.toml": 'env = ["work.dev"]\n'},
        None,
        {**NEW_MODE, "MISE_ENV": "pmsec"},
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "check_mise_legacy_shadowed_selector",
        {
            ".config/mise/miserc.local.toml": 'env = ["work"]\n',
            ".config/mise/miserc.toml": 'env = ["pmsec"]\n',
        },
        None,
        {"PMSEC_MISE_VERSION": "2026.10.25"},
        ["--tool", "mise", "--days", "1", "--check", "--json"],
        {"pre": [["--tool", "mise", "--days", "1", "--json"]]},
    ),
    (
        "disable_mise_miserc_without_env",
        {".config/mise/miserc.local.toml": "other = 1\n"},
        None,
        {"PMSEC_MISE_VERSION": "2026.10.25"},
        ["--tool", "mise", "--disable", "--json"],
        {"pre": [["--tool", "mise", "--days", "1", "--json"]]},
    ),
    (
        "enable_mise_legacy_empty_config_dir",
        {},
        None,
        {"PMSEC_MISE_VERSION": "2026.10.25", "MISE_CONFIG_DIR": "", "MISE_GLOBAL_CONFIG_FILE": ""},
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "check_mise_new_mode_uppercase_env_key",
        {".config/mise/miserc.local.toml": 'ENV = ["pmsec"]\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--check", "--json"],
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
    # A nonempty MISE_ENV replaces the miserc list entirely: a pmsec name in
    # the variable is an active artifact even when every miserc is clean, and
    # a foreign name hides the persistent selector from legacy artifact
    # detection (and from cleanup, which must not delete what this shell
    # cannot see).
    (
        "check_mise_legacy_mise_env_selects_pmsec",
        {".config/mise/config.pmsec.toml": '[settings]\nminimum_release_age = "3d"\n'},
        None,
        {"PMSEC_MISE_VERSION": "2026.10.25", "MISE_ENV": "pmsec"},
        ["--tool", "mise", "--days", "1", "--check", "--json"],
    ),
    (
        "enable_mise_legacy_mise_env_keeps_selector",
        {
            ".config/mise/config.pmsec.toml": '[settings]\nminimum_release_age = "3d"\n',
            ".config/mise/miserc.local.toml": 'env = ["pmsec"]\n',
        },
        None,
        {"PMSEC_MISE_VERSION": "2026.10.25", "MISE_ENV": "work"},
        ["--tool", "mise", "--days", "1", "--json"],
        # The foreign MISE_ENV hides the selector from this shell, so the
        # miserc keeps its pmsec name — but the pmsec FILE's managed keys are
        # still removed and the emptied file deleted.
        {"missing": [".config/mise/config.pmsec.toml"]},
    ),
    # The effective selector may live in a shared/system miserc the cleanup
    # must not rewrite: the cleaned list is materialized into the local file
    # so the next check converges without touching the foreign file.
    (
        "enable_mise_legacy_shared_selector_materialized",
        {
            ".config/mise/miserc.toml": 'env = ["work", "pmsec"]\nkept = true\n',
            ".config/mise/config.pmsec.toml": '[settings]\nminimum_release_age = "3d"\n',
        },
        None,
        {"PMSEC_MISE_VERSION": "2026.10.25"},
        ["--tool", "mise", "--days", "1", "--json"],
        {"missing": [".config/mise/config.pmsec.toml"]},
    ),
    (
        "check_mise_legacy_shared_selector_converged",
        {},
        "enable_mise_legacy_shared_selector_materialized",
        {"PMSEC_MISE_VERSION": "2026.10.25"},
        ["--tool", "mise", "--days", "1", "--check", "--json"],
    ),
    # Same materialization with a nonempty local file that defines no env:
    # the env indices used for the rewrite must describe the freshly parsed
    # local buffer, not the shared one, or unrelated local lines are spliced
    # out.
    (
        "enable_mise_legacy_shared_selector_materialized_keeps_local",
        {
            ".config/mise/miserc.toml": 'env = ["work", "pmsec"]\n',
            ".config/mise/miserc.local.toml": "other = 1\n",
            ".config/mise/config.pmsec.toml": '[settings]\nminimum_release_age = "3d"\n',
        },
        None,
        {"PMSEC_MISE_VERSION": "2026.10.25"},
        ["--tool", "mise", "--days", "1", "--json"],
        {"missing": [".config/mise/config.pmsec.toml"]},
    ),
    # Delimiters inside a comment or a single-line string are not structural:
    # neither may open a multi-line string that hides the real selector or the
    # sections after it.
    (
        "enable_mise_new_mode_comment_triple_quote",
        {".config/mise/miserc.local.toml": '# uses """\nenv = ["work"]\nother = 1\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_trailing_comment_triple_quote",
        {".config/mise/miserc.local.toml": 'env = ["work"] # uses """\n[settings]\nminimum_release_age = "7d"\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_string_delim_triple_quote",
        {".config/mise/miserc.local.toml": "note = \"it's '''\"\nenv = [\"work\"]\nother = 1\n"},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    # A double-quoted key carrying escapes decodes to the bare spelling, so
    # migration replaces the existing assignment instead of adding a duplicate
    # env key.
    (
        "enable_mise_new_mode_escaped_env_key",
        {".config/mise/miserc.local.toml": '"e\\u006ev" = ["work"]\nother = 1\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    # Serializer round-trip: a control character that slipped into an env name
    # (hand-edited file) must come back escaped, not as a raw byte that makes
    # the whole miserc unparseable.
    (
        "disable_mise_env_control_char_roundtrip",
        {".config/mise/miserc.local.toml": "env = [\"a\u0007x\", \"pmsec\"]\nother = 1\n"},
        None,
        {"PMSEC_MISE_VERSION": "2026.10.25"},
        ["--tool", "mise", "--disable", "--json"],
    ),
    # Dots are safe in one path component: config.work.dev.toml is a real
    # mise layer, so its stricter cooldown must be preserved, while a name
    # with a path separator must fail the enable instead of being skipped.
    (
        "enable_mise_new_mode_dotted_env_layer_preservation",
        {
            ".config/mise/miserc.local.toml": 'env = ["work.dev"]\n',
            ".config/mise/config.work.dev.toml": '[settings]\nminimum_release_age = "30d"\n',
        },
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_separator_env_name_fails",
        {".config/mise/miserc.local.toml": 'env = ["work"]\n'},
        None,
        {**NEW_MODE, "MISE_ENV": "work/prod"},
        ["--tool", "mise", "--days", "1", "--json"],
        # The enable fails before writing anything: no half-migrated pair.
        {"missing": [".config/mise/config.pmsec.toml"]},
    ),
    # Removing a local pmsec name can expose a shared/system selector that
    # still selects pmsec; the cleanup must re-resolve and materialize the
    # cleaned list locally (env = [] when nothing but pmsec remains), or the
    # next legacy check would re-enable.
    (
        "enable_mise_legacy_local_removal_exposes_shared",
        {
            ".config/mise/miserc.toml": 'env = ["pmsec"]\n',
            ".config/mise/miserc.local.toml": 'env = ["pmsec"]\n',
            ".config/mise/config.pmsec.toml": '[settings]\nminimum_release_age = "3d"\n',
        },
        None,
        {"PMSEC_MISE_VERSION": "2026.10.25"},
        ["--tool", "mise", "--days", "1", "--json"],
        {"missing": [".config/mise/config.pmsec.toml"]},
    ),
    (
        "check_mise_legacy_local_removal_exposes_shared_converged",
        {},
        "enable_mise_legacy_local_removal_exposes_shared",
        {"PMSEC_MISE_VERSION": "2026.10.25"},
        ["--tool", "mise", "--days", "1", "--check", "--json"],
    ),
    # A multiline basic/literal string is one array value: `env = ["""w"""]`
    # is valid TOML, and enable rewrites the decoded names back as plain
    # single-line strings.
    (
        "enable_mise_new_mode_multiline_basic_env",
        {".config/mise/miserc.local.toml": 'env = ["""pmsec""", """work"""]\nother = 1\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    (
        "enable_mise_new_mode_multiline_literal_env",
        {".config/mise/miserc.local.toml": "env = ['''work''']\nother = 1\n"},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    # TOML allows one or two content quotes immediately before a multiline
    # closing delimiter. Disable must therefore preserve the decoded names
    # while removing only the real pmsec selector.
    (
        "disable_mise_new_mode_multiline_closing_quotes",
        {
            ".config/mise/config.pmsec.toml": '[settings]\nminimum_release_age = "3d"\nparanoid = true\nexperimental = true\n',
            ".config/mise/miserc.local.toml": (
                'env = ["""basic-one' + DQ * 4 + ', """basic-two' + DQ * 5
                + ", '''literal-one" + SQ * 4 + ", '''literal-two" + SQ * 5
                + ', "pmsec"]\nother = 1\n'
            ),
        },
        None,
        NEW_MODE,
        ["--disable", "--tool", "mise", "--json"],
    ),
    # An escaped delimiter inside a multiline basic string (`\"""`) does not
    # close it: the env line below stays inside the string body and is not a
    # real selector, so enable starts fresh instead of migrating "work".
    (
        "enable_mise_new_mode_multiline_escaped_delim_hides_env",
        {".config/mise/miserc.local.toml": 'note = """say \\"""\nenv = ["work"]\n"""\nother = 1\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
    ),
    # A line-ending backslash inside a multiline basic string trims the
    # newline and the following whitespace, so a selector can span lines
    # without embedding a newline in the name. (A name that does embed a
    # newline is refused as unsafe; its message rendering differs per port,
    # so that refusal is pinned by unit tests instead of a shared fixture.)
    (
        "enable_mise_new_mode_multiline_env_line_ending_backslash",
        {".config/mise/miserc.local.toml": 'env = [\n  """\\\n  work""",\n]\n'},
        None,
        NEW_MODE,
        ["--tool", "mise", "--days", "1", "--json"],
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