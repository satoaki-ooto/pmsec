from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from pmsec.tools.mise import NEW_MODE_MIN, preflight, supports_new_mode  # noqa: E402
from pmsec.util.context import Context  # noqa: E402

# Matches the floor every other port uses for the layered config.
NEW_ENOUGH = {"2026.11.0", "2026.12.0"}

VERSIONS = ["2026.11.0", "2026.10.25", "2026.12.0", "none"]
# None = variable absent, "" = exported but empty (means unset).
LEGACY_OVERRIDES = [None, "", "somewhere"]


def make_ctx(version: str, legacy_override: str | None) -> tuple[Context, dict[str, str]]:
    env = {"PMSEC_MISE_VERSION": version}
    if legacy_override is not None:
        env["MISE_GLOBAL_CONFIG_FILE"] = legacy_override
    return Context(env=env, home=Path("/home/user"), platform="linux"), env


def test_new_mode_floor_is_2026_11_0():
    assert NEW_MODE_MIN == (2026, 11, 0)


@pytest.mark.parametrize("legacy_override", LEGACY_OVERRIDES)
@pytest.mark.parametrize("version", VERSIONS)
def test_mode_matrix(version: str, legacy_override: str | None):
    ctx, _ = make_ctx(version, legacy_override)
    assert supports_new_mode(ctx) is (version in NEW_ENOUGH and not legacy_override)


def test_mode_is_recomputed_on_every_call():
    # One mutable Context, mutated in place: any caching would freeze the first
    # answer and fail these assertions.
    ctx, env = make_ctx("2026.10.25", None)
    assert supports_new_mode(ctx) is False

    env["PMSEC_MISE_VERSION"] = "2026.11.0"
    assert supports_new_mode(ctx) is True

    env["PMSEC_MISE_VERSION"] = "2026.12.0"
    assert supports_new_mode(ctx) is True

    env["PMSEC_MISE_VERSION"] = "none"
    assert supports_new_mode(ctx) is False

    env["PMSEC_MISE_VERSION"] = "2026.11.0"
    env["MISE_GLOBAL_CONFIG_FILE"] = "somewhere"
    assert supports_new_mode(ctx) is False

    env["MISE_GLOBAL_CONFIG_FILE"] = ""
    assert supports_new_mode(ctx) is True

    del env["MISE_GLOBAL_CONFIG_FILE"]
    assert supports_new_mode(ctx) is True


# The cooldown preflight and the config mode are separate gates: a mise too old
# for the layered config is still new enough to enforce minimum_release_age.
def test_old_mode_does_not_disturb_the_preflight_floor():
    below_floor, _ = make_ctx("2026.4.21", None)
    assert preflight(below_floor)["warn"] is True
    new_but_legacy_mode, _ = make_ctx("2026.10.25", None)
    assert preflight(new_but_legacy_mode).get("warn") is None
    assert supports_new_mode(new_but_legacy_mode) is False
