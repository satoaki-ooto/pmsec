from __future__ import annotations

import re

# Helpers for mise's `miserc*.toml` global environment selectors and the
# pmsec-owned `config.pmsec.toml` layer. Only the pieces pmsec needs are
# modelled: a single top-level `env = [...]` array of environment names.

_ENV_KEY = re.compile(r"^\s*env\s*=\s*(.*)$")
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
    while True:
        ch = skip_ignored()
        if ch == "]":
            k += 1
            break
        if ch == ",":
            k += 1
            continue
        if ch not in ('"', "'"):
            raise ValueError("miserc env may only contain string names")
        quote = ch
        k += 1
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
    return values, j


def parse_env(text: str) -> dict:
    """Return {"defined", "values", "start", "end"}; start/end are line indexes."""
    if text == "":
        return {"defined": False, "values": [], "start": -1, "end": -1}
    lines = re.split(r"\r?\n", text)
    for i, line in enumerate(lines):
        if _SECTION.match(line):
            break
        m = _ENV_KEY.match(line)
        if not m:
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
    rendered = ", ".join('"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"' for v in values)
    return f"env = [{rendered}]"


def _top_level_insert_index(lines: list[str]) -> int:
    for i, line in enumerate(lines):
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
