import { test } from "node:test";
import assert from "node:assert/strict";
import { MiseEnvError, readEnv, writePmsecEnv } from "../src/util/miseconf.mjs";

// These suites are pure: every input and expectation is an in-memory string, so
// the parser contract is pinned without touching a filesystem or a mise binary.

function rejection(fn) {
  try {
    fn();
  } catch (error) {
    assert.ok(error instanceof MiseEnvError, `expected MiseEnvError, got ${error}`);
    return error;
  }
  assert.fail("expected MiseEnvError");
}

function reasonOf(fn) {
  return rejection(fn).reason;
}

// --- read: accepted forms -------------------------------------------------

test("read: a file without an env assignment is not defined", () => {
  assert.equal(readEnv(""), null);
  assert.equal(readEnv('title = "my miserc"\n'), null);
});

test("read: an [env] table alone is not a top-level env assignment", () => {
  assert.equal(readEnv('[env]\n_.path = ["/bin"]\n'), null);
});

test("read: bare env.foo dotted keys alone are not a top-level env assignment", () => {
  assert.equal(readEnv('env.foo = "bar"\nenv.baz = "qux"\n'), null);
  // Dotted keys are TOML, not env-array syntax, and the whitespace/quoted forms
  // are the same key: `env . foo` must not fall back to "malformed" (it used to
  // be classed as a bare key because the dot was not adjacent).
  for (const key of ["env . foo = 1", '"env".foo = 1', "'env'.foo = 1", 'env."foo" = 1', 'env . "foo" = 1']) {
    assert.equal(readEnv(`${key}\n`), null, key);
  }
});

test("read: envelope and envsub are unrelated keys, including at EOF", () => {
  assert.equal(readEnv("envelope = true\n"), null);
  assert.equal(readEnv('envelope = ["a"]\n'), null);
  assert.equal(readEnv("envelope"), null);
  assert.equal(readEnv("envsub = 1\n"), null);
  assert.equal(readEnv("envsub"), null);
});

test("read: empty array", () => {
  assert.deepEqual(readEnv("env = []\n"), []);
  assert.deepEqual(readEnv("env = [\n]\n"), []);
  assert.deepEqual(readEnv("env = [  ]"), []);
});

test("read: inline arrays", () => {
  assert.deepEqual(readEnv('env = ["a"]\n'), ["a"]);
  assert.deepEqual(readEnv('env = ["a", "b"]\n'), ["a", "b"]);
  assert.deepEqual(readEnv('env=["a","b"]'), ["a", "b"]);
});

test("read: multiline array with comments between tokens", () => {
  const text = [
    "env = [",
    '  "a", # first',
    "  # a whole comment line",
    "  'b',",
    "]",
    "",
  ].join("\n");
  assert.deepEqual(readEnv(text), ["a", "b"]);
});

test("read: comments and newlines are allowed around the assignment", () => {
  assert.deepEqual(readEnv('env # key\n  = [ # open\n  "a" # elem\n  ] # close\n'), ["a"]);
});

test("read: an optional trailing comma is accepted", () => {
  assert.deepEqual(readEnv('env = ["a", "b",]\n'), ["a", "b"]);
  assert.deepEqual(readEnv('env = [\n  "a",\n]\n'), ["a"]);
});

test("read: a single-quoted element keeps backslashes literally", () => {
  assert.deepEqual(readEnv("env = ['say\\hi']\n"), ["say\\hi"]);
  assert.deepEqual(readEnv("env = ['a\\nb']\n"), ["a\\nb"]);
});

test("read: quoted names may hold #, brackets, commas, and spaces", () => {
  assert.deepEqual(readEnv('env = ["a # b", "c[d]", "e,f", " g ", \'h"i\']\n'), [
    "a # b",
    "c[d]",
    "e,f",
    " g ",
    'h"i',
  ]);
});

test("read: names are opaque unicode strings", () => {
  assert.deepEqual(readEnv('env = ["日本語", "ünïcode", "emoji🙂"]\n'), ["日本語", "ünïcode", "emoji🙂"]);
});

test("read: duplicate names inside one array are preserved in order", () => {
  assert.deepEqual(readEnv('env = ["a", "b", "a"]\n'), ["a", "b", "a"]);
});

test("read: leading indentation before the key is accepted", () => {
  assert.deepEqual(readEnv('  env = ["a"]\n'), ["a"]);
  assert.deepEqual(readEnv('\t env = ["a"]\n'), ["a"]);
});

test("read: env-like text inside comments is ignored", () => {
  assert.equal(readEnv('# env = ["nope"]\nkey = 1\n'), null);
  assert.equal(readEnv('key = 1 # env = ["nope"]\n'), null);
});

test("read: env-like text inside an unrelated multiline string is ignored", () => {
  const text = [
    'note = """',
    'env = ["nope"]',
    "[also-not-a-table]",
    '"""',
    'env = ["real"]',
  ].join("\n");
  assert.deepEqual(readEnv(text), ["real"]);
});

test("read: env-like text inside an unrelated one-line string is ignored", () => {
  assert.equal(readEnv('note = "the env = [...] form is documented"\n'), null);
  assert.equal(readEnv('note = \'env = []\'\n'), null);
});

test("read: a one-line string ends with its line, trailing backslash or not", () => {
  // The subset does not validate general TOML: a backslash at the end of the
  // line does not let a one-line string cross it, so the next line is read as
  // structure again and its bare `env` key is still found.
  assert.deepEqual(readEnv('x = "abc\\\nenv = ["work"]\n'), ["work"]);
  assert.deepEqual(readEnv("x = 'abc\\\nenv = ['work']\n"), ["work"]);
  // An escaped quote inside the line is not a closer; the line still ends it.
  assert.deepEqual(readEnv('x = "a\\"b\nenv = ["work"]\n'), ["work"]);
  // An assignment before that opener is read rather than swallowed by it.
  assert.deepEqual(readEnv('env = ["work"]\nx = "abc\\'), ["work"]);
});

test("read: a table header after a multiline string still ends the root region", () => {
  const text = ['note = """', "[t]", '"""', "[tool.env]", 'env = ["nested"]'].join("\n");
  assert.equal(readEnv(text), null);
});

test("read: an env key inside a table body is not top-level", () => {
  assert.equal(readEnv('[tool]\nenv = ["nested"]\n'), null);
});

test("read: a line-start bracket inside an open array is value data, not a header", () => {
  // The nested `[1, 2],` used to be read as a table header, which ended the
  // root region early and hid the real assignment below it.
  assert.deepEqual(readEnv('items = [\n  [1, 2],\n]\nenv = ["work"]\n'), ["work"]);
  assert.deepEqual(readEnv('items = [\n  ["env"],\n]\nenv = ["work"]\n'), ["work"]);
});

test("read: a line-start key inside an open inline table is value data", () => {
  assert.deepEqual(readEnv('x = { a = 1,\n  b = 2 }\nenv = ["work"]\n'), ["work"]);
  assert.deepEqual(readEnv('x = { a = [1],\n  b = 2 }\nenv = ["work"]\n'), ["work"]);
});

test("read: a header after a nested array still ends the root region", () => {
  assert.equal(readEnv('items = [\n  [1, 2],\n]\n[t]\nenv = ["nested"]\n'), null);
});

test("read: a leading BOM is skipped", () => {
  assert.deepEqual(readEnv('\uFEFFenv = ["a"]\n'), ["a"]);
});

test("read: CRLF files are accepted", () => {
  assert.deepEqual(readEnv('env = [\r\n  "a",\r\n  "b",\r\n]\r\n[t]\r\n'), ["a", "b"]);
});

// --- read: rejected forms -------------------------------------------------

test("reject: quoted env key is unsupported", () => {
  assert.equal(reasonOf(() => readEnv('"env" = ["a"]\n')), "quoted env key is unsupported");
  assert.equal(reasonOf(() => readEnv("'env' = ['a']\n")), "quoted env key is unsupported");
  assert.equal(reasonOf(() => readEnv('  "env"\t= ["a"]\n')), "quoted env key is unsupported");
});

test("reject: a second top-level env assignment is a duplicate", () => {
  const text = 'env = ["a"]\n# between them\nenv = ["b"]\n';
  assert.equal(reasonOf(() => readEnv(text)), "duplicate top-level env assignment");
});

test("reject: duplicate detection continues past the first valid assignment", () => {
  const text = 'env = [\n  "a",\n]\nkey = 1\nenv = []\n';
  assert.equal(reasonOf(() => readEnv(text)), "duplicate top-level env assignment");
});

test("reject: a scalar env value must be an array", () => {
  assert.equal(reasonOf(() => readEnv('env = "work"\n')), "env must be an array");
  assert.equal(reasonOf(() => readEnv("env = 'work'\n")), "env must be an array");
  assert.equal(reasonOf(() => readEnv("env = 1\n")), "env must be an array");
  assert.equal(reasonOf(() => readEnv("env = true\n")), "env must be an array");
  assert.equal(reasonOf(() => readEnv('env = { a = "b" }\n')), "env must be an array");
});

test("reject: array elements must be single-line quoted strings", () => {
  for (const value of ["work", "1", "true", "1.5", '["a"]', '{ a = "b" }']) {
    assert.equal(
      reasonOf(() => readEnv(`env = [${value}]\n`)),
      "env array elements must be single-line quoted strings",
      `element ${value}`,
    );
  }
});

test("reject: escape sequences inside a basic string element", () => {
  assert.equal(reasonOf(() => readEnv('env = ["a\\nb"]\n')), "escape sequences are unsupported");
  assert.equal(reasonOf(() => readEnv('env = ["say\\"hi"]\n')), "escape sequences are unsupported");
});

test("reject: multiline string elements", () => {
  assert.equal(reasonOf(() => readEnv('env = ["""a"""]\n')), "multiline strings are unsupported");
  assert.equal(reasonOf(() => readEnv("env = ['''a''']\n")), "multiline strings are unsupported");
});

test("reject: an unterminated string or array", () => {
  assert.equal(reasonOf(() => readEnv('env = ["a"\n')), "unterminated env assignment");
  assert.equal(reasonOf(() => readEnv("env = [\n")), "unterminated env assignment");
  assert.equal(reasonOf(() => readEnv('env = ["a')), "unterminated env assignment");
  assert.equal(reasonOf(() => readEnv("env = ")), "unterminated env assignment");
});

test("reject: malformed env assignment", () => {
  assert.equal(reasonOf(() => readEnv('env ["a"]\n')), "malformed env assignment");
  assert.equal(reasonOf(() => readEnv("env\n")), "malformed env assignment");
  assert.equal(reasonOf(() => readEnv("env\nkey = 1\n")), "malformed env assignment");
  // A file that ends with the bare key has no `=` at all: the empty sentinel is
  // end-of-key, never evidence of an unrelated token, so it fails closed too.
  assert.equal(reasonOf(() => readEnv("env")), "malformed env assignment");
  assert.equal(reasonOf(() => readEnv("env   ")), "malformed env assignment");
  assert.equal(reasonOf(() => readEnv("# note\nenv")), "malformed env assignment");
});

test("reject: malformed env array separator", () => {
  assert.equal(reasonOf(() => readEnv('env = ["a" "b"]\n')), "malformed env array separator");
  assert.equal(reasonOf(() => readEnv('env = [, "a"]\n')), "malformed env array separator");
  assert.equal(reasonOf(() => readEnv('env = ["a",, "b"]\n')), "malformed env array separator");
});

test("reject: content after the closing bracket", () => {
  assert.equal(reasonOf(() => readEnv('env = ["a"] junk\n')), "unexpected content after env array");
  assert.equal(reasonOf(() => readEnv('env = ["a"] ["b"]\n')), "unexpected content after env array");
});

test("reject: an unrelated multiline string that never closes", () => {
  assert.equal(reasonOf(() => readEnv('note = """abc\n')), "unterminated string in file");
  assert.equal(reasonOf(() => readEnv("note = '''\n[t]\n")), "unterminated string in file");
});

test("error carries the source label, code, reason, and message shape", () => {
  const error = rejection(() => readEnv("env = 1\n", "/home/user/.config/mise/miserc.local.toml"));
  assert.equal(error.code, "INVALID_MISE_ENV");
  assert.equal(error.path, "/home/user/.config/mise/miserc.local.toml");
  assert.equal(error.reason, "env must be an array");
  assert.equal(error.message, "invalid env in /home/user/.config/mise/miserc.local.toml: env must be an array");
  assert.ok(error instanceof Error);
});

test("the default source label is <memory>", () => {
  assert.equal(rejection(() => readEnv("env = 1\n")).message, "invalid env in <memory>: env must be an array");
});

// --- write ----------------------------------------------------------------

test("write: empty input produces exactly the canonical line", () => {
  assert.equal(writePmsecEnv("", []), 'env = ["pmsec"]\n');
});

test("write: inherited names are placed before pmsec", () => {
  assert.equal(writePmsecEnv("", ["work"]), 'env = ["work", "pmsec"]\n');
  assert.equal(writePmsecEnv("", ["a", "b"]), 'env = ["a", "b", "pmsec"]\n');
});

test("write: an existing pmsec is removed from the front and re-appended once", () => {
  assert.equal(writePmsecEnv('env = ["pmsec", "work"]\n', ["work"]), 'env = ["work", "pmsec"]\n');
});

test("write: an existing pmsec in the middle is moved to the end", () => {
  assert.equal(
    writePmsecEnv('env = ["work", "pmsec", "other"]\n', ["work", "other"]),
    'env = ["work", "other", "pmsec"]\n',
  );
});

test("write: duplicated pmsec is collapsed to a single trailing entry", () => {
  assert.equal(
    writePmsecEnv('env = ["pmsec", "work", "pmsec"]\n', ["work", "pmsec"]),
    'env = ["work", "pmsec"]\n',
  );
});

test("write: a multiline array becomes one line with no residue", () => {
  const text = 'env = [\n  "a", # one\n  "b",\n]\nkey = 1\n';
  assert.equal(writePmsecEnv(text, ["a", "b"]), 'env = ["a", "b", "pmsec"]\nkey = 1\n');
});

test("write: unrelated bytes are preserved (BOM, comment, indentation, tables)", () => {
  const text = "\uFEFF# top\n  env = ['work']  # keep\n\n[tool]\nx = 1\n";
  assert.equal(
    writePmsecEnv(text, ["work"]),
    "\uFEFF# top\n  env = ['work', \"pmsec\"]  # keep\n\n[tool]\nx = 1\n",
  );
});

test("write: CRLF and a missing final newline are preserved", () => {
  const text = 'a = 1\r\nenv = ["a"]\r\n[t]\r\nx = 1';
  assert.equal(writePmsecEnv(text, ["a"]), 'a = 1\r\nenv = ["a", "pmsec"]\r\n[t]\r\nx = 1');
});

test("write: an absent assignment is inserted before the first table", () => {
  assert.equal(
    writePmsecEnv("a = 1\nb = 2\n[t]\nx = 1\n", []),
    'a = 1\nb = 2\nenv = ["pmsec"]\n[t]\nx = 1\n',
  );
});

test("write: an absent assignment is appended when there is no table", () => {
  assert.equal(writePmsecEnv("a = 1", []), 'a = 1\nenv = ["pmsec"]\n');
  assert.equal(writePmsecEnv("a = 1\n", []), 'a = 1\nenv = ["pmsec"]\n');
});

test("write: a nested array before the assignment is never touched", () => {
  const text = 'items = [\n  [1, 2],\n]\nenv = ["work"]\n';
  // Only the real assignment moves: the insertion used to land inside the open
  // array, which both corrupted the array and left the old env line behind.
  assert.equal(writePmsecEnv(text, ["work"]), 'items = [\n  [1, 2],\n]\nenv = ["work", "pmsec"]\n');
});

test("write: a nested array after the assignment stays byte-identical", () => {
  const text = 'env = ["work"]\nitems = [\n  [1, 2],\n]\n';
  assert.equal(writePmsecEnv(text, ["work"]), 'env = ["work", "pmsec"]\nitems = [\n  [1, 2],\n]\n');
});

test("write: an inline table before the insertion point does not move it", () => {
  assert.equal(
    writePmsecEnv("x = { a = 1 }\n[t]\nx = 1\n", []),
    'x = { a = 1 }\nenv = ["pmsec"]\n[t]\nx = 1\n',
  );
  assert.equal(
    writePmsecEnv('x = { a = 1 }\nenv = ["work"]\n', ["work"]),
    'x = { a = 1 }\nenv = ["work", "pmsec"]\n',
  );
});

test("write: a header that follows a nested array is still the root end", () => {
  assert.equal(
    writePmsecEnv('items = [\n  [1, 2],\n]\n[t]\nx = 1\n', []),
    'items = [\n  [1, 2],\n]\nenv = ["pmsec"]\n[t]\nx = 1\n',
  );
});

test("write: a value still open at EOF keeps the insertion outside it", () => {
  // A truncated file is broken TOML either way, but the value's own line start
  // is the last point still in root scope, so the key cannot become an element.
  assert.equal(writePmsecEnv("a = 1\nx = [\n  1,\n", []), 'a = 1\nenv = ["pmsec"]\nx = [\n  1,\n');
  assert.equal(writePmsecEnv("a = 1\nx = { b = 1\n", []), 'a = 1\nenv = ["pmsec"]\nx = { b = 1\n');
});

test("write: the original single-quoted token is reused", () => {
  assert.equal(writePmsecEnv("env = ['work']\n", ["work"]), "env = ['work', \"pmsec\"]\n");
});

test("write: names unknown to the local array are serialized with double quotes", () => {
  const text = 'env = ["a"]\n';
  assert.equal(writePmsecEnv(text, ["elsewhere"]), 'env = ["elsewhere", "pmsec"]\n');
  assert.equal(writePmsecEnv(text, ["elsewhere", "a"]), 'env = ["elsewhere", "a", "pmsec"]\n');
});

test("write: a name holding a double quote is single-quoted", () => {
  assert.equal(writePmsecEnv("", ['say"hi']), "env = ['say\"hi', \"pmsec\"]\n");
});

test("write: a name holding a backslash is single-quoted", () => {
  assert.equal(writePmsecEnv("", ["back\\slash"]), "env = ['back\\slash', \"pmsec\"]\n");
});

test("write: a name with both quote kinds is unrepresentable", () => {
  assert.equal(
    reasonOf(() => writePmsecEnv("", [`it's "quoted"`])),
    "env name cannot be represented without escapes",
  );
});

test("write: a name with control characters is unrepresentable", () => {
  assert.equal(reasonOf(() => writePmsecEnv("", ["a\tb"])), "env name cannot be represented without escapes");
  assert.equal(reasonOf(() => writePmsecEnv("", ["a\nb"])), "env name cannot be represented without escapes");
});

test("write: an [env] table conflicts with the array", () => {
  const text = 'env = ["a"]\n\n[env]\n_.path = ["/bin"]\n';
  assert.equal(reasonOf(() => writePmsecEnv(text, ["a"])), "env table conflicts with the env array");
});

test("write: every header whose first segment decodes to env conflicts", () => {
  // A header names an absolute path, so the first segment alone decides: these
  // all declare keys under the root env table that the array would collide with.
  for (const header of [
    "[env]",
    "[env.foo]",
    "[ env ]",
    '["env"]',
    "['env']",
    '[ "env" ]',
    '["env".x]',
    '[ "env" . "x" ]',
    '[env."foo"]',
    "[[env]]",
    "[[env.foo]]",
  ]) {
    assert.equal(
      reasonOf(() => writePmsecEnv(`${header}\n_.path = ["/bin"]\n`, [])),
      "env table conflicts with the env array",
      header,
    );
  }
});

test("write: a header whose first segment is not env does not conflict", () => {
  // `["env.foo"]` is one quoted key that merely spells a dot, not the env table.
  for (const header of ["[x.env]", "[envsub]", "[tool.env]", "[envs]", "['x.env']", '["env.foo"]']) {
    assert.equal(writePmsecEnv(`${header}\n`, []), `env = ["pmsec"]\n${header}\n`, header);
  }
});

test("write: a bare env.foo dotted key conflicts with the array", () => {
  assert.equal(reasonOf(() => writePmsecEnv('env.foo = "bar"\n', [])), "env table conflicts with the env array");
});

test("write: every root dotted env key conflicts, spaced or quoted included", () => {
  for (const key of [
    "env.foo = 1",
    "env . foo = 1",
    '"env".foo = 1',
    "'env'.foo = 1",
    'env."foo" = 1',
    'env . "foo" = 1',
    '"env" . "foo" = 1',
  ]) {
    assert.equal(reasonOf(() => writePmsecEnv(`${key}\n`, [])), "env table conflicts with the env array", key);
  }
});

test("write: a dotted env key under a table header still fails closed", () => {
  // The subset does not model table scoping, so this line would mean
  // `tool.env.foo` in mise and not collide with the array -- but a shape pmsec
  // cannot place is rejected rather than guessed at, matching the other ports.
  assert.equal(reasonOf(() => writePmsecEnv("[tool]\nenv.foo = 1\n", [])), "env table conflicts with the env array");
  assert.equal(readEnv("[tool]\nenv.foo = 1\n"), null);
});

test("write: env matching is case-sensitive, so [ENV] and Env stay unrelated", () => {
  assert.equal(writePmsecEnv("[ENV]\n", []), 'env = ["pmsec"]\n[ENV]\n');
  assert.equal(writePmsecEnv('Env = ["a"]\n', []), 'Env = ["a"]\nenv = ["pmsec"]\n');
  assert.equal(writePmsecEnv('"ENV" = ["a"]\n', []), '"ENV" = ["a"]\nenv = ["pmsec"]\n');
  assert.equal(readEnv('"ENV" = ["a"]\n'), null);
  assert.equal(readEnv('Env = ["a"]\n'), null);
});

test("write: a truncated bare env at EOF fails closed", () => {
  assert.equal(reasonOf(() => writePmsecEnv("env", [])), "malformed env assignment");
  assert.equal(reasonOf(() => writePmsecEnv("# note\nenv", [])), "malformed env assignment");
});

test("write: writing the same inherited list twice is byte-identical", () => {
  const text = 'env = [\n  "a",\n]\n[tool]\nx = 1\n';
  const once = writePmsecEnv(text, ["a"]);
  assert.equal(writePmsecEnv(once, ["a"]), once);
  assert.equal(writePmsecEnv(writePmsecEnv("", []), []), 'env = ["pmsec"]\n');
});

test("write: a rejected input throws before returning any text", () => {
  const text = 'env = ["a" "b"]\n';
  assert.equal(reasonOf(() => writePmsecEnv(text, [])), "malformed env array separator");
  assert.equal(reasonOf(() => writePmsecEnv('env = ["a"\n', [])), "unterminated env assignment");
  assert.equal(reasonOf(() => writePmsecEnv('note = """abc\n', [])), "unterminated string in file");
});

test("write: round-trips through read, and the result reads back the target list", () => {
  const text = 'env = ["old", "pmsec"]\nkey = 1\n';
  const out = writePmsecEnv(text, ["old", "new"]);
  assert.equal(out, 'env = ["old", "new", "pmsec"]\nkey = 1\n');
  assert.deepEqual(readEnv(out), ["old", "new", "pmsec"]);
});
