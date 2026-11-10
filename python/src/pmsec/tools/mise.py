from __future__ import annotations

import os
import re
from pathlib import Path

from pmsec.util.context import Context
from pmsec.util.extras import apply_extras, read_extras, remove_extras
from pmsec.util.io import write_atomic
from pmsec.util.lines import read_key, remove_key, set_key
from pmsec.util.miseconf import env_list_from, parse_env, remove_env_value, set_env_values
from pmsec.util.paths import (
    mise_base_config_path,
    mise_config_dir,
    mise_config_path,
    mise_env_config_path,
    mise_local_miserc_path,
    mise_pmsec_config_path,
    mise_shared_miserc_path,
    mise_system_miserc_path,
)
from pmsec.util.version import build_preflight, detect_version, gte

NAME = "mise"
KEY = "minimum_release_age"
SECTION = "settings"
DOCS = "https://mise.jdx.dev/configuration/settings.html#minimum_release_age"
MIN_BIN = (2026, 4, 22)
NEW_MODE_MIN = (2026, 11, 0)
EXTRAS = [
    {"key": "paranoid", "expected": "true", "line": "paranoid = true", "section": SECTION},
    {"key": "gpg_verify", "expected": "true", "line": "gpg_verify = true", "section": SECTION},
    {"key": "github_attestations", "expected": "true", "line": "github_attestations = true", "section": SECTION},
    {"key": "slsa", "expected": "true", "line": "slsa = true", "section": SECTION},
    {"key": "locked_verify_provenance", "expected": "true", "line": "locked_verify_provenance = true", "section": SECTION},
    {"key": "ruby.github_attestations", "expected": "true", "line": "ruby.github_attestations = true", "section": SECTION},
    {"key": "python.github_attestations", "expected": "true", "line": "python.github_attestations = true", "section": SECTION},
    {"key": "provenance_api_failures_fatal", "expected": "true", "line": "provenance_api_failures_fatal = true", "section": SECTION},
    {"key": "aqua.github_attestations", "expected": "true", "line": "aqua.github_attestations = true", "section": SECTION},
    {"key": "aqua.cosign", "expected": "true", "line": "aqua.cosign = true", "section": SECTION},
    {"key": "aqua.minisign", "expected": "true", "line": "aqua.minisign = true", "section": SECTION},
    {"key": "aqua.slsa", "expected": "true", "line": "aqua.slsa = true", "section": SECTION},
    {"key": "github.github_attestations", "expected": "true", "line": "github.github_attestations = true", "section": SECTION},
    {"key": "github.slsa", "expected": "true", "line": "github.slsa = true", "section": SECTION},
    {"key": "node.gpg_verify", "expected": "true", "line": "node.gpg_verify = true", "section": SECTION},
    {"key": "swift.gpg_verify", "expected": "true", "line": "swift.gpg_verify = true", "section": SECTION},
    {"key": "not_found_system_fallback", "expected": "false", "line": "not_found_system_fallback = false", "section": SECTION},
]

preflight = build_preflight(
    NAME, MIN_BIN,
    "setting was named install_before before 2026.4.22 and minimum_release_age is silently "
    "ignored on older mise. Upgrade mise (`mise self-update`) to enforce the cooldown.",
)

_DURATION = re.compile(
    r'^"?\s*(\d+)\s*(d|days?|w|weeks?|m|months?|y|years?)\s*"?$',
    re.IGNORECASE,
)

MIGRATION_WARN = (
    "a previous new-style mise configuration exists (config.pmsec.toml or the pmsec "
    "miserc selector); run `pmsec` to consolidate it"
)
MISE_ENV_WARN = "MISE_ENV overrides miserc and the pmsec environment is not active in this shell"


def path(ctx: Context) -> Path:
    return mise_config_path(ctx.env, ctx.home, ctx.platform)


def paths(ctx: Context) -> dict[str, Path]:
    return {
        "legacy": mise_config_path(ctx.env, ctx.home, ctx.platform),
        "dir": mise_config_dir(ctx.env, ctx.home),
        "base": mise_base_config_path(ctx.env, ctx.home),
        "pmsec": mise_pmsec_config_path(ctx.env, ctx.home),
        "local": mise_local_miserc_path(ctx.env, ctx.home),
        "shared": mise_shared_miserc_path(ctx.env, ctx.home),
        "system": mise_system_miserc_path(ctx.env, ctx.home, ctx.platform),
    }


def _parse_days(value: str | None) -> int | None:
    if value is None:
        return None
    m = _DURATION.match(value)
    if not m:
        return None
    n = int(m.group(1))
    unit = m.group(2).lower()
    if unit in ("w", "week", "weeks"):
        return n * 7
    if unit in ("m", "month", "months"):
        return n * 30
    if unit in ("y", "year", "years"):
        return n * 365
    return n


def _read(p: Path) -> str:
    return p.read_text("utf-8-sig") if p.exists() else ""


def _supports_new_mode(ctx: Context) -> bool:
    v = detect_version("mise", env=ctx.env, override_key="PMSEC_MISE_VERSION")
    return gte(v, NEW_MODE_MIN) is True and "MISE_GLOBAL_CONFIG_FILE" not in ctx.env


def _has_new_artifacts(ctx: Context, p: dict[str, Path]) -> bool:
    """A leftover config.pmsec.toml that defines no managed keys and is not
    selected anywhere is inert — mise loads the layer only when the pmsec
    environment is active — so legacy mode must converge instead of failing
    forever on a file the cleanup intentionally keeps. An artifact is an
    active selector (MISE_ENV or any miserc) or managed keys in the file."""
    if "pmsec" in env_list_from(ctx.env.get("MISE_ENV")):
        return True
    for f in (p["local"], p["shared"], p["system"]):
        if not f.exists():
            continue
        try:
            if "pmsec" in parse_env(_read(f))["values"]:
                return True
        except ValueError:
            continue
    try:
        r = _read_one(_read(p["pmsec"]))
        if r["configured"] is not None or any(e["configured"] is not None for e in r["extras"]):
            return True
    except Exception:
        pass
    return False


def _read_one(raw: str) -> dict:
    value = read_key(raw, KEY, section=SECTION)
    return {"configured": value, "days": _parse_days(value), "extras": read_extras(raw, EXTRAS)}


def _merge_reads(reads: list[dict]) -> dict:
    best = None
    fallback = None
    for r in reads:
        if r["configured"] is not None and fallback is None:
            fallback = r
        if r["days"] is not None and (best is None or r["days"] > best["days"]):
            best = r
    chosen = best or fallback
    extras = []
    for i, e in enumerate(EXTRAS):
        values = [r["extras"][i] for r in reads if i < len(r["extras"])]
        ok_one = next((v for v in values if v["ok"]), None)
        defined = next((v for v in values if v["configured"] is not None), None)
        extras.append(ok_one or defined or {"key": e["key"], "configured": None, "expected": e["expected"], "ok": False})
    return {
        "configured": chosen["configured"] if chosen else None,
        "days": best["days"] if best else (chosen["days"] if chosen else None),
        "extras": extras,
    }


def _read_files(files: list[Path]) -> list[dict]:
    return [_read_one(_read(p)) for p in files]


def _distinct(files: list[Path]) -> list[Path]:
    seen: list[Path] = []
    for p in files:
        if p not in seen:
            seen.append(p)
    return seen


def _first_env(p: dict[str, Path]) -> dict:
    for f in (p["local"], p["shared"], p["system"]):
        if not f.exists():
            continue
        parsed = parse_env(_read(f))
        if parsed["defined"]:
            return {"values": parsed["values"], "path": f}
    return {"values": [], "path": None}


def _selector_state(ctx: Context, p: dict[str, Path]) -> dict:
    from_var = env_list_from(ctx.env.get("MISE_ENV"))
    if from_var:
        return {"path": "MISE_ENV", "env": from_var, "wired": bool(from_var) and from_var[-1] == "pmsec"}
    inherited = _first_env(p)
    return {
        "path": str(inherited["path"] or p["local"]),
        "env": inherited["values"],
        "wired": bool(inherited["values"]) and inherited["values"][-1] == "pmsec",
    }


def _env_warning(ctx: Context) -> str | None:
    values = env_list_from(ctx.env.get("MISE_ENV"))
    if values and "pmsec" not in values:
        return MISE_ENV_WARN
    return None


def _is_empty_structure(text: str) -> bool:
    for line in re.split(r"\r?\n", text):
        t = line.strip()
        if t == "" or t.startswith("#"):
            continue
        if re.fullmatch(r"\[\[?[^\[\]]*\]\]?\s*(#.*)?", t):
            continue
        return False
    return True


def _unlink_quietly(p: Path) -> None:
    try:
        p.unlink()
    except FileNotFoundError:
        pass


def _remove_managed_config(p: Path) -> bool:
    before = _read(p)
    if before == "":
        return False
    cooldown, removed_cooldown = remove_key(before, KEY, section=SECTION)
    after, removed_extras = remove_extras(cooldown, EXTRAS)
    if not removed_cooldown and not removed_extras:
        return False
    if _is_empty_structure(after):
        _unlink_quietly(p)
    else:
        write_atomic(p, after)
    return True


def _remove_managed_from(p: Path) -> bool:
    before = _read(p)
    if before == "":
        return False
    cooldown, removed_cooldown = remove_key(before, KEY, section=SECTION)
    after, removed_extras = remove_extras(cooldown, EXTRAS)
    if removed_cooldown or removed_extras:
        write_atomic(p, after)
        return True
    return False


def _apply_settings(text: str, days: int, ctx: Context) -> str:
    out = set_key(text, KEY, f'{KEY} = "{days}d"', section=SECTION)
    return apply_extras(out, EXTRAS, ctx)


def _remove_selector(p: dict[str, Path]) -> bool:
    before = _read(p["local"])
    if before == "":
        return False
    r = remove_env_value(before, "pmsec")
    if not r["removed"]:
        return False
    if r["empty"]:
        _unlink_quietly(p["local"])
    else:
        write_atomic(p["local"], r["text"])
    return True


def _paths_aliased(p: dict[str, Path]) -> bool:
    """MISE_GLOBAL_CONFIG_FILE can point at <MISE_CONFIG_DIR>/config.pmsec.toml;
    then the legacy destination IS the new generation and the reverse-migration
    cleanup must not remove what it just wrote (or delete the global config)."""
    norm = lambda v: os.path.normpath(str(v))
    return norm(p["legacy"]) == norm(p["pmsec"])


def read(ctx: Context) -> dict:
    p = paths(ctx)
    action = getattr(ctx, "action", "check")
    if _supports_new_mode(ctx):
        files = [p["legacy"], p["base"], p["pmsec"]] if action == "enable" else [p["pmsec"]]
        if action == "enable":
            # Later environments override earlier keys, so a stricter cooldown
            # in any layer that stays active after enable must be preserved.
            from_var = env_list_from(ctx.env.get("MISE_ENV"))
            envs = from_var if from_var else _first_env(p)["values"]
            for name in envs:
                if name == "pmsec":
                    continue
                files.append(mise_env_config_path(name, ctx.env, ctx.home))
        merged = _merge_reads(_read_files(files))
        selector = _selector_state(ctx, p)
        return {
            "path": str(p["pmsec"]),
            **merged,
            "selector": selector,
            "warn": _env_warning(ctx),
            "rowFail": selector["wired"] is False,
        }
    artifacts = _has_new_artifacts(ctx, p)
    files = _distinct([p["legacy"], p["base"], p["pmsec"]]) if action == "enable" and artifacts else [p["legacy"]]
    merged = _merge_reads(_read_files(files))
    return {
        "path": str(p["legacy"]),
        **merged,
        "warn": MIGRATION_WARN if artifacts else None,
        "rowFail": artifacts,
    }


def write(days: int, ctx: Context) -> dict:
    p = paths(ctx)
    if _supports_new_mode(ctx):
        # Resolve the selector before touching any file: an invalid env array
        # must fail without leaving a half-migrated pair of generations.
        inherited = _first_env(p)
        values = [v for v in inherited["values"] if v != "pmsec"] + ["pmsec"]
        local_before = _read(p["local"])
        local_after = set_env_values(local_before, values)

        settings = _apply_settings(_read(p["pmsec"]), days, ctx)
        write_atomic(p["pmsec"], settings)
        write_atomic(p["local"], local_after)
        # A distinct baseConfig is left untouched; only the legacy write target
        # loses pmsec-managed keys.
        _remove_managed_from(p["legacy"])
        return {"path": str(p["pmsec"]), "warn": _env_warning(ctx)}

    artifacts = _has_new_artifacts(ctx, p)
    settings = _apply_settings(_read(p["legacy"]), days, ctx)
    write_atomic(p["legacy"], settings)
    if artifacts:
        # Write the destination before cleaning the new generation so an
        # interrupted cleanup cannot create a no-config gap.
        if not _paths_aliased(p):
            _remove_managed_config(p["pmsec"])
        _remove_selector(p)
    return {"path": str(p["legacy"]), "warn": None}


def unset(ctx: Context) -> dict:
    p = paths(ctx)
    new_mode = _supports_new_mode(ctx)
    legacy_removed = _remove_managed_from(p["legacy"])
    pmsec_removed = False if _paths_aliased(p) else _remove_managed_config(p["pmsec"])
    selector_removed = _remove_selector(p)
    return {
        "path": str(p["pmsec"] if new_mode else p["legacy"]),
        "removed": legacy_removed or pmsec_removed or selector_removed,
    }


def doctor_paths(ctx: Context) -> dict:
    p = paths(ctx)
    if _supports_new_mode(ctx):
        return {"path": str(p["pmsec"]), "extraPaths": [str(p["legacy"]), str(p["local"])]}
    return {"path": str(p["legacy"]), "extraPaths": []}
