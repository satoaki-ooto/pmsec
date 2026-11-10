// Helpers for mise's `miserc*.toml` global environment selectors and the
// pmsec-owned `config.pmsec.toml` layer. Only the pieces pmsec needs are
// modelled: a single top-level `env = [...]` array of environment names.

import { scanView } from "./lines.mjs";

const ENV_KEY = /^\s*env\s*=\s*(.*)$/;
const SECTION = /^\s*\[/;

function decodeBasicString(s) {
  return s.replace(/\\(u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|.)/g, (_m, esc) => {
    if (esc[0] === "u" || esc[0] === "U") {
      const code = parseInt(esc.slice(1), 16);
      return Number.isFinite(code) ? String.fromCodePoint(code) : "";
    }
    switch (esc) {
      case "b": return "\b";
      case "t": return "\t";
      case "n": return "\n";
      case "f": return "\f";
      case "r": return "\r";
      case '"': return '"';
      case "\\": return "\\";
      default: return esc;
    }
  });
}

// Parse the value starting at `[` on lines[startLine] from startCol.
// Comments (inside or between values) are ignored; bare identifiers, numbers,
// and nested arrays are rejected so an unparseable selector never gets
// silently rewritten.
function parseArray(lines, startLine, startCol) {
  let j = startLine, k = startCol;

  const skipIgnored = () => {
    for (;;) {
      if (j >= lines.length) throw new Error("miserc env array is unterminated");
      const line = lines[j];
      if (k >= line.length) { j++; k = 0; continue; }
      const ch = line[k];
      if (ch === "#") { j++; k = 0; continue; }
      if (/\s/.test(ch)) { k++; continue; }
      return ch;
    }
  };

  let ch = skipIgnored();
  if (ch !== "[") throw new Error("miserc env must be an array");
  k++;
  const values = [];
  for (;;) {
    ch = skipIgnored();
    if (ch === "]") { k++; break; }
    if (ch === ",") { k++; continue; }
    if (ch !== '"' && ch !== "'") throw new Error("miserc env may only contain string names");
    const quote = ch;
    k++;
    let value = "";
    let closed = false;
    while (j < lines.length) {
      const line = lines[j];
      if (k >= line.length) { j++; k = 0; continue; }
      const c = line[k];
      if (quote === '"' && c === "\\") {
        const next = line[k + 1];
        if (next === undefined) throw new Error("miserc env has an unterminated escape");
        if (next === "u" || next === "U") {
          const len = next === "u" ? 4 : 8;
          const hex = line.slice(k + 2, k + 2 + len);
          value += decodeBasicString(`\\${next}${hex}`);
          k += 2 + len;
          continue;
        }
        value += decodeBasicString(`\\${next}`);
        k += 2;
        continue;
      }
      if (c === quote) { k++; closed = true; break; }
      value += c;
      k++;
    }
    if (!closed) throw new Error("miserc env has an unterminated string");
    values.push(value);
  }
  return { values, endLine: j, endCol: k };
}

// Find the top-level `env` assignment — outside any table and outside a
// multi-line string, so text inside a `"""` body is never taken for the
// selector. Returns null when the file has none.
export function parseEnv(text) {
  if (text === "") return { defined: false, values: [], start: -1, end: -1 };
  const lines = text.split(/\r?\n/);
  const scan = scanView(lines);
  for (let i = 0; i < lines.length; i++) {
    if (SECTION.test(scan[i])) break;
    const m = scan[i].match(ENV_KEY);
    if (!m) continue;
    const startCol = scan[i].indexOf("=") + 1;
    const parsed = parseArray(lines, i, startCol);
    return { defined: true, values: parsed.values, start: i, end: parsed.endLine };
  }
  return { defined: false, values: [], start: -1, end: -1 };
}

function eolOf(text) { return text.includes("\r\n") ? "\r\n" : "\n"; }

function splitLines(text) {
  if (text === "") return { lines: [], trailing: false };
  const trailing = /\r?\n$/.test(text);
  return { lines: text.replace(/\r?\n$/, "").split(/\r?\n/), trailing };
}

function joinLines(lines, trailing, eol) {
  return lines.join(eol) + (lines.length && trailing ? eol : "");
}

function envLine(values) {
  return `env = [${values.map(v => JSON.stringify(v)).join(", ")}]`;
}

function topLevelInsertIndex(lines) {
  const scan = scanView(lines);
  for (let i = 0; i < lines.length; i++) {
    if (SECTION.test(scan[i])) {
      return i > 0 && lines[i - 1] === "" ? i - 1 : i;
    }
  }
  return lines.length;
}

function replaceEnv(text, values, parsed = parseEnv(text)) {
  const eol = eolOf(text);
  const { lines, trailing } = splitLines(text);
  const line = envLine(values);
  const wantTrailing = trailing || text === "";
  if (parsed.defined) {
    lines.splice(parsed.start, parsed.end - parsed.start + 1, line);
    return joinLines(lines, wantTrailing, eol);
  }
  const at = topLevelInsertIndex(lines);
  lines.splice(at, 0, line);
  return joinLines(lines, wantTrailing, eol);
}

// Replace/insert a single top-level env assignment with `values`. `pmsec` is
// placed last; every other line is preserved.
export function setEnvValues(text, values) {
  const parsed = text === "" ? { defined: false, values: [], start: -1, end: -1 } : parseEnv(text);
  return replaceEnv(text, values, parsed);
}

// Remove a name from the top-level env assignment. Returns removed=false when
// the file has no env or the name is absent. When the list becomes empty the
// whole assignment is dropped.
export function removeEnvValue(text, name) {
  const parsed = parseEnv(text);
  if (!parsed.defined) return { text, removed: false, empty: false };
  const kept = parsed.values.filter(v => v !== name);
  if (kept.length === parsed.values.length) return { text, removed: false, empty: false };
  if (kept.length > 0) return { text: replaceEnv(text, kept, parsed), removed: true, empty: false };
  const eol = eolOf(text);
  const { lines, trailing } = splitLines(text);
  lines.splice(parsed.start, parsed.end - parsed.start + 1);
  const out = joinLines(lines, trailing, eol);
  return { text: out, removed: true, empty: out.trim() === "" };
}

export function envListFrom(value) {
  if (!value) return [];
  return value.split(",").map(v => v.trim()).filter(Boolean);
}
