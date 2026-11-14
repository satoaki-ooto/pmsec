from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from pmsec.util.paths import mise_config_path, mise_paths  # noqa: E402

POSIX_HOME = Path("/home/user")
WIN_HOME = Path("C:\\Users\\user")
WIN_LOCALAPPDATA = "C:\\Users\\user\\AppData\\Local"

KEYS = [
    "legacyConfig",
    "miseDir",
    "baseConfig",
    "pmsecConfig",
    "localMiserc",
    "sharedMiserc",
    "systemMiserc",
]


def test_returns_exactly_the_contract_keys():
    assert list(mise_paths({}, POSIX_HOME, "linux")) == KEYS


def test_posix_defaults_nest_every_new_file_under_dot_config_mise():
    assert mise_paths({}, POSIX_HOME, "linux") == {
        "legacyConfig": "/home/user/.config/mise/config.toml",
        "miseDir": "/home/user/.config/mise",
        "baseConfig": "/home/user/.config/mise/config.toml",
        "pmsecConfig": "/home/user/.config/mise/config.pmsec.toml",
        "localMiserc": "/home/user/.config/mise/miserc.local.toml",
        "sharedMiserc": "/home/user/.config/mise/miserc.toml",
        "systemMiserc": "/etc/mise/miserc.toml",
    }


def test_posix_xdg_override_moves_the_config_dir_but_not_the_system_file():
    paths = mise_paths({"XDG_CONFIG_HOME": "/xdg"}, POSIX_HOME, "linux")
    assert paths["miseDir"] == "/xdg/mise"
    assert paths["baseConfig"] == "/xdg/mise/config.toml"
    assert paths["pmsecConfig"] == "/xdg/mise/config.pmsec.toml"
    assert paths["systemMiserc"] == "/etc/mise/miserc.toml"


def test_mise_config_dir_beats_xdg():
    paths = mise_paths({"MISE_CONFIG_DIR": "/mise", "XDG_CONFIG_HOME": "/xdg"}, POSIX_HOME, "linux")
    assert paths["miseDir"] == "/mise"
    assert paths["baseConfig"] == "/mise/config.toml"
    assert paths["localMiserc"] == "/mise/miserc.local.toml"


def test_empty_mise_config_dir_and_empty_xdg_fall_through():
    paths = mise_paths({"MISE_CONFIG_DIR": "", "XDG_CONFIG_HOME": ""}, POSIX_HOME, "linux")
    assert paths["miseDir"] == "/home/user/.config/mise"


def test_empty_mise_system_config_dir_falls_through():
    paths = mise_paths({"MISE_SYSTEM_CONFIG_DIR": ""}, POSIX_HOME, "linux")
    assert paths["systemMiserc"] == "/etc/mise/miserc.toml"


def test_mise_system_config_dir_override():
    paths = mise_paths({"MISE_SYSTEM_CONFIG_DIR": "/opt/mise"}, POSIX_HOME, "linux")
    assert paths["systemMiserc"] == "/opt/mise/miserc.toml"


def test_legacy_global_config_file_only_moves_the_legacy_config():
    paths = mise_paths({"MISE_GLOBAL_CONFIG_FILE": "/custom/mise.toml"}, POSIX_HOME, "linux")
    assert paths["legacyConfig"] == "/custom/mise.toml"
    # A pinned mise file has nowhere to host the layer, so the family ignores it.
    assert paths["miseDir"] == "/home/user/.config/mise"
    assert paths["pmsecConfig"] == "/home/user/.config/mise/config.pmsec.toml"


def test_mise_config_dir_does_not_move_the_legacy_config():
    paths = mise_paths({"MISE_CONFIG_DIR": "/mise", "XDG_CONFIG_HOME": "/xdg"}, POSIX_HOME, "linux")
    assert paths["legacyConfig"] == "/xdg/mise/config.toml"
    assert paths["miseDir"] == "/mise"


# Deliberate legacy fix in this phase: an exported but empty
# MISE_GLOBAL_CONFIG_FILE means unset, matching bash and Node. Python used to
# return Path("") for it.
def test_empty_global_config_file_means_unset():
    assert mise_config_path({"MISE_GLOBAL_CONFIG_FILE": ""}, POSIX_HOME, "linux") == Path("/home/user/.config/mise/config.toml")
    paths = mise_paths({"MISE_GLOBAL_CONFIG_FILE": "", "XDG_CONFIG_HOME": "/xdg"}, POSIX_HOME, "linux")
    assert paths["legacyConfig"] == "/xdg/mise/config.toml"


def test_win32_legacy_uses_localappdata_while_the_new_dir_uses_dot_config():
    paths = mise_paths({"LOCALAPPDATA": WIN_LOCALAPPDATA}, WIN_HOME, "win32")
    legacy = paths["legacyConfig"].replace("\\", "/")
    assert legacy.startswith("C:/Users/user/AppData/Local/mise/")
    assert legacy.endswith("/mise/config.toml")
    # Never LOCALAPPDATA for the new layering.
    assert paths["miseDir"] == "C:\\Users\\user\\.config\\mise"
    assert paths["baseConfig"] == "C:\\Users\\user\\.config\\mise\\config.toml"
    assert paths["pmsecConfig"] == "C:\\Users\\user\\.config\\mise\\config.pmsec.toml"
    assert "AppData" not in paths["miseDir"]
    assert "AppData" not in paths["systemMiserc"]


def test_win32_new_dir_default_is_dot_config_even_with_localappdata_set():
    without = mise_paths({}, WIN_HOME, "win32")
    with_localappdata = mise_paths({"LOCALAPPDATA": WIN_LOCALAPPDATA}, WIN_HOME, "win32")
    assert without["miseDir"] == "C:\\Users\\user\\.config\\mise"
    assert with_localappdata["miseDir"] == "C:\\Users\\user\\.config\\mise"


def test_win32_xdg_override():
    paths = mise_paths({"XDG_CONFIG_HOME": "C:\\xdg"}, WIN_HOME, "win32")
    assert paths["miseDir"] == "C:\\xdg\\mise"
    assert paths["sharedMiserc"] == "C:\\xdg\\mise\\miserc.toml"


def test_win32_mise_config_dir_beats_xdg():
    paths = mise_paths({"MISE_CONFIG_DIR": "C:\\mise", "XDG_CONFIG_HOME": "C:\\xdg"}, WIN_HOME, "win32")
    assert paths["miseDir"] == "C:\\mise"
    assert paths["localMiserc"] == "C:\\mise\\miserc.local.toml"


def test_win32_system_miserc_sits_under_the_injected_cwd_drive_root():
    assert mise_paths({}, WIN_HOME, "win32", cwd="D:\\work")["systemMiserc"] == "D:\\etc\\mise\\miserc.toml"
    assert mise_paths({}, WIN_HOME, "win32", cwd="C:\\work")["systemMiserc"] == "C:\\etc\\mise\\miserc.toml"
    # A drive-less (relative) cwd anchors the path at the current drive's root.
    assert mise_paths({}, WIN_HOME, "win32", cwd="work")["systemMiserc"] == "\\etc\\mise\\miserc.toml"


def test_win32_system_miserc_ignores_home_and_systemdrive():
    paths = mise_paths({"SystemDrive": "E:", "USERPROFILE": "C:\\Users\\user"}, WIN_HOME, "win32", cwd="D:\\work")
    assert paths["systemMiserc"] == "D:\\etc\\mise\\miserc.toml"


def test_win32_system_config_dir_override_beats_the_drive_root():
    paths = mise_paths({"MISE_SYSTEM_CONFIG_DIR": "C:\\ProgramData\\mise"}, WIN_HOME, "win32", cwd="D:\\work")
    assert paths["systemMiserc"] == "C:\\ProgramData\\mise\\miserc.toml"


def test_win32_without_cwd_keeps_the_system_miserc_drive_root_relative():
    assert mise_paths({}, WIN_HOME, "win32")["systemMiserc"] == "\\etc\\mise\\miserc.toml"


def test_legacy_config_file_wins_over_every_platform_shortcut_on_win32():
    paths = mise_paths({"MISE_GLOBAL_CONFIG_FILE": "D:\\pinned\\mise.toml", "LOCALAPPDATA": WIN_LOCALAPPDATA}, WIN_HOME, "win32")
    assert paths["legacyConfig"] == "D:\\pinned\\mise.toml"
