"""The effective mise `env` list, and the one place pmsec writes it.

mise 2026.11 resolves the top-level `env` array from `MISE_ENV` or from three
miserc files in precedence order: local, shared, system. pmsec never merges
those lists — the first file that defines `env` owns the effective list, so a
higher-precedence file can deliberately stop inheritance with `env = []`.

Reading and writing answer different questions. `read_selector` reports what
mise would use, `MISE_ENV` included. `write_local_selector` inherits the
*file-based* list only: `MISE_ENV` describes one shell invocation, so copying
its names into `miserc.local.toml` would silently promote a temporary
selection into every later `pmsec enable`.

Every read, parse and planning step happens before the single atomic write.
A broken higher-precedence file therefore aborts the whole operation instead
of leaving a half-applied config (or a fresh backup of the wrong bytes).
Format knowledge stays in the pure parser in `util/miseconf.py`; file I/O for
this layer lives here.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from pmsec.util.io import write_atomic
from pmsec.util.miseconf import MiseEnvError, read_env, write_pmsec_env
from pmsec.util.paths import current_platform, mise_paths

# Reason strings are the shared cross-port vocabulary declared in miseconf.py;
# this module adds the one file-level failure the pure parser cannot see.
REASON_CANNOT_READ = "cannot read file"

# mise's own precedence order. Reading stops at the first file that defines
# `env`, so nothing later in this tuple may be opened once a definition exists.
_SOURCES = ("localMiserc", "sharedMiserc", "systemMiserc")
_PMSEC = "pmsec"


@dataclass(frozen=True)
class Selector:
    """Which list is effective, and where it came from.

    `path` is `"MISE_ENV"` when the variable decided the list, otherwise the
    miserc file that defines it — or the local file when none does. `wired` is
    exact, case-sensitive membership of `pmsec`: position is irrelevant, and
    `env_sets` never expands here.
    """

    path: str
    env: list[str]
    wired: bool


def read_selector(
    env: dict[str, str],
    home: Path,
    platform: str = current_platform(),
    cwd: str | None = None,
) -> Selector:
    """What mise would use for `env`, without reading any file when `MISE_ENV` decides.

    mise tokenizes `MISE_ENV` by splitting on commas and dropping empty
    elements; names are *not* trimmed (`"a, b"` selects `" b"`). pmsec reports
    the same names mise would, and an empty `MISE_ENV` is unset (file fallback)
    rather than an empty selection.
    """
    mise_env = env.get("MISE_ENV")
    if mise_env:
        # Byte-for-byte mise: no trimming, no de-duplication, empties dropped.
        names = [name for name in mise_env.split(",") if name != ""]
        return Selector("MISE_ENV", names, _PMSEC in names)

    paths = mise_paths(env, home, platform, cwd)
    definition = _first_definition(paths)
    if definition is None:
        return Selector(paths["localMiserc"], [], False)
    path, names = definition
    return Selector(path, names, _PMSEC in names)


def write_local_selector(
    env: dict[str, str],
    home: Path,
    platform: str = current_platform(),
    cwd: str | None = None,
) -> str:
    """Wire pmsec into the local miserc and return that file's path.

    The inherited list is file-based even when `MISE_ENV` is set: the variable
    is a per-invocation choice, not configuration to persist. Nothing is
    written, backed up or `mkdir`'d until every source file has been read and
    parsed and the replacement text is fully planned; shared and system files
    are read as inheritance but never written.
    """
    paths = mise_paths(env, home, platform, cwd)
    definition = _first_definition(paths)
    local = paths["localMiserc"]
    current = _read_text(local)
    text = write_pmsec_env(
        "" if current is None else current,
        [] if definition is None else definition[1],
        local,
    )
    write_atomic(Path(local), text)
    return local


def _first_definition(paths: dict[str, str]) -> tuple[str, list[str]] | None:
    """The highest-precedence file whose top-level `env` exists, if any.

    Files are visited in precedence order and the walk stops at the first
    definition, so a lower-precedence file is never opened once a higher one
    has decided the list. `env = []` counts as a definition: it is how a local
    file stops inheriting the shared list. A missing file is only precedence;
    any other read failure or a parse error propagates and fails closed.
    """
    for source in _SOURCES:
        path = paths[source]
        text = _read_text(path)
        if text is None:
            continue
        # `read_env` labels its own errors with `path`, so a parse failure
        # already carries the file it came from and must not be caught here.
        names = read_env(text, path)
        if names is not None:
            return path, names
    return None


def _read_text(path: str) -> str | None:
    """Raw utf-8 text of `path`, or None when the file does not exist.

    Read directly instead of through the tool helpers: those decode with
    `utf-8-sig` and would drop a BOM that the writer has to reproduce
    byte-for-byte. `newline=""` matters just as much: the default universal
    newlines would turn CRLF into LF, so the rewrite would silently normalize
    every line ending in a file pmsec only meant to touch one assignment in.

    Missing is precedence, not an error. Every other failure — a directory,
    permissions, undecodable bytes — fails closed with `path` rather than
    falling through to a lower-precedence file.
    """
    try:
        with Path(path).open("r", encoding="utf-8", newline="") as file:
            return file.read()
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError) as error:
        raise MiseEnvError(path, REASON_CANNOT_READ) from error
