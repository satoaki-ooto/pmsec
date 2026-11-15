from __future__ import annotations

import os
import secrets
import stat
from pathlib import Path


def _is_symlink(path: Path) -> bool:
    try:
        return stat.S_ISLNK(path.lstat().st_mode)
    except FileNotFoundError:
        return False


def _atomic_replace(path: Path, text: str, *, raw: bool = False) -> None:
    """Replace `path` with `text` from a sibling temp file.

    `raw` picks the byte-exact output stream. The default text stream applies
    the platform newline translation, turning every `\\n` in the buffer into
    `os.linesep`; that is right for the callers whose buffers are already
    normalised to `\\n`, but on Windows it would rewrite an already-CRLF miserc
    as CRCRLF. Raw callers open with `newline=""` instead, so the buffer lands
    exactly as given.
    """
    parent = path.parent
    tmp = parent / f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}.tmp"
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="" if raw else None) as f:
                f.write(text)
                f.flush()
                try:
                    os.fsync(f.fileno())
                except OSError:
                    pass
        except BaseException:
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass
            raise
        os.replace(tmp, path)
    except BaseException:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise


# Permission errors propagate to the caller, which prints a chown hint. pmsec
# never escalates privileges itself: an unwritable config under HOME is an
# operator decision (or a symptom worth seeing), not something to sudo past.
def write_atomic(path: Path, text: str, *, backup: bool = True, raw: bool = False) -> None:
    """Write `text` to `path` atomically, keeping the first pre-existing bytes as a backup.

    `raw=True` keeps the buffer byte for byte (see `_atomic_replace`). Only the
    miserc selector writer asks for it, because it hands over text read with
    `newline=""` whose CRLF must survive the rewrite; every other caller keeps
    the normalising text stream it has always used. The backup itself stays on
    that text stream: it is a decoded snapshot (BOM-less, universal newlines),
    which is its long-standing behaviour for every caller.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and _is_symlink(path):
        raise OSError(f"refusing to write through symlink {path}")
    if backup and path.exists():
        bak = path.with_suffix(path.suffix + ".bak")
        if not bak.exists():
            # A dangling symlink fails exists(); os.replace would swap the link
            # itself, but refuse so a planted link is visible, not silently clobbered.
            if _is_symlink(bak):
                raise OSError(f"refusing to write backup through symlink {bak}")
            _atomic_replace(bak, path.read_text("utf-8-sig"))
    _atomic_replace(path, text, raw=raw)
