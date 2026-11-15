from __future__ import annotations

import ntpath
import os
import posixpath
import sys
from pathlib import Path


def npmrc_path(env: dict[str, str], home: Path) -> Path:
    if "NPM_CONFIG_USERCONFIG" in env:
        return Path(env["NPM_CONFIG_USERCONFIG"])
    return home / ".npmrc"


def pnpm_rc_path(env: dict[str, str], home: Path, platform: str) -> Path:
    """pnpm reads its global rc separately from ~/.npmrc; writing pnpm-only
    keys here keeps npm from warning (and, in npm 12, erroring) about unknown
    user config. pnpm respects XDG_CONFIG_HOME on every OS."""
    if "PMSEC_PNPM_CONFIG_FILE" in env:
        return Path(env["PMSEC_PNPM_CONFIG_FILE"])
    if "XDG_CONFIG_HOME" in env:
        return Path(env["XDG_CONFIG_HOME"]) / "pnpm" / "rc"
    if platform == "darwin":
        return home / "Library" / "Preferences" / "pnpm" / "rc"
    if platform == "win32":
        base = Path(env["LOCALAPPDATA"]) if "LOCALAPPDATA" in env else home / "AppData" / "Local"
        return base / "pnpm" / "config" / "rc"
    return home / ".config" / "pnpm" / "rc"


def pnpm_config_path(env: dict[str, str], home: Path, platform: str) -> Path:
    """pnpm >= 11 reads pnpm-specific settings from config.yaml (camelCase)
    instead of the registry/auth-only rc file. Keep it next to the rc path so
    custom PMSEC_PNPM_CONFIG_FILE overrides remain self-contained."""
    if "PMSEC_PNPM_CONFIG_YAML" in env:
        return Path(env["PMSEC_PNPM_CONFIG_YAML"])
    return pnpm_rc_path(env, home, platform).parent / "config.yaml"


def bun_config_path(env: dict[str, str], home: Path) -> Path:
    """bun reads $XDG_CONFIG_HOME/.bunfig.toml *instead of* $HOME/.bunfig.toml
    whenever XDG_CONFIG_HOME is set to an absolute path."""
    if "BUN_CONFIG_FILE" in env:
        return Path(env["BUN_CONFIG_FILE"])
    xdg = env.get("XDG_CONFIG_HOME")
    if xdg and Path(xdg).is_absolute():
        return Path(xdg) / ".bunfig.toml"
    return home / ".bunfig.toml"


def yarnrc_path(env: dict[str, str], home: Path) -> Path:
    if "YARN_RC_FILENAME" in env:
        return Path(env["YARN_RC_FILENAME"])
    return home / ".yarnrc.yml"


def cargo_config_path(env: dict[str, str], home: Path) -> Path:
    if "CARGO_HOME" in env:
        return Path(env["CARGO_HOME"]) / "config.toml"
    return home / ".cargo" / "config.toml"


def bundle_config_path(env: dict[str, str], home: Path) -> Path:
    """Bundler's global config. BUNDLE_USER_CONFIG points at the file directly;
    BUNDLE_USER_HOME points at the home dir (config lives at <home>/config).
    Both default to ~/.bundle, matching bundler's own resolution order."""
    if "BUNDLE_USER_CONFIG" in env:
        return Path(env["BUNDLE_USER_CONFIG"])
    if "BUNDLE_USER_HOME" in env:
        return Path(env["BUNDLE_USER_HOME"]) / "config"
    return home / ".bundle" / "config"


def mise_config_path(env: dict[str, str], home: Path, platform: str) -> Path:
    # Empty means unset, matching the shell and Node ports: an exported but
    # empty MISE_GLOBAL_CONFIG_FILE must not resolve to Path("").
    if env.get("MISE_GLOBAL_CONFIG_FILE"):
        return Path(env["MISE_GLOBAL_CONFIG_FILE"])
    if platform == "win32":
        base = Path(env["LOCALAPPDATA"]) if "LOCALAPPDATA" in env else home / "AppData" / "Local"
        return base / "mise" / "config.toml"
    base = Path(env["XDG_CONFIG_HOME"]) if "XDG_CONFIG_HOME" in env else home / ".config"
    return base / "mise" / "config.toml"


def mise_paths(env: dict[str, str], home: Path, platform: str, cwd: str | None = None) -> dict[str, str]:
    """Every mise file pmsec works with, legacy and layered.

    `legacyConfig` is the single global config file mise reads today and stays
    delegated to `mise_config_path`. The rest describe the 2026.11 layering:
    `config.pmsec.toml` and the two miserc files live next to `config.toml` in
    `miseDir`, while `systemMiserc` is machine-wide.

    Values are plain strings. On `win32` the new fields are built with `ntpath`
    so a simulated Windows host yields real Windows shapes (drive letters,
    backslashes, `<drive>\\etc\\mise\\miserc.toml`) instead of `pathlib`'s
    host-dependent `/` joining. `legacyConfig` is `str()` of the existing
    `Path`-returning resolver, so it prints exactly what the CLI prints today.
    Pure: no filesystem access. `cwd` only supplies the drive for win32's
    system miserc; a missing or drive-less `cwd` leaves it drive-root-relative.
    """
    windows = platform == "win32"
    join = ntpath.join if windows else posixpath.join

    mise_dir = env.get("MISE_CONFIG_DIR") or ""
    if not mise_dir:
        xdg = env.get("XDG_CONFIG_HOME") or ""
        mise_dir = join(xdg, "mise") if xdg else join(str(home), ".config", "mise")

    system_dir = env.get("MISE_SYSTEM_CONFIG_DIR") or ""
    if system_dir:
        system_miserc = join(system_dir, "miserc.toml")
    elif windows:
        # mise reads its system config from the current drive's root; neither
        # home nor SystemDrive participates. Without a drive the `\etc\...`
        # path stays anchored at whichever drive happens to be current.
        drive = ntpath.splitdrive(str(cwd))[0] if cwd else ""
        system_miserc = ntpath.join(drive + "\\", "etc", "mise", "miserc.toml")
    else:
        system_miserc = "/etc/mise/miserc.toml"

    return {
        "legacyConfig": str(mise_config_path(env, home, platform)),
        "miseDir": mise_dir,
        "baseConfig": join(mise_dir, "config.toml"),
        "pmsecConfig": join(mise_dir, "config.pmsec.toml"),
        "localMiserc": join(mise_dir, "miserc.local.toml"),
        "sharedMiserc": join(mise_dir, "miserc.toml"),
        "systemMiserc": system_miserc,
    }


def uv_config_path(env: dict[str, str], home: Path, platform: str) -> Path:
    if "UV_CONFIG_FILE" in env:
        return Path(env["UV_CONFIG_FILE"])
    if platform == "win32":
        base = Path(env["APPDATA"]) if "APPDATA" in env else home / "AppData" / "Roaming"
        return base / "uv" / "uv.toml"
    base = Path(env["XDG_CONFIG_HOME"]) if "XDG_CONFIG_HOME" in env else home / ".config"
    return base / "uv" / "uv.toml"


def aube_config_path(env: dict[str, str], home: Path, platform: str) -> Path:
    if "AUBE_CONFIG_FILE" in env:
        return Path(env["AUBE_CONFIG_FILE"])
    if platform == "win32":
        base = Path(env["LOCALAPPDATA"]) if "LOCALAPPDATA" in env else home / "AppData" / "Local"
        return base / "aube" / "config.toml"
    base = Path(env["XDG_CONFIG_HOME"]) if "XDG_CONFIG_HOME" in env else home / ".config"
    return base / "aube" / "config.toml"


def composer_config_path(env: dict[str, str], home: Path, platform: str) -> Path:
    """Mirrors Composer's Factory::getHomeDir: COMPOSER_HOME, else %APPDATA%/Composer
    on Windows, else (when any XDG_* variable is set or /etc/xdg exists) the
    first existing of $XDG_CONFIG_HOME/composer and ~/.composer, defaulting to
    the XDG one; without XDG, ~/.composer. Composer never uses Application
    Support on macOS."""
    if "COMPOSER_HOME" in env:
        return Path(env["COMPOSER_HOME"]) / "config.json"
    if platform == "win32":
        base = Path(env["APPDATA"]) if "APPDATA" in env else home / "AppData" / "Roaming"
        return base / "Composer" / "config.json"
    # The /etc/xdg probe describes the host, so it only applies when the
    # requested platform is the host platform (tests pass foreign platforms).
    use_xdg = any(k.startswith("XDG_") for k in env) or (
        platform == current_platform() and Path("/etc/xdg").is_dir()
    )
    dirs: list[Path] = []
    if use_xdg:
        dirs.append(Path(env.get("XDG_CONFIG_HOME") or (home / ".config")) / "composer")
    dirs.append(home / ".composer")
    chosen = next((d for d in dirs if d.is_dir()), dirs[0])
    return chosen / "config.json"


def current_platform() -> str:
    if os.name == "nt":
        return "win32"
    if sys.platform == "darwin":
        return "darwin"
    return "linux"
