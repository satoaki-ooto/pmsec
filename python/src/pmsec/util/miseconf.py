"""Narrow reader/writer for the top-level `env` array of a miserc file.

miserc files are TOML, but pmsec deliberately understands only the one shape it
writes: a bare, top-level `env = ["...", "..."]` assignment, inline or spread
over physical lines, with whitespace and comments between tokens. Everything
else fails closed with a structured `MiseEnvError` *before* any bytes are
produced, so a valid-but-unrecognised TOML form can never be partially rewritten
into an invalid or unprotected config.

Both functions are pure: they take text and return text. File I/O stays in
`util/io.py` (deliberately not imported here).
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# deliberate: Issue-#194 TOML subset only; unsupported forms fail closed. Upgrade path: extend this parser per port behind the same contract.

INVALID_MISE_ENV = "INVALID_MISE_ENV"

# Frozen reason vocabulary: every port emits these exact strings, so Phase 3
# call sites and the conformance layer can rely on them.
REASON_QUOTED_KEY = "quoted env key is unsupported"
REASON_DUPLICATE = "duplicate top-level env assignment"
REASON_NOT_ARRAY = "env must be an array"
REASON_ELEMENT = "env array elements must be single-line quoted strings"
REASON_ESCAPE = "escape sequences are unsupported"
REASON_MULTILINE = "multiline strings are unsupported"
REASON_UNTERMINATED = "unterminated env assignment"
REASON_MALFORMED = "malformed env assignment"
REASON_SEPARATOR = "malformed env array separator"
REASON_AFTER_ARRAY = "unexpected content after env array"
REASON_UNTERMINATED_FILE_STRING = "unterminated string in file"
REASON_ENV_TABLE = "env table conflicts with the env array"
REASON_UNREPRESENTABLE = "env name cannot be represented without escapes"

_ENV = "env"
_PMSEC = "pmsec"
_MULTILINE_DELIMITERS = ('"""', "'''")

# A bare key token: the exact word `env` followed by whitespace, `=`, a dotted-key
# dot, or end of line. `envelope = true` therefore stays an unrelated key.
_BARE_ENV = re.compile(r"[ \t]*env(?=[ \t\r=.]|$)")
# `"env" = ...` / `'env' = ...`: a quoted key, which this parser does not rewrite.
_QUOTED_ENV = re.compile(r"""[ \t]*(?:"env"|'env')[ \t]*=""")
# `[env]`, `[[env]]`, `[ "env" ]`: a table that owns the key we would insert.
_ENV_TABLE = re.compile(r"""[ \t]*\[\[?[ \t]*(?:env|"env"|'env')[ \t]*\]""")
# `env.foo = 1` and `env . foo = 1` define keys under a root `env` table.
_ENV_DOTTED = re.compile(r"[ \t]*env[ \t]*\.")


class MiseEnvError(OSError):
    """A miserc file whose `env` assignment pmsec will not touch.

    Subclasses OSError deliberately: the enable/disable paths already catch
    OSError, so wiring this helper in needs no new catch sites. `.code`,
    `.path` and `.reason` are the structured diagnostic; `str()` is the
    single-line message a CLI prints verbatim.
    """

    def __init__(self, path: str, reason: str) -> None:
        self.code = INVALID_MISE_ENV
        self.path = path
        self.reason = reason
        super().__init__(f"invalid env in {path}: {reason}")


@dataclass(frozen=True)
class _Structure:
    """String/comment-aware skeleton of a file, in byte offsets.

    `line_starts` holds only the offsets at which a line begins outside every
    string, so env-like text inside a `\"\"\"` block never counts as a line of
    code. `header_offsets` holds the start of every table header line (the first
    one closes the root region). `unterminated_string` is the offset where a
    multiline string that never closes was opened, if any.
    """

    line_starts: list[int]
    header_offsets: list[int]
    unterminated_string: int | None


@dataclass(frozen=True)
class _EnvAssignment:
    """A parsed top-level `env` array: its span and its decoded elements.

    `key_offset` is the first byte of the bare `env` key (anything before it is
    leading indentation) and `end` is the first byte after the closing `]`, so
    the whole assignment can be replaced without disturbing a byte around it.
    `tokens` keeps each element's original source text, quotes included, so a
    rewrite can reuse `'work'` instead of normalising it to `"work"`.
    """

    key_offset: int
    end: int
    values: list[str]
    tokens: list[str]


def read_env(text: str, source: str = "<memory>") -> list[str] | None:
    """Return the top-level `env` names, or None when the file has no assignment.

    `source` labels the file in the error message and `.path`. Raises
    `MiseEnvError` for every form outside the supported subset.
    """
    assignment = _parse(text, _scan_structure(text), source)
    return None if assignment is None else list(assignment.values)


def write_pmsec_env(text: str, inherited: list[str], source: str = "<memory>") -> str:
    """Rewrite `text` so its top-level `env` is `inherited` plus a trailing pmsec.

    Every exact `pmsec` in `inherited` is dropped and one is appended last, so
    calling this twice with the same list is byte-identical. An existing
    assignment is replaced from its bare key through its closing `]`, reusing
    the local quoting of names that are already present; every other byte —
    BOM, line endings, comments, unrelated tables, a missing final newline — is
    preserved. With no assignment, one canonical line is inserted at the end of
    the root region (before the first table header).

    Raises `MiseEnvError` for anything it cannot rewrite exactly, including a
    `[env]` table or `env.*` dotted keys, which would collide with the array.
    """
    structure = _scan_structure(text)
    _reject_competing_env_tables(text, structure, source)
    assignment = _parse(text, structure, source)
    target = [name for name in inherited if name != _PMSEC] + [_PMSEC]

    if assignment is None:
        line = _canonical_line([_quote(name, source) for name in target])
        root_end = structure.header_offsets[0] if structure.header_offsets else len(text)
        head = text[:root_end]
        if head and not head.endswith("\n"):
            head += "\n"
        return f"{head}{line}\n{text[root_end:]}"

    local: dict[str, str] = {}
    for value, token in zip(assignment.values, assignment.tokens):
        # Leftmost token wins: `["work", 'work']` stays stable across rewrites.
        local.setdefault(value, token)
    tokens = [
        local[name] if name in local else _quote(name, source) for name in target
    ]
    return f"{text[: assignment.key_offset]}{_canonical_line(tokens)}{text[assignment.end:]}"


def _canonical_line(tokens: list[str]) -> str:
    """One physical `env = [...]` line; `, ` separators, no trailing comma."""
    return f"{_ENV} = [{', '.join(tokens)}]"


def _quote(name: str, source: str) -> str:
    """Serialize a name the way miserc files hand-write them.

    Double quotes by default; single quotes (which process no escapes) when the
    value contains `"` or a literal backslash. A value that needs both quote
    kinds, or any control character, has no escape-free spelling and fails closed.
    """
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in name):
        raise _error(source, REASON_UNREPRESENTABLE)
    if '"' in name and "'" in name:
        raise _error(source, REASON_UNREPRESENTABLE)
    if '"' in name or "\\" in name:
        return f"'{name}'"
    return f'"{name}"'


def _error(source: str, reason: str) -> MiseEnvError:
    return MiseEnvError(source, reason)


def _scan_structure(text: str) -> _Structure:
    """Walk the whole file once, tracking strings and comments.

    Line starts recorded here are the only places a `key = value` line or a
    table header can begin; indices stay aligned with `text`, so callers can cut
    and rejoin substrings directly. A leading BOM is skipped but not consumed:
    the first recorded line start sits after it, which keeps the BOM in the
    preserved prefix of any rewrite.
    """
    length = len(text)
    index = 1 if text.startswith("\ufeff") else 0
    line_start = index
    line_has_content = False
    line_starts = [index]
    header_offsets: list[int] = []
    state = ""
    opened_at = -1

    while index < length:
        ch = text[index]

        if state in _MULTILINE_DELIMITERS:
            if text.startswith(state, index):
                index += 3
                state = ""
                opened_at = -1
                # The closing delimiter is code again: text later on this same
                # line must not be mistaken for the line's first non-blank char.
                line_has_content = True
                continue
            if ch == "\n":
                # New line, but its beginning is inside the string: not a code
                # line, so it is never offered as a key or header candidate.
                line_start = index + 1
                line_has_content = False
            index += 1
            continue

        if state:
            # A one-line string. Backslashes escape in basic strings, so a
            # `\"` inside one must not be taken for the closing quote.
            if state == '"' and ch == "\\":
                if index + 1 >= length or text[index + 1] == "\n":
                    # A trailing backslash cannot carry a one-line string across
                    # the newline: this subset does not validate general TOML, so
                    # the string simply ends with its line. Leaving `index` on the
                    # newline hands the rest of the file back to code state.
                    state = ""
                    opened_at = -1
                    index += 1
                    continue
                index += 2
                continue
            if ch == state:
                state = ""
                opened_at = -1
                index += 1
                continue
            if ch == "\n":
                # TOML forbids a raw newline in a one-line string. Treat it as
                # ended here so the rest of the file stays scannable; an env
                # element in this shape is reported by the assignment parser.
                state = ""
                opened_at = -1
                line_start = index + 1
                line_has_content = False
                line_starts.append(line_start)
                index += 1
                continue
            index += 1
            continue

        if ch == "\n":
            index += 1
            line_start = index
            line_has_content = False
            line_starts.append(line_start)
            continue
        if ch in " \t\r":
            index += 1
            continue
        if ch == "#":
            newline = text.find("\n", index)
            if newline < 0:
                break
            index = newline
            continue
        if ch == "[" and not line_has_content:
            header_offsets.append(line_start)
        line_has_content = True
        if text.startswith('"""', index) or text.startswith("'''", index):
            state = text[index : index + 3]
            opened_at = index
            index += 3
            continue
        if ch in "\"'":
            state = ch
            opened_at = index
            index += 1
            continue
        index += 1

    unterminated = opened_at if state in _MULTILINE_DELIMITERS else None
    return _Structure(line_starts=line_starts, header_offsets=header_offsets, unterminated_string=unterminated)


def _line_at(text: str, start: int) -> str:
    """The line beginning at `start`, without its line ending."""
    end = text.find("\n", start)
    return text[start:] if end < 0 else text[start:end]


def _parse(text: str, structure: _Structure, source: str) -> _EnvAssignment | None:
    """Find and parse the single top-level `env` assignment, if any."""
    root_end = structure.header_offsets[0] if structure.header_offsets else len(text)
    candidates: list[int] = []
    for start in structure.line_starts:
        if start >= root_end:
            break
        line = _line_at(text, start)
        match = _BARE_ENV.match(line)
        if match is not None:
            if line[match.end() :].startswith("."):
                # `env.foo = 1` defines a table, not this array: not defined.
                continue
            candidates.append(start + match.end() - len(_ENV))
            continue
        if _QUOTED_ENV.match(line) is not None:
            raise _error(source, REASON_QUOTED_KEY)

    if not candidates:
        if structure.unterminated_string is not None:
            raise _error(source, REASON_UNTERMINATED_FILE_STRING)
        return None

    assignment = _parse_assignment(text, candidates[0], source)
    if len(candidates) > 1:
        # Keep scanning instead of returning the first match: a second
        # assignment is a config pmsec cannot rewrite safely.
        raise _error(source, REASON_DUPLICATE)
    if structure.unterminated_string is not None:
        raise _error(source, REASON_UNTERMINATED_FILE_STRING)
    return assignment


def _parse_assignment(text: str, key_offset: int, source: str) -> _EnvAssignment:
    length = len(text)
    index = _skip_space_and_comments(text, key_offset + len(_ENV))
    if index >= length or text[index] != "=":
        raise _error(source, REASON_MALFORMED)
    index = _skip_space_and_comments(text, index + 1)
    if index >= length:
        # Nothing at all follows the `=`: the assignment is cut short, which is
        # a different failure from a value of the wrong shape.
        raise _error(source, REASON_UNTERMINATED)
    if text[index] != "[":
        if text[index] in "\"'":
            # Any scalar is the wrong shape, but a string is still scanned first
            # so a multiline, unterminated or escaped one reports its own cause.
            # `_read_element` is the same scanner the array uses, so the two
            # paths cannot drift apart.
            _read_element(text, index, source)
        raise _error(source, REASON_NOT_ARRAY)
    values, tokens, close = _read_array(text, index, source)
    end = close + 1
    _reject_trailing_content(text, end, source)
    return _EnvAssignment(key_offset=key_offset, end=end, values=values, tokens=tokens)


def _read_array(text: str, index: int, source: str) -> tuple[list[str], list[str], int]:
    """Parse `[...]` from the opening bracket; return values, tokens, `]` index."""
    length = len(text)
    values: list[str] = []
    tokens: list[str] = []
    index = _skip_space_and_comments(text, index + 1)
    if index >= length:
        raise _error(source, REASON_UNTERMINATED)
    if text[index] == "]":
        return values, tokens, index

    while True:
        index = _skip_space_and_comments(text, index)
        if index >= length:
            raise _error(source, REASON_UNTERMINATED)
        if text[index] in ",]":
            # A leading comma, or a second one after the separator was consumed.
            raise _error(source, REASON_SEPARATOR)
        value, token, index = _read_element(text, index, source)
        values.append(value)
        tokens.append(token)

        index = _skip_space_and_comments(text, index)
        if index >= length:
            raise _error(source, REASON_UNTERMINATED)
        if text[index] == "]":
            return values, tokens, index
        if text[index] != ",":
            raise _error(source, REASON_SEPARATOR)
        index = _skip_space_and_comments(text, index + 1)
        if index >= length:
            raise _error(source, REASON_UNTERMINATED)
        if text[index] == "]":
            return values, tokens, index
        if text[index] == ",":
            raise _error(source, REASON_SEPARATOR)


def _read_element(text: str, index: int, source: str) -> tuple[str, str, int]:
    """Read one single-line quoted element; return decoded value, token, next index."""
    length = len(text)
    if any(text.startswith(delimiter, index) for delimiter in _MULTILINE_DELIMITERS):
        raise _error(source, REASON_MULTILINE)
    quote = text[index]
    if quote not in "\"'":
        raise _error(source, REASON_ELEMENT)
    cursor = index + 1
    while cursor < length:
        ch = text[cursor]
        if quote == '"' and ch == "\\":
            raise _error(source, REASON_ESCAPE)
        if ch == quote:
            token = text[index : cursor + 1]
            return token[1:-1], token, cursor + 1
        if ch == "\n":
            break
        cursor += 1
    raise _error(source, REASON_UNTERMINATED)


def _skip_space_and_comments(text: str, index: int) -> int:
    """Skip spaces, tabs, newlines and `#` comments between tokens."""
    length = len(text)
    while index < length:
        ch = text[index]
        if ch in " \t\r\n":
            index += 1
            continue
        if ch == "#":
            newline = text.find("\n", index)
            if newline < 0:
                return length
            index = newline
            continue
        return index
    return index


def _reject_trailing_content(text: str, index: int, source: str) -> None:
    """Accept only spaces and a trailing comment between `]` and the line end."""
    length = len(text)
    while index < length:
        ch = text[index]
        if ch in " \t\r":
            index += 1
            continue
        if ch in "\n#":
            return
        raise _error(source, REASON_AFTER_ARRAY)


def _reject_competing_env_tables(text: str, structure: _Structure, source: str) -> None:
    """Fail before writing when `[env]` or `env.*` already defines the key."""
    for start in structure.header_offsets:
        if _ENV_TABLE.match(_line_at(text, start)) is not None:
            raise _error(source, REASON_ENV_TABLE)
    for start in structure.line_starts:
        if _ENV_DOTTED.match(_line_at(text, start)) is not None:
            raise _error(source, REASON_ENV_TABLE)
