// Narrow, fail-closed reader/writer for the single top-level `env = [...]`
// assignment of a mise miserc file.
//
// deliberate: Issue-#194 TOML subset only; unsupported forms fail closed. Upgrade path: extend this parser per port behind the same contract.
//
// The "root region" is everything from the start of the file (after a leading
// BOM, which is skipped but preserved) to the first line whose first
// non-whitespace character is `[` outside a string, a comment, or an open
// array/inline table (string- and comment-aware bracket depth). Only a bare,
// case-sensitive `env` key there is a target; every other byte is untouched.
// Nothing here validates TOML in general: the scanner only tracks enough
// structure (basic/literal strings, `"""`/`'''` blocks, comments, value
// brackets) to keep env-like text and table headers inside them from being
// misparsed.

const BOM = "\uFEFF";

// A bare `env` token only counts when followed by one of these, so `envelope`
// and `envoy` stay unrelated keys.
const BARE_KEY_END = new Set([" ", "\t", "\r", "\n", "\f", "\v", "="]);

// Names that cannot appear inside a one-line quoted string without escapes.
const CONTROL = /[\u0000-\u001f\u007f]/;

export class MiseEnvError extends Error {
  constructor(reason, path) {
    super(`invalid env in ${path}: ${reason}`);
    this.name = "MiseEnvError";
    this.code = "INVALID_MISE_ENV";
    this.path = path;
    this.reason = reason;
  }
}

function fail(path, reason) {
  throw new MiseEnvError(reason, path);
}

// Skips spaces, tabs, CRs, newlines, and `#` comments. Used between every token
// of an assignment, so an array may be spread over any number of lines.
function skipTrivia(text, i) {
  const n = text.length;
  for (;;) {
    while (i < n && (text[i] === " " || text[i] === "\t" || text[i] === "\r" || text[i] === "\n")) i++;
    if (i < n && text[i] === "#") {
      while (i < n && text[i] !== "\n") i++;
      continue;
    }
    return i;
  }
}

// Scans a one-line basic string starting at the opening `"` and returns the
// index of the closing quote. The subset carries no escapes, so a backslash is
// fatal rather than decoded.
function scanBasic(text, i, path) {
  if (text.startsWith('"""', i)) fail(path, "multiline strings are unsupported");
  for (let j = i + 1; ; j++) {
    if (j >= text.length || text[j] === "\n") fail(path, "unterminated env assignment");
    if (text[j] === "\\") fail(path, "escape sequences are unsupported");
    if (text[j] === '"') return j;
  }
}

// Scans a one-line literal string starting at the opening `'`. Backslashes are
// ordinary content here, which is why `['say\hi']` is accepted verbatim.
function scanLiteral(text, i, path) {
  if (text.startsWith("'''", i)) fail(path, "multiline strings are unsupported");
  for (let j = i + 1; ; j++) {
    if (j >= text.length || text[j] === "\n") fail(path, "unterminated env assignment");
    if (text[j] === "'") return j;
  }
}

// Parses the array that must follow `env =`. `start` is the offset of `[`.
// Returns the offset just past the closing `]` plus every element's original
// token and decoded value.
function parseArray(text, start, path) {
  const n = text.length;
  const elements = [];
  let i = start + 1;
  for (;;) {
    i = skipTrivia(text, i);
    if (i >= n) fail(path, "unterminated env assignment");
    if (text[i] === "]") {
      i++;
      break;
    }
    // A comma where an element is expected is leading or doubled.
    if (text[i] === ",") fail(path, "malformed env array separator");
    const at = i;
    let close;
    if (text[i] === '"') close = scanBasic(text, i, path);
    else if (text[i] === "'") close = scanLiteral(text, i, path);
    else fail(path, "env array elements must be single-line quoted strings");
    elements.push({
      token: text.slice(at, close + 1),
      value: text.slice(at + 1, close),
      start: at,
      end: close + 1,
    });
    i = skipTrivia(text, close + 1);
    if (i >= n) fail(path, "unterminated env assignment");
    if (text[i] === ",") {
      i++;
      continue;
    }
    if (text[i] === "]") {
      i++;
      break;
    }
    fail(path, "malformed env array separator");
  }
  const end = i;
  // Only whitespace and a trailing comment may follow the closing bracket.
  let j = i;
  while (j < n && (text[j] === " " || text[j] === "\t" || text[j] === "\r")) j++;
  if (j < n && text[j] === "#") while (j < n && text[j] !== "\n") j++;
  if (j < n && text[j] !== "\n") fail(path, "unexpected content after env array");
  return { end, elements };
}

// Parses one top-level `env` key occurrence. `keyStart` is the offset of the
// `env` token; the returned range spans the key through the closing `]` so a
// writer can replace exactly those bytes.
function parseAssignment(text, keyStart, path) {
  const n = text.length;
  let i = skipTrivia(text, keyStart + 3);
  if (i >= n || text[i] !== "=") fail(path, "malformed env assignment");
  i = skipTrivia(text, i + 1);
  if (i >= n) fail(path, "unterminated env assignment");
  // Any scalar is the wrong shape; a string is still scanned first so an
  // unterminated or escaped one reports its own cause.
  if (text[i] === '"') {
    scanBasic(text, i, path);
    fail(path, "env must be an array");
  }
  if (text[i] === "'") {
    scanLiteral(text, i, path);
    fail(path, "env must be an array");
  }
  if (text[i] !== "[") fail(path, "env must be an array");
  const array = parseArray(text, i, path);
  return { keyStart, end: array.end, elements: array.elements };
}

// TOML lets a multiline string end with up to two quotes that belong to its
// content (`"""a""""`), so consume the whole run instead of stopping short.
function quoteRun(text, i) {
  const q = text[i];
  let j = i;
  while (j < text.length && text[j] === q && j - i < 5) j++;
  return j - i;
}

// Header name without brackets, or null when the line is not a closed header.
function headerName(text, i) {
  const double = text[i + 1] === "[";
  let quote = null;
  let name = "";
  for (let j = i + (double ? 2 : 1); j < text.length; j++) {
    const c = text[j];
    if (c === "\n") return null;
    if (quote !== null) {
      if (c === quote) quote = null;
      name += c;
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
      name += c;
      continue;
    }
    if (c === "#") return null;
    if (c === "]") {
      if (double && text[j + 1] !== "]") return null;
      return name.trim();
    }
    name += c;
  }
  return null;
}

function unquote(s) {
  return /^(".*"|'.*')$/s.test(s) ? s.slice(1, -1) : s;
}

// A table header names an absolute key path, so its FIRST segment alone decides
// whether it owns the key pmsec writes: `[env]`, `[env.foo]`, `[ "env" ]`, and
// `["env".x]` all define something under the root `env` table, while `[x.env]`
// and `[envsub]` do not. Segments may be quoted and whitespace may surround the
// dots, so decode the first segment the way TOML would.
//
// deliberate: Issue-#194 subset only; splitting on the first dot is enough
// because only that segment is compared, and a quoted segment keeps its opening
// quote, so a dot inside a quoted key (`["env.foo"]`) can never decode to `env`.
function headerFirstSegment(name) {
  return unquote(name.split(".")[0].trim());
}

// Horizontal whitespace only: a dotted key cannot cross a line, so the forms
// that are tolerated before `=` stay bare-key decisions instead of dotted ones.
function skipBlanks(text, i, n) {
  while (i < n && (text[i] === " " || text[i] === "\t" || text[i] === "\r")) i++;
  return i;
}

// Classifies one line-start token. `bare` is the exact token `env` followed by
// whitespace/`=`/end-of-file; `dotted` is `env` as the first segment of a
// dotted key (`env.foo`, `env . foo`, `"env".foo`), which defines the env table
// rather than the array; `quoted` is `"env"`/`'env'` used as a key, which is out
// of subset. A bare `env` at end-of-file is still `bare`: the empty sentinel
// means the assignment is cut short, never that the key is unrelated.
function classifyKey(text, i, n) {
  const c = text[i];
  if (c === '"' || c === "'") {
    if (text.startsWith(c.repeat(3), i)) return null;
    let raw = "";
    let j = i + 1;
    while (j < n && text[j] !== c) {
      if (text[j] === "\n") return null;
      if (c === '"' && text[j] === "\\") {
        raw += text.slice(j, j + 2);
        j += 2;
        continue;
      }
      raw += text[j];
      j++;
    }
    if (j >= n || raw !== "env") return null;
    if (text[skipBlanks(text, j + 1, n)] === ".") return { kind: "dotted" };
    let k = j + 1;
    while (k < n && (text[k] === " " || text[k] === "\t" || text[k] === "\r" || text[k] === "\n")) k++;
    return text[k] === "=" ? { kind: "quoted" } : null;
  }
  if (text.startsWith("env", i)) {
    const next = i + 3 < n ? text[i + 3] : "";
    if (text[skipBlanks(text, i + 3, n)] === ".") return { kind: "dotted" };
    if (next === "" || BARE_KEY_END.has(next)) return { kind: "bare" };
  }
  return null;
}

// One pass over the whole file. Tracks strings, comments, and value-bracket
// depth so their contents are never read as structure, and records every offset
// the caller needs:
//   rootEnd    - line start of the first depth-0 table header (-1 when there is none)
//   bareEnv    - root-region offsets of bare `env` keys, in file order
//   quotedEnv  - first root-region `"env"`/`'env'` key, or -1
//   dottedEnv  - first `env.` key anywhere, or -1 (fail closed: the subset
//                does not model table scoping, so a nested one is rejected too)
//   envTable   - first `[env...]` header anywhere, or -1
//   openValue  - line start where an array/inline table still open at EOF began, or -1
//   unterminated - a `"""`/`'''` block that never closes
//
// A line start only offers a header or a key at depth 0: inside `key = [` ... `]`
// or `key = {` ... `}` the line is value data, and reading a nested `[` there as
// a header would cut the root region short and point the writer's insertion
// inside the array. Brackets inside strings and comments never move the depth
// because those bytes are consumed in their own states.
//
// deliberate: Issue-#194 subset only; the depth is one counter over both bracket
// kinds. It answers "is a value open", not "does this file nest legally", which
// is the only question the root region and the insertion point ask.
function lex(text) {
  const n = text.length;
  let i = text.startsWith(BOM) ? 1 : 0;
  let state = "code";
  let atLineStart = true;
  let lineStart = i;
  let inRoot = true;
  let rootEnd = -1;
  let quotedEnv = -1;
  let dottedEnv = -1;
  let envTable = -1;
  let depth = 0;
  let openValue = -1;
  const bareEnv = [];

  while (i < n) {
    const c = text[i];
    if (state === "comment") {
      if (c === "\n") {
        state = "code";
        atLineStart = true;
        lineStart = i + 1;
      }
      i++;
      continue;
    }
    if (state === "ml-basic" || state === "ml-literal") {
      const delim = state === "ml-basic" ? '"""' : "'''";
      if (state === "ml-basic" && c === "\\") {
        i += 2;
        atLineStart = false;
        continue;
      }
      if (text.startsWith(delim, i)) {
        state = "code";
        i += quoteRun(text, i);
        atLineStart = false;
        continue;
      }
      atLineStart = c === "\n";
      if (atLineStart) lineStart = i + 1;
      i++;
      continue;
    }
    if (state === "basic" || state === "literal") {
      if (state === "basic" && c === "\\") {
        // A backslash that reaches the end of the line (or the file) does not
        // carry the string over it: the line still ends the string, and the
        // scan resumes in code state on the next line. Escapes strictly within
        // the line keep skipping their pair, so `\"` never closes it.
        if (i + 1 >= n || text[i + 1] === "\n") {
          state = "code";
          i++;
          continue;
        }
        i += 2;
        continue;
      }
      if (c === (state === "basic" ? '"' : "'")) {
        state = "code";
        i++;
        continue;
      }
      // A one-line string cannot span a newline; the subset does not try to
      // validate that, so the line simply ends it.
      if (c === "\n") {
        state = "code";
        atLineStart = true;
        lineStart = i + 1;
      }
      i++;
      continue;
    }
    // state === "code"
    if (c === "\n") {
      atLineStart = true;
      lineStart = i + 1;
      i++;
      continue;
    }
    if (c === " " || c === "\t" || c === "\r" || c === "\f" || c === "\v") {
      i++;
      continue;
    }
    if (c === "#") {
      state = "comment";
      i++;
      continue;
    }
    if (atLineStart) {
      atLineStart = false;
      // A line that starts inside a value continues that value: its first token
      // is array/inline-table data, never a header and never a root key.
      if (depth === 0 && c === "[") {
        const name = headerName(text, i);
        if (inRoot) {
          inRoot = false;
          rootEnd = lineStart;
        }
        if (envTable < 0 && name !== null && headerFirstSegment(name) === "env") envTable = i;
        // The header's own `[` opens no value context: consuming it keeps its
        // matching `]` from being read as a nested closer.
        i++;
        continue;
      }
      if (depth === 0) {
        const key = classifyKey(text, i, n);
        if (key !== null && key.kind === "dotted") {
          // Any `env.` dotted key is rejected, not only a root one: the subset
          // does not model table scoping, so `env.foo` under a header is a
          // shape pmsec cannot reason about and fails closed instead.
          if (dottedEnv < 0) dottedEnv = i;
        } else if (key !== null && inRoot) {
          if (key.kind === "quoted") {
            if (quotedEnv < 0) quotedEnv = i;
          } else {
            bareEnv.push(i);
          }
        }
      }
    }
    if (c === "[" || c === "{") {
      // An array or inline table swallows every following line until its
      // matching closer; remember where the outermost one began so a still-open
      // value at EOF can never become the writer's insertion point.
      if (depth === 0) openValue = lineStart;
      depth++;
      i++;
      continue;
    }
    if (c === "]" || c === "}") {
      // Floored: a header's closing `]` arrives here without a matching open,
      // and a stray closer must not unbalance the lines that follow.
      if (depth > 0) depth--;
      if (depth === 0) openValue = -1;
      i++;
      continue;
    }
    if (c === '"') {
      if (text.startsWith('"""', i)) {
        state = "ml-basic";
        i += 3;
      } else {
        state = "basic";
        i++;
      }
      continue;
    }
    if (c === "'") {
      if (text.startsWith("'''", i)) {
        state = "ml-literal";
        i += 3;
      } else {
        state = "literal";
        i++;
      }
      continue;
    }
    i++;
  }

  return {
    rootEnd,
    bareEnv,
    quotedEnv,
    dottedEnv,
    envTable,
    openValue,
    unterminated: state === "ml-basic" || state === "ml-literal",
  };
}

// Validate everything before a caller can act on the result: a rejected file
// must report one structured reason and never a partial reading.
function analyze(text, path) {
  const lx = lex(text);
  if (lx.quotedEnv >= 0) fail(path, "quoted env key is unsupported");
  // Keep scanning past the first assignment so a second top-level `env` key is
  // reported as a duplicate instead of the first one being returned silently.
  // Only the first occurrence is parsed; once a valid assignment exists, any
  // further `env` key in the root region is already fatal.
  let assignment = null;
  for (const offset of lx.bareEnv) {
    if (assignment !== null) fail(path, "duplicate top-level env assignment");
    assignment = parseAssignment(text, offset, path);
  }
  if (lx.unterminated) fail(path, "unterminated string in file");
  return {
    assignment,
    rootEnd: lx.rootEnd,
    openValue: lx.openValue,
    envTable: lx.envTable,
    dottedEnv: lx.dottedEnv,
  };
}

// Serializes a name the subset can express without escapes: double quotes by
// default, single quotes when the value holds `"` or `\`, and a hard failure
// when neither form can carry it.
function serialize(value, path) {
  if (CONTROL.test(value)) fail(path, "env name cannot be represented without escapes");
  if (!/["\\]/.test(value)) return `"${value}"`;
  if (!value.includes("'")) return `'${value}'`;
  fail(path, "env name cannot be represented without escapes");
}

/**
 * Reads the top-level `env` array of a miserc file.
 * Returns null when the file has no such assignment.
 */
export function readEnv(text, source = "<memory>") {
  const { assignment } = analyze(text, source);
  return assignment === null ? null : assignment.elements.map(element => element.value);
}

/**
 * Returns `text` with its top-level `env` array replaced by one canonical line
 * holding `inherited` (minus any `pmsec`) plus `pmsec` last. Every other byte
 * is preserved. Throws MiseEnvError instead of returning partial output.
 */
export function writePmsecEnv(text, inherited, source = "<memory>") {
  if (!Array.isArray(inherited)) throw new TypeError("inherited must be an array of strings");
  const { assignment, rootEnd, openValue, envTable, dottedEnv } = analyze(text, source);
  // Validate before touching the text: a conflicting shape must never be
  // rewritten, since a later mise would then see two sources for `env`.
  if (envTable >= 0 || dottedEnv >= 0) fail(source, "env table conflicts with the env array");

  const local = assignment === null ? [] : assignment.elements;
  const names = inherited.filter(name => name !== "pmsec").concat("pmsec");
  const tokens = names.map(name => {
    const reuse = local.find(element => element.value === name);
    return reuse === undefined ? serialize(name, source) : reuse.token;
  });
  const line = tokens.length === 0 ? "env = []" : `env = [${tokens.join(", ")}]`;

  if (assignment !== null) {
    return text.slice(0, assignment.keyStart) + line + text.slice(assignment.end);
  }
  // The end of the root region: before the first depth-0 header, otherwise at
  // EOF. A value still open at EOF (a truncated file) ends the region where it
  // began; the file is broken TOML either way, but the new key must not become
  // an element of that value.
  const at = rootEnd >= 0 ? rootEnd : openValue >= 0 ? openValue : text.length;
  const before = text.slice(0, at);
  const separator = before.length > 0 && !before.endsWith("\n") ? "\n" : "";
  return `${before}${separator}${line}\n${text.slice(at)}`;
}
