from __future__ import annotations

import os
import re
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
    if "MISE_GLOBAL_CONFIG_FILE" in env:
        return Path(env["MISE_GLOBAL_CONFIG_FILE"])
    if platform == "win32":
        base = Path(env["LOCALAPPDATA"]) if "LOCALAPPDATA" in env else home / "AppData" / "Local"
        return base / "mise" / "config.toml"
    base = Path(env["XDG_CONFIG_HOME"]) if "XDG_CONFIG_HOME" in env else home / ".config"
    return base / "mise" / "config.toml"


def mise_config_dir(env: dict[str, str], home: Path) -> Path:
    """mise's global config directory (https://mise.jdx.dev/directories.html).

    Unlike the legacy single-file path above this is the same on every OS:
    win32 uses %USERPROFILE%\\.config\\mise, not %LOCALAPPDATA%\\mise.
    """
    if "MISE_CONFIG_DIR" in env:
        return Path(env["MISE_CONFIG_DIR"])
    if "XDG_CONFIG_HOME" in env:
        return Path(env["XDG_CONFIG_HOME"]) / "mise"
    return home / ".config" / "mise"


def mise_base_config_path(env: dict[str, str], home: Path) -> Path:
    return mise_config_dir(env, home) / "config.toml"


def mise_pmsec_config_path(env: dict[str, str], home: Path) -> Path:
    return mise_config_dir(env, home) / "config.pmsec.toml"


def mise_local_miserc_path(env: dict[str, str], home: Path) -> Path:
    return mise_config_dir(env, home) / "miserc.local.toml"


def mise_shared_miserc_path(env: dict[str, str], home: Path) -> Path:
    return mise_config_dir(env, home) / "miserc.toml"


def mise_system_miserc_path(env: dict[str, str], home: Path, platform: str) -> Path:
    if "MISE_SYSTEM_CONFIG_DIR" in env:
        return Path(env["MISE_SYSTEM_CONFIG_DIR"]) / "miserc.toml"
    if platform == "win32":
        # `home` may be a simulated Windows path on a POSIX test runner, so
        # read the drive letter from the string instead of Path.anchor.
        m = re.match(r"^[A-Za-z]:[\\/]", str(home))
        root = m.group(0) if m else (home.anchor or "C:\\")
        return Path(root) / "etc" / "mise" / "miserc.toml"
    return Path("/etc/mise/miserc.toml")


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
