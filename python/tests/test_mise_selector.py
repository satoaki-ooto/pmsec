from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from pmsec.util.io import write_atomic  # noqa: E402
from pmsec.util.miseconf import MiseEnvError  # noqa: E402
from pmsec.util.selector import Selector, read_selector, write_local_selector  # noqa: E402

# Every path is injected: `env` carries MISE_CONFIG_DIR / MISE_SYSTEM_CONFIG_DIR,
# `home` is either an unused placeholder (MISE_ENV branch) or the tmp_path, and
# no test mutates os.environ. Unreadable sources are simulated with chmod 000
# rather than mocks, so "this file was never read" is proven by not raising.
# Nothing here may touch the host's real /etc/mise or ~/.config/mise.

HOME = Path("/home/user")
WIN_HOME = Path("C:\\Users\\user")

CANNOT_READ = "cannot read file"
NOT_ARRAY = "env must be an array"
MALFORMED = "malformed env assignment"
ENV_TABLE = "env table conflicts with the env array"

# chmod 000 only blocks a read for a non-root POSIX user. Same guard the
# existing CLI permission tests use, so the suite stays green as root or on
# Windows where mode bits do not deny reads.
NO_PERMISSION_SEMANTICS = pytest.mark.skipif(
    sys.platform == "win32" or (hasattr(os, "geteuid") and os.geteuid() == 0),
    reason="POSIX permission semantics; Windows and root bypass chmod for non-execute bits",
)


def _paths(tmp_path: Path) -> tuple[Path, Path, Path, dict[str, str]]:
    """Local, shared and system miserc under tmp_path, plus the dict that selects them."""
    config = tmp_path / "mise"
    local = config / "miserc.local.toml"
    shared = config / "miserc.toml"
    system = tmp_path / "etc" / "miserc.toml"
    env = {
        "MISE_CONFIG_DIR": str(config),
        "MISE_SYSTEM_CONFIG_DIR": str(system.parent),
    }
    return local, shared, system, env


def _write(path: Path, text: str) -> None:
    """Raw bytes, so a BOM or CRLF in a fixture survives being written."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(text.encode("utf-8"))


def _bak(path: Path) -> Path:
    # Same suffix rule as util/io.py: miserc.local.toml -> miserc.local.toml.bak
    return path.with_suffix(path.suffix + ".bak")


def _temps(path: Path) -> list[str]:
    return [p.name for p in path.parent.glob(".*.tmp")]


# --- read: MISE_ENV ---------------------------------------------------------


def test_mise_env_splits_on_commas_without_trimming():
    def names(value: str) -> list[str]:
        return read_selector({"MISE_ENV": value}, HOME, "linux").env

    assert names("a,b") == ["a", "b"]
    # mise 2026.11.0 does not trim around commas: " b" keeps its space.
    assert names("a, b") == ["a", " b"]
    assert names("a,") == ["a"]
    assert names(",a") == ["a"]
    assert names(",,,") == []
    assert names("a,a") == ["a", "a"]
    assert names(" a ") == [" a "]


def test_mise_env_path_is_the_variable_name():
    selector = read_selector({"MISE_ENV": "work"}, HOME, "linux")
    assert selector == Selector("MISE_ENV", ["work"], False)


def test_mise_env_wired_is_exact_case_sensitive_membership():
    def wired(value: str) -> bool:
        return read_selector({"MISE_ENV": value}, HOME, "linux").wired

    assert wired("pmsec") is True
    assert wired("pmsec,work") is True
    assert wired("work,pmsec") is True
    assert wired("work,pmsec,other") is True
    assert wired("work") is False
    # Position alone never wires; the name must match exactly.
    assert wired("Pmsec") is False
    assert wired(" pmsec") is False
    assert wired("pmsec ") is False
    assert wired(",,") is False


def test_mise_env_decides_without_any_filesystem_access(tmp_path):
    local, _, _, env = _paths(tmp_path)
    # A directory where the local file would be: reading it raises
    # IsADirectoryError, so a successful return proves the file was never opened.
    local.mkdir(parents=True)
    env["MISE_ENV"] = "work,pmsec"
    assert read_selector(env, tmp_path, "linux") == Selector("MISE_ENV", ["work", "pmsec"], True)


# --- read: file precedence --------------------------------------------------


def test_empty_mise_env_falls_back_to_the_files(tmp_path):
    _, shared, _, env = _paths(tmp_path)
    _write(shared, 'env = ["work"]\n')
    env["MISE_ENV"] = ""
    assert read_selector(env, tmp_path, "linux") == Selector(str(shared), ["work"], False)


@NO_PERMISSION_SEMANTICS
def test_local_definition_wins_and_nothing_below_it_is_read(tmp_path):
    local, shared, _, env = _paths(tmp_path)
    _write(local, 'env = ["work", "pmsec"]\n')
    _write(shared, 'env = ["unreadable"]\n')
    os.chmod(shared, 0o000)
    try:
        assert read_selector(env, tmp_path, "linux") == Selector(
            str(local), ["work", "pmsec"], True
        )
    finally:
        os.chmod(shared, 0o600)


@NO_PERMISSION_SEMANTICS
def test_shared_definition_wins_when_local_is_missing_and_system_is_not_read(tmp_path):
    _, shared, system, env = _paths(tmp_path)
    _write(shared, 'env = ["a"]\n')
    _write(system, 'env = ["b"]\n')
    os.chmod(system, 0o000)
    try:
        assert read_selector(env, tmp_path, "linux") == Selector(str(shared), ["a"], False)
    finally:
        os.chmod(system, 0o600)


def test_system_definition_wins_when_local_and_shared_are_missing(tmp_path):
    _, _, system, env = _paths(tmp_path)
    _write(system, 'env = ["sys", "pmsec"]\n')
    assert read_selector(env, tmp_path, "linux") == Selector(
        str(system), ["sys", "pmsec"], True
    )


def test_local_empty_array_is_a_definition_that_stops_inheritance(tmp_path):
    local, shared, _, env = _paths(tmp_path)
    _write(local, "env = []\n")
    _write(shared, 'env = ["work", "pmsec"]\n')
    assert read_selector(env, tmp_path, "linux") == Selector(str(local), [], False)


def test_a_nested_array_before_env_does_not_hide_the_definition(tmp_path):
    # A line-start `[` inside the open array nests a value and must not end the
    # root region, or the env below it would read as not defined.
    _, shared, _, env = _paths(tmp_path)
    _write(shared, 'items = [\n  [1, 2],\n]\nenv = ["work"]\n')
    assert read_selector(env, tmp_path, "linux") == Selector(str(shared), ["work"], False)


def test_a_file_without_an_env_assignment_does_not_define(tmp_path):
    local, shared, system, env = _paths(tmp_path)
    _write(local, '[tools]\nnode = "22"\n')
    _write(shared, "# just a comment\n")
    _write(system, "env = []\n")
    assert read_selector(env, tmp_path, "linux") == Selector(str(system), [], False)


def test_no_definition_reports_the_local_path(tmp_path):
    local, shared, _, env = _paths(tmp_path)
    _write(shared, '[tools]\nnode = "22"\n')
    assert read_selector(env, tmp_path, "linux") == Selector(str(local), [], False)
    # A config directory that does not exist at all reads the same way. The
    # system dir is injected too: the host's real /etc/mise must stay unread.
    missing = tmp_path / "absent"
    absent = {
        "MISE_CONFIG_DIR": str(missing),
        "MISE_SYSTEM_CONFIG_DIR": str(tmp_path / "absent-etc"),
    }
    assert read_selector(absent, tmp_path, "linux") == Selector(
        str(missing / "miserc.local.toml"), [], False
    )


# --- read: fail-closed errors ----------------------------------------------


def test_parse_error_in_the_local_file_propagates_and_never_falls_back(tmp_path):
    local, shared, _, env = _paths(tmp_path)
    _write(local, 'env = "work"\n')
    _write(shared, 'env = ["work"]\n')
    with pytest.raises(MiseEnvError) as excinfo:
        read_selector(env, tmp_path, "linux")
    error = excinfo.value
    assert error.code == "INVALID_MISE_ENV"
    assert error.reason == NOT_ARRAY
    assert error.path == str(local)
    assert str(error) == f"invalid env in {local}: {NOT_ARRAY}"


@NO_PERMISSION_SEMANTICS
def test_unreadable_local_file_fails_closed_with_its_path(tmp_path):
    local, shared, _, env = _paths(tmp_path)
    _write(local, 'env = ["work"]\n')
    _write(shared, 'env = ["work"]\n')
    os.chmod(local, 0o000)
    try:
        with pytest.raises(MiseEnvError) as excinfo:
            read_selector(env, tmp_path, "linux")
        assert excinfo.value.reason == CANNOT_READ
        assert excinfo.value.path == str(local)
        assert excinfo.value.code == "INVALID_MISE_ENV"
    finally:
        os.chmod(local, 0o600)


def test_a_directory_where_a_miserc_file_is_expected_is_a_read_error(tmp_path):
    local, _, _, env = _paths(tmp_path)
    local.mkdir(parents=True)
    with pytest.raises(MiseEnvError) as excinfo:
        read_selector(env, tmp_path, "linux")
    assert excinfo.value.reason == CANNOT_READ
    assert excinfo.value.path == str(local)


# --- read: simulated Windows shape -----------------------------------------


def test_win32_path_shape_comes_from_mise_paths_without_touching_the_host(tmp_path):
    # No MISE_CONFIG_DIR: win32 nests the layer under home/.config/mise, and the
    # system file hangs off the injected cwd's drive. These names cannot exist
    # on this host, so every source is simply missing.
    selector = read_selector({}, WIN_HOME, "win32", cwd="C:\\repo")
    assert selector == Selector("C:\\Users\\user\\.config\\mise\\miserc.local.toml", [], False)


# --- write: target list -----------------------------------------------------


def test_empty_config_writes_the_canonical_line_and_creates_the_dir_last(tmp_path):
    local, shared, system, env = _paths(tmp_path)
    assert not local.parent.exists()
    assert not shared.exists()
    assert not system.exists()

    assert write_local_selector(env, tmp_path, "linux") == str(local)
    assert local.read_bytes() == b'env = ["pmsec"]\n'
    # The system tree is never created either.
    assert not system.parent.exists()
    # Nothing to back up when the file did not exist.
    assert not _bak(local).exists()


def test_inherits_the_shared_list_when_the_local_file_is_missing(tmp_path):
    local, shared, system, env = _paths(tmp_path)
    _write(shared, 'env = ["work", "pmsec", "x"]\n')
    _write(system, 'env = ["sys"]\n')
    shared_before = shared.read_bytes()
    system_before = system.read_bytes()

    write_local_selector(env, tmp_path, "linux")

    assert local.read_bytes() == b'env = ["work", "x", "pmsec"]\n'
    assert shared.read_bytes() == shared_before
    assert system.read_bytes() == system_before


def test_inherits_the_system_list_when_local_and_shared_are_missing(tmp_path):
    local, _, system, env = _paths(tmp_path)
    _write(system, 'env = ["sys"]\n')
    system_before = system.read_bytes()

    write_local_selector(env, tmp_path, "linux")

    assert local.read_bytes() == b'env = ["sys", "pmsec"]\n'
    assert system.read_bytes() == system_before


def test_existing_local_assignment_is_rewritten_in_place(tmp_path):
    local, _, _, env = _paths(tmp_path)
    # BOM, CRLF, a trailing comment after the closing bracket, an unrelated
    # table and no final newline all sit outside the rewritten range.
    original = '\ufeff# top\r\nenv = ["work"]  # keep\r\n\r\n[tools]\r\nnode = "22"'
    _write(local, original)

    write_local_selector(env, tmp_path, "linux")

    assert local.read_bytes() == (
        '\ufeff# top\r\nenv = ["work", "pmsec"]  # keep\r\n\r\n[tools]\r\nnode = "22"'
    ).encode("utf-8")


def test_existing_single_quote_tokens_are_reused(tmp_path):
    local, _, _, env = _paths(tmp_path)
    _write(local, "env = ['work']\n")
    write_local_selector(env, tmp_path, "linux")
    assert local.read_bytes() == b"env = ['work', \"pmsec\"]\n"


def test_missing_local_assignment_is_inserted_at_the_end_of_the_root_region(tmp_path):
    local, shared, _, env = _paths(tmp_path)
    _write(local, 'name = "x"\n\n[tools]\nnode = "22"\n')
    _write(shared, 'env = ["work"]\n')

    write_local_selector(env, tmp_path, "linux")

    # The new line lands before the first table header, not at end of file.
    assert local.read_bytes() == (
        b'name = "x"\n\nenv = ["work", "pmsec"]\n[tools]\nnode = "22"\n'
    )


def test_local_empty_array_is_replaced_with_pmsec(tmp_path):
    local, shared, _, env = _paths(tmp_path)
    _write(local, "env = []\n")
    _write(shared, 'env = ["work"]\n')
    write_local_selector(env, tmp_path, "linux")
    assert local.read_bytes() == b'env = ["pmsec"]\n'
    assert shared.read_bytes() == b'env = ["work"]\n'


def test_a_nested_array_in_the_local_file_survives_the_rewrite(tmp_path):
    local, _, _, env = _paths(tmp_path)
    _write(local, 'items = [\n  [1, 2],\n]\nenv = ["work"]\n')
    write_local_selector(env, tmp_path, "linux")
    assert local.read_bytes() == b'items = [\n  [1, 2],\n]\nenv = ["work", "pmsec"]\n'


def test_a_nested_array_does_not_take_the_insertion_point(tmp_path):
    # With no local assignment the line goes at the end of the root region, never
    # between the elements of an array that is open there.
    local, shared, _, env = _paths(tmp_path)
    _write(local, 'items = [\n  [1, 2],\n]\n')
    _write(shared, 'env = ["work"]\n')
    write_local_selector(env, tmp_path, "linux")
    assert local.read_bytes() == b'items = [\n  [1, 2],\n]\nenv = ["work", "pmsec"]\n'


def test_rewrite_preserves_mixed_crlf_and_lf_bytes(tmp_path):
    # `_read_text` keeps every line ending as read, so the planned text holds
    # both CRLF and LF; the raw output path must write them back untouched. A
    # universal-newline round trip would turn the lone LF line into CRLF here.
    local, _, _, env = _paths(tmp_path)
    original = 'name = "x"\r\nenv = ["work"]\r\nlast = 1\n'
    _write(local, original)
    write_local_selector(env, tmp_path, "linux")
    assert local.read_bytes() == b'name = "x"\r\nenv = ["work", "pmsec"]\r\nlast = 1\n'


def test_the_raw_atomic_path_writes_the_buffer_byte_for_byte(tmp_path):
    # Windows text mode turns every LF in the buffer into CRLF again, which is
    # why the selector writer asks for the raw stream. This pins the bytes that
    # stream produces, and that the legacy default call still writes a
    # normalised buffer unchanged (the path every other caller keeps).
    raw = tmp_path / "raw" / "miserc.local.toml"
    write_atomic(raw, 'env = ["a"]\r\nx = 1\n', raw=True)
    assert raw.read_bytes() == b'env = ["a"]\r\nx = 1\n'
    legacy = tmp_path / "legacy" / "miserc.local.toml"
    write_atomic(legacy, 'env = ["a"]\n')
    assert legacy.read_bytes() == b'env = ["a"]\n'


def test_rerunning_is_byte_idempotent_and_keeps_the_existing_backup(tmp_path):
    local, _, _, env = _paths(tmp_path)
    _write(local, 'env = ["work", "pmsec"]\n')

    assert write_local_selector(env, tmp_path, "linux") == str(local)
    first = local.read_bytes()
    backup = _bak(local)
    assert backup.read_bytes() == b'env = ["work", "pmsec"]\n'

    assert write_local_selector(env, tmp_path, "linux") == str(local)
    assert local.read_bytes() == first == b'env = ["work", "pmsec"]\n'
    # write_atomic never overwrites an existing .bak, so the first original stays.
    assert backup.read_bytes() == b'env = ["work", "pmsec"]\n'


def test_writer_ignores_mise_env_when_no_file_defines(tmp_path):
    local, _, _, env = _paths(tmp_path)
    env["MISE_ENV"] = "a,b"
    write_local_selector(env, tmp_path, "linux")
    assert local.read_bytes() == b'env = ["pmsec"]\n'


def test_writer_inherits_the_file_list_even_when_mise_env_is_set(tmp_path):
    local, shared, _, env = _paths(tmp_path)
    _write(shared, 'env = ["y"]\n')
    env["MISE_ENV"] = "a,b"
    write_local_selector(env, tmp_path, "linux")
    assert local.read_bytes() == b'env = ["y", "pmsec"]\n'


# --- write: fail-closed before any byte exists ------------------------------


def test_shared_parse_error_leaves_local_untouched_and_writes_nothing(tmp_path):
    local, shared, _, env = _paths(tmp_path)
    _write(local, '# keep\nname = "x"\n')
    _write(shared, 'env = "work"\n')
    before = local.read_bytes()

    with pytest.raises(MiseEnvError) as excinfo:
        write_local_selector(env, tmp_path, "linux")

    assert excinfo.value.reason == NOT_ARRAY
    assert excinfo.value.path == str(shared)
    assert local.read_bytes() == before
    assert not _bak(local).exists()
    assert _temps(local) == []


def test_env_table_in_the_target_fails_before_writing(tmp_path):
    local, _, _, env = _paths(tmp_path)
    original = '[env]\nFOO = "1"\n'
    _write(local, original)

    with pytest.raises(MiseEnvError) as excinfo:
        write_local_selector(env, tmp_path, "linux")

    assert excinfo.value.reason == ENV_TABLE
    assert excinfo.value.path == str(local)
    assert local.read_bytes() == original.encode("utf-8")
    assert not _bak(local).exists()
    assert _temps(local) == []


@pytest.mark.parametrize(
    "original", ['["env"]\nFOO = "1"\n', "[env.foo]\n", "env . foo = 1\n", '"env".foo = 1\n']
)
def test_every_spelling_of_an_env_table_fails_before_writing(tmp_path, original: str):
    local, _, _, env = _paths(tmp_path)
    _write(local, original)

    with pytest.raises(MiseEnvError) as excinfo:
        write_local_selector(env, tmp_path, "linux")

    assert excinfo.value.reason == ENV_TABLE
    assert excinfo.value.path == str(local)
    assert local.read_bytes() == original.encode("utf-8")
    assert not _bak(local).exists()
    assert _temps(local) == []


@pytest.mark.parametrize("reader", [read_selector, write_local_selector])
def test_a_bare_env_key_with_no_assignment_fails_closed(tmp_path, reader):
    # `env` at end of file is a malformed assignment, not a file without one:
    # neither reading nor wiring may treat it as absent.
    local, _, _, env = _paths(tmp_path)
    _write(local, "env\n")

    with pytest.raises(MiseEnvError) as excinfo:
        reader(env, tmp_path, "linux")

    assert excinfo.value.reason == MALFORMED
    assert excinfo.value.path == str(local)
    assert local.read_bytes() == b"env\n"


@pytest.mark.parametrize("reader", [read_selector, write_local_selector])
def test_undecodable_bytes_fail_closed_as_cannot_read(tmp_path, reader):
    local, _, _, env = _paths(tmp_path)
    local.parent.mkdir(parents=True)
    original = b'env = ["work"]\n\xff\xfe\n'
    local.write_bytes(original)

    with pytest.raises(MiseEnvError) as excinfo:
        reader(env, tmp_path, "linux")

    assert excinfo.value.reason == CANNOT_READ
    assert excinfo.value.path == str(local)
    assert excinfo.value.code == "INVALID_MISE_ENV"
    assert local.read_bytes() == original


@NO_PERMISSION_SEMANTICS
def test_unreadable_shared_file_leaves_local_untouched(tmp_path):
    local, shared, _, env = _paths(tmp_path)
    _write(local, "# keep\n")
    _write(shared, 'env = ["x"]\n')
    os.chmod(shared, 0o000)
    try:
        with pytest.raises(MiseEnvError) as excinfo:
            write_local_selector(env, tmp_path, "linux")
        assert excinfo.value.reason == CANNOT_READ
        assert excinfo.value.path == str(shared)
    finally:
        os.chmod(shared, 0o600)

    assert local.read_bytes() == b"# keep\n"
    assert not _bak(local).exists()
    assert _temps(local) == []


def test_a_failed_write_does_not_create_the_target_directory(tmp_path):
    local, shared, system, env = _paths(tmp_path)
    assert not local.parent.exists()
    assert not shared.exists()
    _write(system, 'env = "work"\n')

    with pytest.raises(MiseEnvError) as excinfo:
        write_local_selector(env, tmp_path, "linux")

    assert excinfo.value.reason == NOT_ARRAY
    assert excinfo.value.path == str(system)
    assert not local.parent.exists()
