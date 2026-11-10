from __future__ import annotations

import io
import json
import os
import re
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from pmsec.cli import main  # noqa: E402


def env_for(home: Path, **overrides: str) -> dict[str, str]:
    # Hide the host pnpm/bundler by default so version-aware behavior (pnpm 11
    # default enforcement, bundler preflight warnings) doesn't depend on what's
    # installed on the test machine.
    base = {
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(home / ".config"),
        "PMSEC_PNPM_VERSION": "none",
        "PMSEC_BUNDLER_VERSION": "none",
        "PMSEC_COMPOSER_VERSION": "none",
        "PMSEC_MISE_VERSION": "none",
        "MISE_SYSTEM_CONFIG_DIR": str(home / "etc-mise"),
    }
    base.update(overrides)
    return base


def run(argv, home, platform="linux", **env_overrides):
    out, err = io.StringIO(), io.StringIO()
    code = main(argv, env=env_for(home, **env_overrides), home=home, platform=platform, out=out, err=err)
    return code, out.getvalue(), err.getvalue()


# Catches a class of formatting bug where the human-readable output
# leaks unresolved placeholders ({N}) because of a string-construction
# mistake. Walks every code path that emits a formatted line.
def test_human_output_has_no_unresolved_placeholders(tmp_path):
    scenarios = [
        ("enable", lambda h: None, ["--tool", "npm", "--days", "7"]),
        ("keep", lambda h: (h / ".npmrc").write_text("min-release-age=99\n"), ["--tool", "npm"]),
        ("upgrade", lambda h: (h / ".npmrc").write_text("min-release-age=3\n"), ["--tool", "npm", "--days", "7"]),
        ("check_fail", lambda h: None, ["--check"]),
        ("check_pass", lambda h: run([], h), ["--check"]),
        ("disable", lambda h: run(["--tool", "npm"], h), ["--disable", "--tool", "npm"]),
    ]
    for name, setup, argv in scenarios:
        h = tmp_path / name
        h.mkdir()
        setup(h)
        _, out, err = run(argv, h)
        assert not re.search(r"\{[0-9]+\}", out + err), f"{name} leaked placeholder: {out}{err}"


def test_default_invocation_writes_bundle_for_every_tool(tmp_path):
    code, _, _ = run([], tmp_path)
    assert code == 0
    npmrc = (tmp_path / ".npmrc").read_text()
    assert "min-release-age=1" in npmrc
    assert "audit-level=high" in npmrc
    assert "allow-git=none" in npmrc
    assert "allow-remote=none" in npmrc
    assert "allow-file=root" in npmrc
    assert "allow-directory=root" in npmrc
    assert "strict-allow-scripts=true" in npmrc
    assert "dangerously-allow-all-scripts=false" in npmrc
    assert "allow-scripts-pin=true" in npmrc
    assert "ignore-extension=true" in npmrc
    assert "minimum-release-age" not in npmrc, "pnpm keys must not leak into .npmrc"
    pnpmrc = (tmp_path / ".config" / "pnpm" / "rc").read_text()
    assert "minimum-release-age=1440" in pnpmrc
    assert "trust-policy=no-downgrade" in pnpmrc
    assert "block-exotic-subdeps=true" in pnpmrc
    assert "strict-dep-builds=true" in pnpmrc
    assert "verify-deps-before-run=error" in pnpmrc
    assert "minimum-release-age-strict=true" in pnpmrc
    assert "dangerously-allow-all-builds=false" in pnpmrc
    assert "trust-lockfile=false" in pnpmrc
    assert "minimum-release-age-ignore-missing-time=false" in pnpmrc
    pnpm_yaml = (tmp_path / ".config" / "pnpm" / "config.yaml").read_text()
    assert "minimumReleaseAge: 1440" in pnpm_yaml
    assert "trustPolicy: no-downgrade" in pnpm_yaml
    assert "blockExoticSubdeps: true" in pnpm_yaml
    assert "strictDepBuilds: true" in pnpm_yaml
    assert "verifyDepsBeforeRun: error" in pnpm_yaml
    assert "minimumReleaseAgeStrict: true" in pnpm_yaml
    assert "dangerouslyAllowAllBuilds: false" in pnpm_yaml
    assert "trustLockfile: false" in pnpm_yaml
    assert "minimumReleaseAgeIgnoreMissingTime: false" in pnpm_yaml
    uvtoml = (tmp_path / ".config" / "uv" / "uv.toml").read_text()
    assert 'exclude-newer = "1 days"' in uvtoml
    assert 'index-strategy = "first-index"' in uvtoml
    assert "[audit]" in uvtoml
    assert "malware-check = true" in uvtoml
    bunfig = (tmp_path / ".config" / ".bunfig.toml").read_text()
    assert "[install]" in bunfig
    assert "minimumReleaseAge = 86400" in bunfig
    assert "ignoreScripts = true" in bunfig
    yarnrc = (tmp_path / ".yarnrc.yml").read_text()
    assert "npmMinimalAgeGate: 1440" in yarnrc
    assert "enableHardenedMode: true" in yarnrc
    assert "enableScripts: false" in yarnrc
    assert "approvedGitRepositories: []" in yarnrc
    mise = (tmp_path / ".config" / "mise" / "config.toml").read_text()
    assert "[settings]" in mise
    assert 'minimum_release_age = "1d"' in mise
    assert "paranoid = true" in mise
    assert "gpg_verify = true" in mise
    assert "github_attestations = true" in mise
    assert "slsa = true" in mise
    assert "locked_verify_provenance = true" in mise
    assert "ruby.github_attestations = true" in mise
    assert "python.github_attestations = true" in mise
    assert "provenance_api_failures_fatal = true" in mise
    assert "aqua.github_attestations = true" in mise
    assert "aqua.cosign = true" in mise
    assert "aqua.minisign = true" in mise
    assert "aqua.slsa = true" in mise
    assert "github.github_attestations = true" in mise
    assert "github.slsa = true" in mise
    assert "node.gpg_verify = true" in mise
    assert "swift.gpg_verify = true" in mise
    assert "not_found_system_fallback = false" in mise
    aube = (tmp_path / ".config" / "aube" / "config.toml").read_text()
    assert "minimumReleaseAge = 1440" in aube
    assert "paranoid = true" in aube
    bundle = (tmp_path / ".bundle" / "config").read_text()
    assert 'BUNDLE_COOLDOWN: "1"' in bundle
    composer = (tmp_path / ".config" / "composer" / "config.json").read_text()
    assert '"period": "1 days"' in composer
    assert '"allow-plugins": false' in composer
    assert '"secure-http": true' in composer
    assert '"disable-tls": false' in composer
    assert '"abandoned": "fail"' in composer


def test_check_passes_after_default_enable(tmp_path):
    run([], tmp_path)
    code, _, _ = run(["--check"], tmp_path)
    assert code == 0


def test_check_fails_when_bundle_missing(tmp_path):
    code, out, _ = run(["--check"], tmp_path)
    assert code == 1
    for tool in ("npm", "pnpm", "yarn", "bun", "cargo", "mise", "uv", "bundler", "aube", "composer"):
        assert f"MISSING {tool}" in out


def test_disable_preserves_other_keys(tmp_path):
    (tmp_path / ".npmrc").write_text(
        "registry=https://r/\nmin-release-age=3\n"
    )
    pnpm_dir = tmp_path / ".config" / "pnpm"
    pnpm_dir.mkdir(parents=True)
    (pnpm_dir / "rc").write_text("minimum-release-age=4320\nstore-dir=/tmp/pstore\n")
    (pnpm_dir / "config.yaml").write_text("minimumReleaseAge: 4320\nstoreDir: /tmp/pstore\n")
    uv_dir = tmp_path / ".config" / "uv"
    uv_dir.mkdir(parents=True)
    (uv_dir / "uv.toml").write_text(
        'exclude-newer = "3 days"\nlink-mode = "copy"\n'
    )
    (tmp_path / ".config" / ".bunfig.toml").write_text(
        '[install]\nminimumReleaseAge = 259200\nregistry = "https://x/"\n'
    )
    (tmp_path / ".yarnrc.yml").write_text(
        'npmMinimalAgeGate: "3d"\nnpmRegistryServer: "https://r/"\n'
    )
    run(["--disable"], tmp_path)
    assert (tmp_path / ".npmrc").read_text() == "registry=https://r/\n"
    assert (pnpm_dir / "rc").read_text() == "store-dir=/tmp/pstore\n"
    assert (pnpm_dir / "config.yaml").read_text() == "storeDir: /tmp/pstore\n"
    assert (uv_dir / "uv.toml").read_text() == 'link-mode = "copy"\n'
    assert (tmp_path / ".config" / ".bunfig.toml").read_text() == '[install]\nregistry = "https://x/"\n'
    assert (tmp_path / ".yarnrc.yml").read_text() == 'npmRegistryServer: "https://r/"\n'


def test_enable_upgrades_weak_existing_value(tmp_path):
    (tmp_path / ".npmrc").write_text("min-release-age=3\nregistry=https://r/\n")
    run(["--tool", "npm", "--days", "7"], tmp_path)
    assert (tmp_path / ".npmrc").read_text() == (
        "min-release-age=7\nregistry=https://r/\naudit-level=high\nallow-git=none\nallow-remote=none\nallow-file=root\nallow-directory=root\nstrict-allow-scripts=true\ndangerously-allow-all-scripts=false\nallow-scripts-pin=true\nignore-extension=true\n"
    )


def test_enable_preserves_stricter_existing_cooldown(tmp_path):
    (tmp_path / ".npmrc").write_text("min-release-age=99\nregistry=https://r/\n")
    code, out, _ = run(["--tool", "npm"], tmp_path)
    assert code == 0
    assert re.search(r"^keep\s+npm\s+\[[^\]]+\]\s+\(kept existing 99d \S+ \d+d\)", out, re.M)
    assert (tmp_path / ".npmrc").read_text() == (
        "min-release-age=99\nregistry=https://r/\naudit-level=high\nallow-git=none\nallow-remote=none\nallow-file=root\nallow-directory=root\nstrict-allow-scripts=true\ndangerously-allow-all-scripts=false\nallow-scripts-pin=true\nignore-extension=true\n"
    )


def test_enable_force_overwrites_stricter_existing(tmp_path):
    (tmp_path / ".npmrc").write_text("min-release-age=99\n")
    code, _, _ = run(["--tool", "npm", "--days", "1", "--force"], tmp_path)
    assert code == 0
    text = (tmp_path / ".npmrc").read_text()
    assert "min-release-age=1" in text


def test_enable_days_upgrades_when_request_exceeds_existing(tmp_path):
    (tmp_path / ".npmrc").write_text("min-release-age=3\n")
    run(["--tool", "npm", "--days", "14"], tmp_path)
    text = (tmp_path / ".npmrc").read_text()
    assert "min-release-age=14" in text


def test_tool_filter(tmp_path):
    run(["--tool", "npm,bun"], tmp_path)
    assert (tmp_path / ".npmrc").exists()
    assert (tmp_path / ".config" / ".bunfig.toml").exists()
    assert not (tmp_path / ".config" / "uv" / "uv.toml").exists()


def test_windows_uv_path(tmp_path):
    appdata = tmp_path / "AppData" / "Roaming"
    out, err = io.StringIO(), io.StringIO()
    main(["--tool", "uv"], env={"APPDATA": str(appdata)}, home=tmp_path, platform="win32", out=out, err=err)
    assert (appdata / "uv" / "uv.toml").read_text().splitlines()[0] == 'exclude-newer = "1 days"'


def test_check_json(tmp_path):
    _, out, _ = run(["--check", "--json"], tmp_path)
    data = json.loads(out)
    assert data["ok"] is False
    assert data["bundleDays"] == 1
    assert len(data["rows"]) == 10
    assert [r["tool"] for r in data["rows"]] == ["npm", "pnpm", "yarn", "bun", "cargo", "mise", "uv", "bundler", "aube", "composer"]


def test_bun_section_insert(tmp_path):
    (tmp_path / ".config").mkdir(exist_ok=True)
    (tmp_path / ".config" / ".bunfig.toml").write_text('[install]\nregistry = "https://x/"\n')
    run(["--tool", "bun"], tmp_path)
    text = (tmp_path / ".config" / ".bunfig.toml").read_text()
    assert text.startswith("[install]\nignoreScripts = true\nminimumReleaseAge = 86400\nregistry =")


def test_bun_creates_section_if_missing(tmp_path):
    (tmp_path / ".config").mkdir(exist_ok=True)
    (tmp_path / ".config" / ".bunfig.toml").write_text("telemetry = false\n")
    run(["--tool", "bun"], tmp_path)
    text = (tmp_path / ".config" / ".bunfig.toml").read_text()
    assert text == "telemetry = false\n\n[install]\nignoreScripts = true\nminimumReleaseAge = 86400\n"


def test_yarn_check_parses_days(tmp_path):
    (tmp_path / ".yarnrc.yml").write_text(
        'npmMinimalAgeGate: "14d"\nenableHardenedMode: true\nenableScripts: false\napprovedGitRepositories: []\n'
    )
    _, out, _ = run(["--check", "--json", "--tool", "yarn"], tmp_path)
    data = json.loads(out)
    assert data["ok"] is True
    assert data["rows"][0]["days"] == 14


def test_bundler_enable_preserves_unrelated_keys(tmp_path):
    bundle_dir = tmp_path / ".bundle"
    bundle_dir.mkdir()
    (bundle_dir / "config").write_text('---\nBUNDLE_PATH: "vendor/bundle"\n')
    run(["--tool", "bundler", "--days", "7"], tmp_path)
    text = (bundle_dir / "config").read_text()
    assert 'BUNDLE_COOLDOWN: "7"' in text
    assert 'BUNDLE_PATH: "vendor/bundle"' in text


def test_bundler_check_parses_days(tmp_path):
    bundle_dir = tmp_path / ".bundle"
    bundle_dir.mkdir()
    (bundle_dir / "config").write_text('---\nBUNDLE_COOLDOWN: "14"\n')
    _, out, _ = run(["--check", "--json", "--tool", "bundler"], tmp_path)
    data = json.loads(out)
    assert data["ok"] is True
    assert data["rows"][0]["days"] == 14


def test_bundler_user_config_override(tmp_path):
    cfg = tmp_path / "custom-bundle-config"
    run(["--tool", "bundler"], tmp_path, BUNDLE_USER_CONFIG=str(cfg))
    assert 'BUNDLE_COOLDOWN: "1"' in cfg.read_text()


def test_pnpm_check_normalizes_minutes(tmp_path):
    pnpm_dir = tmp_path / ".config" / "pnpm"
    pnpm_dir.mkdir(parents=True)
    (pnpm_dir / "rc").write_text("minimum-release-age=20160\n")
    _, out, _ = run(["--check", "--json", "--tool", "pnpm"], tmp_path, PMSEC_PNPM_VERSION="10.26.0")
    data = json.loads(out)
    assert data["rows"][0]["days"] == 14


def test_bak_created_once(tmp_path):
    (tmp_path / ".npmrc").write_text("registry=https://original/\n")
    run(["--tool", "npm"], tmp_path)
    run(["--disable", "--tool", "npm"], tmp_path)
    run(["--tool", "npm"], tmp_path)
    assert (tmp_path / ".npmrc.bak").read_text() == "registry=https://original/\n"


def test_hardening_extras_roundtrip(tmp_path):
    pnpm_dir = tmp_path / ".config" / "pnpm"
    pnpm_dir.mkdir(parents=True)
    pnpmrc = pnpm_dir / "rc"
    pnpmrc.write_text("minimum-release-age=20160\n")
    code, out, _ = run(["--check", "--json", "--tool", "pnpm"], tmp_path)
    data = json.loads(out)
    assert code == 1
    assert len(data["rows"][0]["extras"]) == 8
    assert all(not e["ok"] for e in data["rows"][0]["extras"])

    run(["--tool", "pnpm"], tmp_path)
    text = pnpmrc.read_text()
    assert "trust-policy=no-downgrade" in text
    assert "block-exotic-subdeps=true" in text
    assert "strict-dep-builds=true" in text
    assert "verify-deps-before-run=error" in text
    assert "minimum-release-age-strict=true" in text

    code, out, _ = run(["--check", "--json", "--tool", "pnpm"], tmp_path)
    assert code == 0
    assert json.loads(out)["ok"] is True

    run(["--disable", "--tool", "pnpm"], tmp_path)
    after = pnpmrc.read_text()
    assert "trust-policy" not in after
    assert "block-exotic-subdeps" not in after
    assert "strict-dep-builds" not in after
    assert "verify-deps-before-run" not in after
    assert "minimum-release-age" not in after


def test_pnpm_11_reads_config_yaml_and_default_enforces_block_exotic_subdeps(tmp_path):
    # Cooldown present in YAML, but extras lines absent. Under pnpm 11 the
    # runtime still blocks exotic subdeps by default, so check must report it as
    # OK rather than MISSING (trustPolicy stays MISSING — no default change).
    pnpm_dir = tmp_path / ".config" / "pnpm"
    pnpm_dir.mkdir(parents=True)
    (pnpm_dir / "config.yaml").write_text("minimumReleaseAge: 4320\n")
    code, out, _ = run(["--check", "--json", "--tool", "pnpm"], tmp_path, PMSEC_PNPM_VERSION="11.0.0")
    data = json.loads(out)
    assert data["rows"][0]["key"] == "minimumReleaseAge"
    assert data["rows"][0]["path"] == str(pnpm_dir / "config.yaml")
    assert data["rows"][0]["days"] == 3
    extras = {e["key"]: e for e in data["rows"][0]["extras"]}
    assert extras["blockExoticSubdeps"]["ok"] is True
    assert extras["blockExoticSubdeps"]["defaultEnforced"] is True
    assert extras["blockExoticSubdeps"]["configured"] is None
    assert extras["trustPolicy"]["ok"] is False
    assert code == 1


def test_pnpm_11_check_ignores_legacy_rc_values(tmp_path):
    pnpm_dir = tmp_path / ".config" / "pnpm"
    pnpm_dir.mkdir(parents=True)
    (pnpm_dir / "rc").write_text("minimum-release-age=10080\ntrust-policy=no-downgrade\n")
    code, out, _ = run(["--check", "--json", "--tool", "pnpm"], tmp_path, PMSEC_PNPM_VERSION="11.28.5")
    data = json.loads(out)
    assert code == 1
    assert data["rows"][0]["configured"] is None
    assert data["rows"][0]["path"] == str(pnpm_dir / "config.yaml")


def test_pnpm_pre11_still_flags_block_exotic_subdeps(tmp_path):
    pnpm_dir = tmp_path / ".config" / "pnpm"
    pnpm_dir.mkdir(parents=True)
    (pnpm_dir / "rc").write_text("minimum-release-age=4320\n")
    _, out, _ = run(["--check", "--json", "--tool", "pnpm"], tmp_path, PMSEC_PNPM_VERSION="10.26.0")
    extras = {e["key"]: e for e in json.loads(out)["rows"][0]["extras"]}
    assert extras["block-exotic-subdeps"]["ok"] is False
    assert extras["block-exotic-subdeps"].get("defaultEnforced", False) is False


def test_days_flag_overrides_bundle_cooldown(tmp_path):
    code, _, _ = run(["--days", "7"], tmp_path)
    assert code == 0
    npmrc = (tmp_path / ".npmrc").read_text()
    assert "min-release-age=7" in npmrc
    pnpmrc = (tmp_path / ".config" / "pnpm" / "rc").read_text()
    assert "minimum-release-age=10080" in pnpmrc
    assert "minimumReleaseAge: 10080" in (tmp_path / ".config" / "pnpm" / "config.yaml").read_text()
    assert 'exclude-newer = "7 days"' in (tmp_path / ".config" / "uv" / "uv.toml").read_text()
    assert "minimumReleaseAge = 604800" in (tmp_path / ".config" / ".bunfig.toml").read_text()
    assert "minimumReleaseAge = 10080" in (tmp_path / ".config" / "aube" / "config.toml").read_text()

    code, out, _ = run(["--check", "--json", "--days", "7"], tmp_path)
    assert code == 0
    assert json.loads(out)["bundleDays"] == 7

    code, _, _ = run(["--check"], tmp_path)
    assert code == 0

    code, _, _ = run(["--check", "--days", "30"], tmp_path)
    assert code == 1


@pytest.mark.parametrize("bad", ["0", "-1", "abc"])
def test_days_rejects_invalid(tmp_path, bad):
    with pytest.raises(SystemExit) as exc:
        run(["--days", bad], tmp_path)
    assert exc.value.code == 2


def test_check_disable_mutually_exclusive(tmp_path):
    with pytest.raises(SystemExit) as exc:
        run(["--check", "--disable"], tmp_path)
    assert exc.value.code == 2


@pytest.mark.parametrize("flag", ["--version", "-V"])
def test_version_flag_prints_package_version(tmp_path, capsys, flag):
    from pmsec import __version__
    with pytest.raises(SystemExit) as exc:
        run([flag], tmp_path)
    assert exc.value.code == 0
    captured = capsys.readouterr()
    assert captured.out.strip() == f"pmsec {__version__}"


def test_doctor_json_reports_per_tool_writability(tmp_path):
    code, out, _ = run(["--doctor", "--json"], tmp_path)
    data = json.loads(out)
    assert data["doctor"] is True
    assert data["ok"] is True
    assert code == 0
    # All eight tools surfaced in stable order with the writability quintet.
    tools = [t["tool"] for t in data["tools"]]
    assert tools == ["npm", "pnpm", "yarn", "bun", "cargo", "mise", "uv", "bundler", "aube", "composer"]
    for t in data["tools"]:
        for key in ("path", "parent", "exists", "writable", "parentExists", "parentWritable", "owner"):
            assert key in t, f"{t['tool']} missing {key}"
        assert t["parentWritable"] is True, f"{t['tool']} parent should be writable in fresh tmp_path"
    assert data["pmsecHomeSource"] == "HOME"


@pytest.mark.skipif(
    sys.platform == "win32" or (hasattr(os, "geteuid") and os.geteuid() == 0),
    reason="POSIX permission semantics; Windows and root bypass chmod for non-execute bits",
)
def test_doctor_blocks_when_parent_not_writable(tmp_path):
    blocked = tmp_path / "ro" / ".npmrc"
    blocked.parent.mkdir()
    # Drop write permission on the parent dir; doctor must report BLOCK.
    blocked.parent.chmod(0o500)
    try:
        code, out, _ = run(["--doctor", "--json", "--tool", "npm"],
                           tmp_path / "ro", NPM_CONFIG_USERCONFIG=str(blocked))
        data = json.loads(out)
        assert data["ok"] is False
        assert code == 1
        assert data["tools"][0]["parentWritable"] is False
    finally:
        blocked.parent.chmod(0o700)


@pytest.mark.skipif(
    sys.platform == "win32" or (hasattr(os, "geteuid") and os.geteuid() == 0),
    reason="POSIX permission semantics; Windows and root bypass chmod for non-execute bits",
)
def test_explain_fs_error_emits_chown_hint_for_permission_denied(tmp_path):
    # Make ~/.npmrc unwritable (owned by root would be ideal but we can't
    # sudo in tests). Setting the file readonly + parent dir readonly
    # produces PermissionError during atomic rename, which the explainer
    # should turn into a chown hint.
    (tmp_path / ".npmrc").write_text("registry=https://r/\n")
    (tmp_path / ".npmrc").chmod(0o400)
    (tmp_path).chmod(0o500)
    try:
        code, _, err = run(["--tool", "npm"], tmp_path)
        assert code == 1
        assert "Check file ownership" in err or "PermissionError" in err
    finally:
        (tmp_path).chmod(0o700)
        (tmp_path / ".npmrc").chmod(0o600)


def test_cargo_enable_writes_global_min_publish_age(tmp_path):
    cargo_home = tmp_path / "cargo"
    env = {"CARGO_HOME": str(cargo_home)}
    run(["--tool", "cargo", "--days", "7"], tmp_path, **env)
    cfg = (cargo_home / "config.toml").read_text()
    assert '[registry]\nglobal-min-publish-age = "7 days"' in cfg
    assert "minimum-release-age" not in cfg
    code, out, _ = run(["--check", "--tool", "cargo", "--days", "7", "--json"], tmp_path, **env)
    assert code == 0
    row = json.loads(out)["rows"][0]
    assert row["key"] == "global-min-publish-age"
    assert row["configured"] == '"7 days"'
    assert row["days"] == 7
    assert row["extras"] == []
    (cargo_home / "config.toml").write_text('[registry]\nglobal-min-publish-age = "1 days"\n')
    code, _, _ = run(["--check", "--tool", "cargo", "--days", "7"], tmp_path, **env)
    assert code == 1
    (cargo_home / "config.toml").write_text('[registry]\nglobal-min-publish-age = "2 weeks"\n')
    code, _, _ = run(["--check", "--tool", "cargo", "--days", "7"], tmp_path, **env)
    assert code == 0
    (cargo_home / "config.toml").write_text('[install]\nminimum-release-age = "7d"\n[registry]\nglobal-min-publish-age = "1 days"\n')
    run(["--disable", "--tool", "cargo"], tmp_path, **env)
    assert (cargo_home / "config.toml").read_text() == "[install]\n[registry]\n"


def test_composer_roundtrip(tmp_path):
    code, _, _ = run(["--tool", "composer", "--days", "7"], tmp_path)
    assert code == 0
    cfg_path = tmp_path / ".config" / "composer" / "config.json"
    cfg = json.loads(cfg_path.read_text())
    assert cfg["config"]["policy"]["cooldown"]["period"] == "7 days"
    assert "minimum-release-age" not in cfg["config"]
    assert cfg["config"]["allow-plugins"] is False
    assert cfg["config"]["secure-http"] is True
    assert cfg["config"]["disable-tls"] is False
    assert cfg["config"]["audit"]["abandoned"] == "fail"
    code, out, _ = run(["--check", "--json", "--tool", "composer", "--days", "7"], tmp_path)
    assert code == 0
    assert json.loads(out)["rows"][0]["days"] == 7
    run(["--disable", "--tool", "composer"], tmp_path)
    code, out, _ = run(["--check", "--tool", "composer"], tmp_path)
    assert code == 1
    assert "MISSING composer" in out


def test_composer_preserves_unrelated_keys_and_honors_home(tmp_path):
    composer_home = tmp_path / "composer-home"
    composer_home.mkdir()
    cfg_path = composer_home / "config.json"
    cfg_path.write_text(
        '{\n  "config": {\n    "preferred-install": "dist",\n'
        '    "audit": {\n      "ignore": ["vendor/pkg"]\n    }\n  },\n'
        '  "repositories": {\n    "packagist": false\n  }\n}\n'
    )
    run(["--tool", "composer"], tmp_path, COMPOSER_HOME=str(composer_home))
    cfg = json.loads(cfg_path.read_text())
    assert cfg["config"]["preferred-install"] == "dist"
    assert cfg["config"]["audit"]["ignore"] == ["vendor/pkg"]
    assert cfg["repositories"]["packagist"] is False
    run(["--disable", "--tool", "composer"], tmp_path, COMPOSER_HOME=str(composer_home))
    cfg = json.loads(cfg_path.read_text())
    assert cfg["config"]["preferred-install"] == "dist"
    assert cfg["config"]["audit"]["ignore"] == ["vendor/pkg"]
    assert cfg["repositories"]["packagist"] is False


def test_non_numeric_npm_cooldown_fails_check_and_is_replaced(tmp_path):
    home = tmp_path
    (home / ".npmrc").write_text("min-release-age=abc\n")
    code, out, _ = run(["--check", "--tool", "npm", "--json"], home)
    report = json.loads(out)
    assert report["rows"][0]["days"] is None
    assert report["ok"] is False
    assert code == 1
    run(["--tool", "npm"], home)
    assert re.search(r"^min-release-age=1$", (home / ".npmrc").read_text(), re.M)


def test_symlink_at_bak_path_is_refused(tmp_path):
    home = tmp_path
    (home / ".npmrc").write_text("registry=https://original/\n")
    os.symlink("/nonexistent-target", home / ".npmrc.bak")
    code, _, err = run(["--tool", "npm"], home)
    assert code != 0
    assert "refusing to write backup through symlink" in err
    assert (home / ".npmrc").read_text() == "registry=https://original/\n"


def test_doctor_never_claims_pmsec_home_support(tmp_path):
    code, out, err = run(["--doctor", "--json"], tmp_path, PMSEC_HOME="/elsewhere")
    report = json.loads(out)
    assert report["pmsecHome"] is None
    assert report["pmsecHomeSource"] == "HOME"
    assert "PMSEC_HOME is ignored" in err


def test_mise_new_mode_keeps_win32_config_under_dot_config(tmp_path):
    local = tmp_path / "AppData" / "Local"
    code, out, _ = run(["--doctor", "--json", "--tool", "mise"], tmp_path, "win32",
                       PMSEC_MISE_VERSION="2026.11.0", LOCALAPPDATA=str(local))
    assert code == 0
    row = json.loads(out)["tools"][0]
    assert row["path"] == str(tmp_path / ".config" / "mise" / "config.pmsec.toml")
    assert row["extraPaths"] == [
        str(local / "mise" / "config.toml"),
        str(tmp_path / ".config" / "mise" / "miserc.local.toml"),
    ]


def test_mise_legacy_win32_mode_uses_localappdata(tmp_path):
    local = tmp_path / "AppData" / "Local"
    _, out, _ = run(["--doctor", "--json", "--tool", "mise"], tmp_path, "win32",
                    PMSEC_MISE_VERSION="2026.10.25", LOCALAPPDATA=str(local))
    assert json.loads(out)["tools"][0]["path"] == str(local / "mise" / "config.toml")


def test_mise_new_mode_honors_xdg_and_config_dir(tmp_path):
    xdg = tmp_path / "xdg"
    _, out, _ = run(["--doctor", "--json", "--tool", "mise"], tmp_path, "linux",
                    PMSEC_MISE_VERSION="2026.11.0", XDG_CONFIG_HOME=str(xdg))
    assert json.loads(out)["tools"][0]["path"] == str(xdg / "mise" / "config.pmsec.toml")
    custom = tmp_path / "mise-custom"
    _, out, _ = run(["--doctor", "--json", "--tool", "mise"], tmp_path, "linux",
                    PMSEC_MISE_VERSION="2026.11.0", XDG_CONFIG_HOME=str(xdg),
                    MISE_CONFIG_DIR=str(custom))
    assert json.loads(out)["tools"][0]["path"] == str(custom / "config.pmsec.toml")


def test_disable_reports_malformed_selector(tmp_path):
    (tmp_path / ".config" / "mise").mkdir(parents=True)
    (tmp_path / ".config" / "mise" / "miserc.local.toml").write_text("env = [1]\n")
    code, out, err = run(["--disable", "--tool", "mise", "--json"], tmp_path)
    data = json.loads(out)
    assert code != 0
    assert data["ok"] is False
    assert data["results"][0]["ok"] is False
    assert "miserc env may only contain string names" in data["results"][0]["error"]


def _casefold_root() -> Path | None:
    """A case-insensitive directory: the default tmpdir on Windows/macOS, or
    PMSEC_TEST_CASEFOLD_DIR (e.g. a vfat mount) elsewhere."""
    import tempfile
    root = Path(os.environ.get("PMSEC_TEST_CASEFOLD_DIR") or tempfile.gettempdir())
    try:
        d = Path(tempfile.mkdtemp(prefix="pmsec-case-", dir=root))
        (d / "probe").write_text("")
        yes = (d / "PROBE").exists()
        (d / "probe").unlink()
        d.rmdir()
        return root if yes else None
    except OSError:
        return None


@pytest.mark.skipif(_casefold_root() is None, reason="needs a case-insensitive filesystem")
def test_mise_reverse_migration_keeps_case_variant_global_alias():
    import shutil
    import tempfile
    home = Path(tempfile.mkdtemp(prefix="pmsec-", dir=_casefold_root()))
    try:
        d = home / ".config" / "mise"
        d.mkdir(parents=True)
        (d / "config.pmsec.toml").write_text('[settings]\nminimum_release_age = "3d"\n')
        (d / "miserc.local.toml").write_text('env = ["pmsec"]\n')
        env = {"PMSEC_MISE_VERSION": "2026.10.25", "MISE_GLOBAL_CONFIG_FILE": str(d / "Config.Pmsec.toml")}
        code, _, _ = run(["--tool", "mise", "--days", "1"], home, **env)
        assert code == 0
        assert re.search(r'^minimum_release_age = "3d"$', (d / "config.pmsec.toml").read_text(), re.M)
        assert not (d / "miserc.local.toml").exists()
        assert run(["--tool", "mise", "--check"], home, **env)[0] == 0
    finally:
        shutil.rmtree(home, ignore_errors=True)


def test_mise_reverse_migration_keeps_global_alias_through_linked_config_dir(tmp_path):
    real = tmp_path / "real"
    real.mkdir()
    try:
        os.symlink(real, tmp_path / "link", target_is_directory=True)
    except OSError as e:
        pytest.skip(f"cannot create a directory symlink: {e}")
    (real / "config.pmsec.toml").write_text('[settings]\nminimum_release_age = "3d"\n')
    (real / "miserc.local.toml").write_text('env = ["pmsec"]\n')
    env = {
        "PMSEC_MISE_VERSION": "2026.10.25",
        "MISE_CONFIG_DIR": str(tmp_path / "link"),
        "MISE_GLOBAL_CONFIG_FILE": str(real / "config.pmsec.toml"),
    }
    assert run(["--tool", "mise", "--days", "1"], tmp_path, **env)[0] == 0
    assert re.search(r'^minimum_release_age = "3d"$', (real / "config.pmsec.toml").read_text(), re.M)
    assert not (real / "miserc.local.toml").exists()
    assert run(["--tool", "mise", "--check"], tmp_path, **env)[0] == 0


def test_mise_legacy_migration_follows_config_dir(tmp_path):
    custom = tmp_path / "mise-custom"
    run(["--tool", "mise", "--days", "1"], tmp_path, PMSEC_MISE_VERSION="2026.11.0",
        MISE_CONFIG_DIR=str(custom))
    assert 'minimum_release_age = "1d"' in (custom / "config.pmsec.toml").read_text()
    # A downgrade must migrate into the config dir mise actually reads.
    run(["--tool", "mise", "--days", "1"], tmp_path, PMSEC_MISE_VERSION="2026.10.25",
        MISE_CONFIG_DIR=str(custom))
    assert 'minimum_release_age = "1d"' in (custom / "config.toml").read_text()
    assert not (custom / "config.pmsec.toml").exists()
    assert not (tmp_path / ".config" / "mise" / "config.toml").exists()


def test_win32_system_miserc_sits_under_drive_root():
    from pmsec.util.paths import mise_system_miserc_path
    assert mise_system_miserc_path({"MISE_SYSTEM_CONFIG_DIR": "D:/mise-etc"}, Path("C:/Users/me"), "win32") == Path("D:/mise-etc/miserc.toml")
    if os.name == "nt":
        assert mise_system_miserc_path({}, Path("C:/Users/me"), "win32") == Path("C:/etc/mise/miserc.toml")
