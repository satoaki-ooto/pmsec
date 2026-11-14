from __future__ import annotations

import re

from .lines import scan_view

# Helpers for mise's `miserc*.toml` global environment selectors and the
# pmsec-owned `config.pmsec.toml` layer. Only the pieces pmsec needs are
# modelled: a single top-level `env = [...]` array of environment names.

# TOML treats "env", 'env', and env as the same key; recognize all three so
# migration replaces the existing assignment instead of adding a duplicate.
# A basic-quoted key may carry escapes ("e\u006ev" decodes to env), so the
# double-quoted spelling is captured and decoded before the comparison.
_ENV_KEY = re.compile(r'^\s*(?:"((?:[^"\\]|\\.)*)"|\'([^\']*)\'|(env))\s*=\s*(.*)$')
_SECTION = re.compile(r"^\s*\[")


def _decode_basic(s: str) -> str:
    def repl(m: re.Match) -> str:
        esc = m.group(1)
        if esc[0] in ("u", "U"):
            try:
                return chr(int(esc[1:], 16))
            except (ValueError, OverflowError):
                return ""
        return {
            "b": "\b", "t": "\t", "n": "\n", "f": "\f", "r": "\r",
            '"': '"', "\\": "\\",
        }.get(esc, esc)

    return re.sub(r"\\(u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|.)", repl, s)


def _parse_array(lines: list[str], start_line: int, start_col: int) -> tuple[list[str], int]:
    j, k = start_line, start_col

    def skip_ignored() -> str:
        nonlocal j, k
        while True:
            if j >= len(lines):
                raise ValueError("miserc env array is unterminated")
            line = lines[j]
            if k >= len(line):
                j += 1
                k = 0
                continue
            ch = line[k]
            if ch == "#":
                j += 1
                k = 0
                continue
            if ch.isspace():
                k += 1
                continue
            return ch

    ch = skip_ignored()
    if ch != "[":
        raise ValueError("miserc env must be an array")
    k += 1
    values: list[str] = []
    # Separators are validated: a comma is required between values, and one
    # may not lead or repeat (a trailing comma stays valid TOML).
    need_sep = False
    while True:
        ch = skip_ignored()
        if ch == "]":
            k += 1
            break
        if ch == ",":
            if not need_sep:
                raise ValueError("miserc env has an unexpected comma")
            need_sep = False
            k += 1
            continue
        if ch not in ('"', "'"):
            raise ValueError("miserc env may only contain string names")
        if need_sep:
            raise ValueError("miserc env is missing a comma between names")
        quote = ch
        k += 1
        if lines[j][k:k + 2] == quote * 2:
            # A multiline basic/literal string is one value that may span
            # lines: `env = ["""work"""]` is valid TOML.
            k += 2
            value = ""
            closed = False
            # TOML trims the first newline right after the opening delimiter.
            if k >= len(lines[j]):
                j += 1
                k = 0
            while j < len(lines):
                line = lines[j]
                if k >= len(line):
                    j += 1
                    k = 0
                    value += "\n"
                    continue
                c = line[k]
                if quote == '"' and c == "\\":
                    if re.fullmatch(r"[ \t]*", line[k + 1:]):
                        # A line-ending backslash trims the newline and the
                        # following whitespace instead of being content.
                        j += 1
                        k = 0
                        while j < len(lines):
                            stripped = lines[j].lstrip(" \t")
                            if stripped == "":
                                j += 1
                                continue
                            k = len(lines[j]) - len(stripped)
                            break
                        continue
                    if k + 1 >= len(line):
                        raise ValueError("miserc env has an unterminated escape")
                    nxt = line[k + 1]
                    if nxt in ("u", "U"):
                        width = 4 if nxt == "u" else 8
                        value += _decode_basic("\\" + nxt + line[k + 2:k + 2 + width])
                        k += 2 + width
                        continue
                    value += _decode_basic("\\" + nxt)
                    k += 2
                    continue
                # One or two content quotes may precede the closing delimiter,
                # so a four-/five-quote run closes on its final three quotes.
                closing = 0
                while closing < 5 and k + closing < len(line) and line[k + closing] == quote:
                    closing += 1
                if closing in (4, 5):
                    value += quote * (closing - 3)
                    k += closing
                    closed = True
                    break
                if closing == 3:
                    k += 3
                    closed = True
                    break
                value += c
                k += 1
            if not closed:
                raise ValueError("miserc env has an unterminated string")
            values.append(value)
            need_sep = True
            continue
        value = ""
        closed = False
        while j < len(lines):
            line = lines[j]
            if k >= len(line):
                j += 1
                k = 0
                continue
            c = line[k]
            if quote == '"' and c == "\\":
                if k + 1 >= len(line):
                    raise ValueError("miserc env has an unterminated escape")
                nxt = line[k + 1]
                if nxt in ("u", "U"):
                    width = 4 if nxt == "u" else 8
                    value += _decode_basic("\\" + nxt + line[k + 2:k + 2 + width])
                    k += 2 + width
                    continue
                value += _decode_basic("\\" + nxt)
                k += 2
                continue
            if c == quote:
                k += 1
                closed = True
                break
            value += c
            k += 1
        if not closed:
            raise ValueError("miserc env has an unterminated string")
        values.append(value)
        need_sep = True
    return values, j


def parse_env(text: str) -> dict:
    """Return {"defined", "values", "start", "end"}; start/end are line indexes.

    Top-level means outside any table and outside a multi-line string: text
    inside a multi-line string body is never taken for the selector.
    """
    if text == "":
        return {"defined": False, "values": [], "start": -1, "end": -1}
    lines = re.split(r"\r?\n", text)
    scan = scan_view(lines)
    for i, line in enumerate(scan):
        if _SECTION.match(line):
            break
        m = _ENV_KEY.match(line)
        if not m:
            continue
        # Group 1 is a double-quoted key (escapes decoded), group 2 a literal
        # single-quoted key (never decoded), group 3 the bare spelling.
        if m.group(1) is not None:
            key = _decode_basic(m.group(1))
        elif m.group(2) is not None:
            key = m.group(2)
        else:
            key = m.group(3)
        if key != "env":
            continue
        start_col = line.index("=") + 1
        values, end = _parse_array(lines, i, start_col)
        return {"defined": True, "values": values, "start": i, "end": end}
    return {"defined": False, "values": [], "start": -1, "end": -1}


def _eol(text: str) -> str:
    return "\r\n" if "\r\n" in text else "\n"


def _split_lines(text: str) -> tuple[list[str], bool]:
    if text == "":
        return [], False
    trailing = bool(re.search(r"\r?\n$", text))
    body = re.sub(r"\r?\n$", "", text)
    return re.split(r"\r?\n", body), trailing


def _join_lines(lines: list[str], trailing: bool, eol: str) -> str:
    out = eol.join(lines)
    if lines and trailing:
        out += eol
    return out


def _env_line(values: list[str]) -> str:
    # Escape backslash and quote first, then every control character TOML
    # forbids in a basic string (C0 except tab is written as its short escape,
    # the rest and DEL as \uXXXX). C1 and non-ASCII stay raw, like node.
    def quote(v: str) -> str:
        out = v.replace("\\", "\\\\").replace('"', '\\"')
        for ch, esc in (("\b", "\\b"), ("\t", "\\t"), ("\n", "\\n"), ("\f", "\\f"), ("\r", "\\r")):
            out = out.replace(ch, esc)
        out = re.sub(r"[\x00-\x08\x0b\x0e-\x1f\x7f]", lambda m: f"\\u{ord(m.group(0)):04x}", out)
        return f'"{out}"'

    return f"env = [{', '.join(quote(v) for v in values)}]"


def _top_level_insert_index(lines: list[str]) -> int:
    scan = scan_view(lines)
    for i, line in enumerate(scan):
        if _SECTION.match(line):
            return i - 1 if i > 0 and lines[i - 1] == "" else i
    return len(lines)


def _replace_env(text: str, values: list[str], parsed: dict | None = None) -> str:
    eol = _eol(text)
    parsed = parsed or parse_env(text)
    lines, trailing = _split_lines(text)
    want_trailing = trailing or text == ""
    line = _env_line(values)
    if parsed["defined"]:
        lines[parsed["start"]:parsed["end"] + 1] = [line]
        return _join_lines(lines, want_trailing, eol)
    at = _top_level_insert_index(lines)
    lines.insert(at, line)
    return _join_lines(lines, want_trailing, eol)


def set_env_values(text: str, values: list[str]) -> str:
    """Replace/insert a single top-level env assignment. Other lines are preserved."""
    return _replace_env(text, values)


def remove_env_value(text: str, name: str) -> dict:
    """Remove a name from the top-level env assignment.

    Returns {"text", "removed", "empty"}; `empty` is true when the remaining
    file is whitespace only and the caller should delete it.
    """
    parsed = parse_env(text)
    if not parsed["defined"]:
        return {"text": text, "removed": False, "empty": False}
    kept = [v for v in parsed["values"] if v != name]
    if len(kept) == len(parsed["values"]):
        return {"text": text, "removed": False, "empty": False}
    if kept:
        return {"text": _replace_env(text, kept, parsed), "removed": True, "empty": False}
    eol = _eol(text)
    lines, trailing = _split_lines(text)
    del lines[parsed["start"]:parsed["end"] + 1]
    out = _join_lines(lines, trailing, eol)
    return {"text": out, "removed": True, "empty": out.strip() == ""}


def env_list_from(value: str | None) -> list[str]:
    if not value:
        return []
    return [v.strip() for v in value.split(",") if v.strip()]
