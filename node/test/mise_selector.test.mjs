import { test } from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { MiseEnvError } from "../src/util/miseconf.mjs";
import { misePaths } from "../src/util/paths.mjs";
import { readSelector, writeLocalSelector } from "../src/util/selector.mjs";

// Every case gets a throwaway mise config tree, injected through MISE_CONFIG_DIR
// and MISE_SYSTEM_CONFIG_DIR so the suite never reads or writes the host's real
// files. The chmod-000 cases rely on the suite running as a non-root user (the
// supported setup); cleanup restores the modes so the tree can still be removed.
const WIN_HOME = "C:\\Users\\user";

// `await` covers both the synchronous reader and the asynchronous writer.
async function rejectionOf(fn) {
  try {
    await fn();
  } catch (error) {
    assert.ok(error instanceof MiseEnvError, `expected MiseEnvError, got ${error}`);
    return error;
  }
  assert.fail("expected MiseEnvError");
}

async function sandbox(t) {
  const root = await mkdtemp(join(tmpdir(), "pmsec-mise-selector-"));
  const configDir = join(root, "config");
  const systemDir = join(root, "system");
  const local = join(configDir, "miserc.local.toml");
  const shared = join(configDir, "miserc.toml");
  const system = join(systemDir, "miserc.toml");
  const restricted = [];
  t.after(async () => {
    for (const path of restricted) await chmod(path, 0o600).catch(() => {});
    await rm(root, { recursive: true, force: true });
  });
  const box = {
    root, configDir, systemDir, local, shared, system,
    // The injection arguments both entry points share. home/cwd stay inside the
    // throwaway root so a resolver change cannot silently escape to the host.
    args(extra = {}) {
      return [
        { MISE_CONFIG_DIR: configDir, MISE_SYSTEM_CONFIG_DIR: systemDir, ...extra },
        join(root, "home"),
        "linux",
        root,
      ];
    },
    async put(path, text) {
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, text, "utf8");
    },
    read: path => readFile(path, "utf8"),
    // A real EACCES for a non-root user; the mode is restored in cleanup.
    async close(path) {
      await chmod(path, 0o000);
      restricted.push(path);
    },
    // A directory where a file is expected: EISDIR on Linux, and unreadable even
    // for root, which keeps the fail-closed contract testable anywhere.
    async block(path) {
      await mkdir(path, { recursive: true });
    },
    async leftovers(path) {
      return (await readdir(dirname(path))).filter(name => name.endsWith(".tmp"));
    },
  };
  return box;
}

// --- reader: MISE_ENV -----------------------------------------------------

test("MISE_ENV splits on commas, drops empty elements, and never trims", async (t) => {
  const box = await sandbox(t);
  const at = extra => readSelector(...box.args(extra));
  assert.deepEqual(at({ MISE_ENV: "a,b" }), { path: "MISE_ENV", env: ["a", "b"], wired: false });
  // Duplicates are preserved: the selector reports mise's list, not a set.
  assert.deepEqual(at({ MISE_ENV: "a,b,a" }), { path: "MISE_ENV", env: ["a", "b", "a"], wired: false });
  assert.deepEqual(at({ MISE_ENV: "a," }), { path: "MISE_ENV", env: ["a"], wired: false });
  assert.deepEqual(at({ MISE_ENV: ",a,,b," }), { path: "MISE_ENV", env: ["a", "b"], wired: false });
  assert.deepEqual(at({ MISE_ENV: ",," }), { path: "MISE_ENV", env: [], wired: false });
  // Surrounding spaces are significant in mise 2026.11.0: " b" is a different env.
  assert.deepEqual(at({ MISE_ENV: "a, b" }), { path: "MISE_ENV", env: ["a", " b"], wired: false });
});

test("wired is exact, case-sensitive membership anywhere in the MISE_ENV list", async (t) => {
  const box = await sandbox(t);
  const at = extra => readSelector(...box.args(extra));
  assert.equal(at({ MISE_ENV: "pmsec" }).wired, true);
  assert.equal(at({ MISE_ENV: "work,pmsec" }).wired, true);
  assert.equal(at({ MISE_ENV: "pmsec,work" }).wired, true);
  assert.equal(at({ MISE_ENV: "work,pmsec,other" }).wired, true);
  // Case and spacing are part of the name, and neither is normalized.
  assert.equal(at({ MISE_ENV: "Pmsec" }).wired, false);
  assert.equal(at({ MISE_ENV: " pmsec" }).wired, false);
  assert.equal(at({ MISE_ENV: "pmsecx" }).wired, false);
  assert.equal(at({ MISE_ENV: "a" }).wired, false);
});

test("a non-empty MISE_ENV performs no filesystem access at all", async (t) => {
  // Every file layer is unreadable: a directory at each path would throw
  // "cannot read file" if the override branch looked at the filesystem.
  const blocked = await sandbox(t);
  await blocked.block(blocked.local);
  await blocked.block(blocked.shared);
  await blocked.block(blocked.system);
  assert.deepEqual(
    readSelector(...blocked.args({ MISE_ENV: "work" })),
    { path: "MISE_ENV", env: ["work"], wired: false },
  );
  // Same claim with a mode-000 file, so the check does not depend on EISDIR.
  const closed = await sandbox(t);
  await closed.put(closed.local, 'env = "not even parseable"\n');
  await closed.close(closed.local);
  assert.deepEqual(
    readSelector(...closed.args({ MISE_ENV: "work" })),
    { path: "MISE_ENV", env: ["work"], wired: false },
  );
});

// --- reader: file fallback ------------------------------------------------

test("MISE_ENV=\"\" counts as unset and falls back to the files", async (t) => {
  const box = await sandbox(t);
  await box.put(box.local, 'env = ["work"]\n');
  const expected = { path: box.local, env: ["work"], wired: false };
  assert.deepEqual(readSelector(...box.args({ MISE_ENV: "" })), expected);
  // Missing MISE_ENV takes the same path.
  assert.deepEqual(readSelector(...box.args()), expected);
});

test("the local file wins and the lower layers are never read", async (t) => {
  const box = await sandbox(t);
  await box.put(box.local, 'env = ["work", "pmsec"]\n');
  // A mode-000 unparseable shared file and a directory as the system file:
  // reading either one after the local definition would throw.
  await box.put(box.shared, 'env = "not an array"\n');
  await box.close(box.shared);
  await box.block(box.system);
  assert.deepEqual(
    readSelector(...box.args()),
    { path: box.local, env: ["work", "pmsec"], wired: true },
  );
});

test("a missing local layer falls through to shared and stops there", async (t) => {
  const box = await sandbox(t);
  await box.put(box.shared, "env = ['y']\n");
  // The system file must not be read once shared defines the list.
  await box.put(box.system, 'env = "not an array"\n');
  await box.close(box.system);
  assert.deepEqual(readSelector(...box.args()), { path: box.shared, env: ["y"], wired: false });
});

test("the system file is the last layer and is adopted wholesale", async (t) => {
  const box = await sandbox(t);
  await box.put(box.system, 'env = ["base", "pmsec"]\n');
  assert.deepEqual(
    readSelector(...box.args()),
    { path: box.system, env: ["base", "pmsec"], wired: true },
  );
});

test("env = [] is a definition that stops inheritance", async (t) => {
  const box = await sandbox(t);
  await box.put(box.local, "env = []\n");
  await box.put(box.shared, 'env = ["shared"]\n');
  assert.deepEqual(readSelector(...box.args()), { path: box.local, env: [], wired: false });
});

test("no file defines env: the empty default is reported against localMiserc", async (t) => {
  const box = await sandbox(t);
  await box.put(box.local, "key = 1\n");
  // An [env] table is not a top-level assignment, so it defines nothing and the
  // reader keeps walking instead of failing.
  await box.put(box.shared, '[env]\n_.path = ["/bin"]\n');
  assert.deepEqual(readSelector(...box.args()), { path: box.local, env: [], wired: false });
});

test("a malformed local file fails closed with the parser's reason", async (t) => {
  const box = await sandbox(t);
  await box.put(box.local, 'env = "work"\n');
  // A valid lower layer is no rescue: a broken higher layer must not degrade.
  await box.put(box.shared, 'env = ["work"]\n');
  const error = await rejectionOf(() => readSelector(...box.args()));
  assert.equal(error.reason, "env must be an array");
  assert.equal(error.path, box.local);
  assert.equal(error.code, "INVALID_MISE_ENV");
  assert.match(error.message, /^invalid env in /);
});

test("an unreadable file fails closed as \"cannot read file\"", async (t) => {
  const box = await sandbox(t);
  await box.put(box.local, 'env = ["work"]\n');
  await box.put(box.shared, 'env = ["work"]\n');
  await box.close(box.local);
  const error = await rejectionOf(() => readSelector(...box.args()));
  assert.equal(error.reason, "cannot read file");
  assert.equal(error.path, box.local);
  // A missing file is the only outcome that may skip a layer, so the same
  // shape as a directory is a read error too.
  const blocked = await sandbox(t);
  await blocked.block(blocked.local);
  const blockedError = await rejectionOf(() => readSelector(...blocked.args()));
  assert.equal(blockedError.reason, "cannot read file");
  assert.equal(blockedError.path, blocked.local);
});

test("a simulated win32 host resolves every layer through misePaths", async (t) => {
  // Pure path shape first: with MISE_CONFIG_DIR unset the local/shared layer is
  // ~/.config/mise (win32 joins), and the system layer hangs off the injected
  // cwd's drive root rather than HOME.
  const win = misePaths({}, WIN_HOME, "win32", "C:\\repo");
  assert.equal(win.localMiserc, "C:\\Users\\user\\.config\\mise\\miserc.local.toml");
  assert.equal(win.sharedMiserc, "C:\\Users\\user\\.config\\mise\\miserc.toml");
  assert.equal(win.systemMiserc, "C:\\etc\\mise\\miserc.toml");
  assert.equal(misePaths({}, WIN_HOME, "win32", "D:\\work").systemMiserc, "D:\\etc\\mise\\miserc.toml");
  // None of those win32-shaped paths exist on the host, so every layer reads as
  // absent and the fallback is reported against the win32 local path.
  assert.deepEqual(
    readSelector({}, WIN_HOME, "win32", "C:\\repo"),
    { path: win.localMiserc, env: [], wired: false },
  );
});

// --- writer ---------------------------------------------------------------

test("write: an empty tree yields exactly the canonical line", async (t) => {
  const box = await sandbox(t);
  // The config directory is a side effect of the write itself, never of planning.
  assert.equal(existsSync(box.configDir), false);
  assert.deepEqual(await writeLocalSelector(...box.args()), { path: box.local });
  assert.equal(await box.read(box.local), 'env = ["pmsec"]\n');
  // The system tree is never created either.
  assert.equal(existsSync(box.systemDir), false);
});

test("write: the shared list is inherited and no other file changes", async (t) => {
  const box = await sandbox(t);
  const sharedText = 'env = ["y", "pmsec", "z"]\n';
  const systemText = 'env = ["sys"]\n';
  await box.put(box.shared, sharedText);
  await box.put(box.system, systemText);
  await writeLocalSelector(...box.args());
  assert.equal(await box.read(box.local), 'env = ["y", "z", "pmsec"]\n');
  assert.equal(await box.read(box.shared), sharedText);
  assert.equal(await box.read(box.system), systemText);
});

test("write: a system-only definition is inherited into the local file", async (t) => {
  const box = await sandbox(t);
  const systemText = "env = ['sys']\n";
  await box.put(box.system, systemText);
  await writeLocalSelector(...box.args());
  assert.equal(await box.read(box.local), 'env = ["sys", "pmsec"]\n');
  assert.equal(await box.read(box.system), systemText);
});

test("write: only the assignment changes; every other byte survives", async (t) => {
  const box = await sandbox(t);
  // BOM, CRLF, a trailing comment, an unrelated table, a single-quoted token,
  // and a missing final newline all sit outside the rewritten range.
  const original = "\uFEFF# top\r\nenv = ['work']  # keep\r\n\r\n[tool]\r\nx = 1";
  await box.put(box.local, original);
  await writeLocalSelector(...box.args());
  assert.equal(
    await box.read(box.local),
    "\uFEFF# top\r\nenv = ['work', \"pmsec\"]  # keep\r\n\r\n[tool]\r\nx = 1",
  );
  assert.equal(await box.read(box.local + ".bak"), original);
});

test("write: re-running is byte-identical and keeps the first backup", async (t) => {
  const box = await sandbox(t);
  const original = 'env = ["work", "pmsec"]\n[tool]\nx = 1\n';
  await box.put(box.local, original);
  await writeLocalSelector(...box.args());
  // The list was already in target shape, so the planned bytes equal the
  // original and the file is rewritten with identical content.
  const once = await box.read(box.local);
  assert.equal(once, 'env = ["work", "pmsec"]\n[tool]\nx = 1\n');
  const backup = await box.read(box.local + ".bak");
  assert.equal(backup, original);
  await writeLocalSelector(...box.args());
  assert.equal(await box.read(box.local), once);
  assert.equal(await box.read(box.local + ".bak"), original);
  assert.deepEqual(await box.leftovers(box.local), []);
});

test("write: MISE_ENV never becomes the inherited list", async (t) => {
  // No file defines env: the override must not be frozen into the written file.
  const empty = await sandbox(t);
  await writeLocalSelector(...empty.args({ MISE_ENV: "a,b" }));
  assert.equal(await empty.read(empty.local), 'env = ["pmsec"]\n');
  // The file-based definition still wins over the override for inheritance.
  const sharedBox = await sandbox(t);
  await sharedBox.put(sharedBox.shared, 'env = ["y"]\n');
  await writeLocalSelector(...sharedBox.args({ MISE_ENV: "a,b" }));
  assert.equal(await sharedBox.read(sharedBox.local), 'env = ["y", "pmsec"]\n');
});

test("write: a local env = [] definition yields the single pmsec entry", async (t) => {
  const box = await sandbox(t);
  await box.put(box.local, "env = []\n");
  await box.put(box.shared, 'env = ["shared"]\n');
  await writeLocalSelector(...box.args());
  assert.equal(await box.read(box.local), 'env = ["pmsec"]\n');
  assert.equal(await box.read(box.shared), 'env = ["shared"]\n');
});

test("write: a malformed shared file aborts before the local file is touched", async (t) => {
  const box = await sandbox(t);
  const localText = "key = 1\n";
  const sharedText = 'env = "boom"\n';
  await box.put(box.local, localText);
  await box.put(box.shared, sharedText);
  const error = await rejectionOf(() => writeLocalSelector(...box.args()));
  assert.equal(error.reason, "env must be an array");
  assert.equal(error.path, box.shared);
  assert.equal(await box.read(box.local), localText);
  assert.equal(existsSync(box.local + ".bak"), false);
  assert.deepEqual(await box.leftovers(box.local), []);
  assert.equal(await box.read(box.shared), sharedText);
});

test("write: a local [env] table is rejected without changing anything", async (t) => {
  const box = await sandbox(t);
  const original = 'env = ["work"]\n\n[env]\n_.path = ["/bin"]\n';
  await box.put(box.local, original);
  const error = await rejectionOf(() => writeLocalSelector(...box.args()));
  assert.equal(error.reason, "env table conflicts with the env array");
  assert.equal(error.path, box.local);
  assert.equal(await box.read(box.local), original);
  assert.equal(existsSync(box.local + ".bak"), false);
  assert.deepEqual(await box.leftovers(box.local), []);
});

test("write: an unreadable shared file aborts before the local file is touched", async (t) => {
  const box = await sandbox(t);
  const localText = "key = 1\n";
  await box.put(box.local, localText);
  await box.put(box.shared, 'env = ["y"]\n');
  await box.close(box.shared);
  const error = await rejectionOf(() => writeLocalSelector(...box.args()));
  assert.equal(error.reason, "cannot read file");
  assert.equal(error.path, box.shared);
  assert.equal(await box.read(box.local), localText);
  assert.equal(existsSync(box.local + ".bak"), false);
  assert.deepEqual(await box.leftovers(box.local), []);
});

test("write: a failing run never creates the target directory", async (t) => {
  const box = await sandbox(t);
  // No config tree at all: the only source is a system file that rejects, so
  // the failure happens during inheritance and the directory must stay absent.
  await box.put(box.system, 'env = "boom"\n');
  assert.equal(existsSync(box.configDir), false);
  const error = await rejectionOf(() => writeLocalSelector(...box.args()));
  assert.equal(error.reason, "env must be an array");
  assert.equal(error.path, box.system);
  assert.equal(existsSync(box.configDir), false);
});
