// Selects mise's effective `env` list and writes pmsec's membership into the
// local miserc only.
//
// deliberate: Issue-#194 selector subset only; mise semantics outside this contract are not modelled. Upgrade path: extend this file per port behind the same contract rather than growing a second selector elsewhere.
//
// Precedence mirrors mise 2026.11.0 exactly: a non-empty MISE_ENV replaces the
// files entirely, and otherwise the first of local -> shared -> system that
// *defines* a top-level `env` wins wholesale. There is no merge across files,
// no `env_sets` expansion, and no trimming inside MISE_ENV.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { misePaths } from "./paths.mjs";
import { writeAtomic } from "./io.mjs";
import { MiseEnvError, readEnv, writePmsecEnv } from "./miseconf.mjs";

const PMSEC = "pmsec";

// mise splits MISE_ENV on commas and drops empty elements, but keeps surrounding
// spaces: `"a, b"` selects "a" and " b", and `",,"` selects nothing. Trimming
// would silently select a different env than mise does.
function tokenize(value) {
  return value.split(",").filter(token => token !== "");
}

// Membership is exact and case-sensitive, wherever it appears: `Pmsec` is a
// distinct mise env name, and a trailing `pmsec` means nothing more than a
// leading one (there is no last-position rule).
function isWired(list) {
  return list.includes(PMSEC);
}

// Absence is the only outcome that may fall through to the next layer. Every
// other failure (EACCES, EISDIR, ...) leaves the effective selection unknown,
// so it fails closed instead of guessing a lower-precedence source.
function readTextOrNull(path) {
  try {
    return readFileSync(path, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw new MiseEnvError("cannot read file", path);
  }
}

// File-based half of the selector, shared by reader and writer on purpose: the
// writer must inherit exactly what mise applies to the local file, and MISE_ENV
// is an invocation-time override that must never be frozen into a file.
function adoptFromFiles(paths) {
  for (const path of [paths.localMiserc, paths.sharedMiserc, paths.systemMiserc]) {
    const text = readTextOrNull(path);
    if (text === null) continue;
    // readEnv throws its own MiseEnvError carrying the parser reason and this
    // file's path; a malformed higher layer must never degrade into a lower one.
    const env = readEnv(text, path);
    // Stop at the first definition, `env = []` included: an empty array is how a
    // higher layer stops inheritance, and the lower layers are then not read at
    // all (they are not part of the effective selection).
    if (env !== null) return { path, env, wired: isWired(env) };
  }
  return { path: paths.localMiserc, env: [], wired: false };
}

/**
 * Returns `{ path, env, wired }` describing the `env` list mise would apply.
 * `path` is "MISE_ENV" for an override, otherwise the file that defined the
 * list (or localMiserc when nothing defined it).
 */
export function readSelector(env = process.env, home = homedir(), platform = process.platform, cwd = process.cwd()) {
  // Checked before any path resolution or read, so a non-empty MISE_ENV makes
  // this function touch no filesystem at all, not even a stat.
  const override = env.MISE_ENV;
  if (typeof override === "string" && override !== "") {
    const tokens = tokenize(override);
    return { path: "MISE_ENV", env: tokens, wired: isWired(tokens) };
  }
  // MISE_ENV="" is defined as unset, so it falls through to the files.
  return adoptFromFiles(misePaths(env, home, platform, cwd));
}

/**
 * Writes pmsec's membership into localMiserc and returns `{ path }`.
 * Async because the atomic writer is; every read, parse, and the full
 * replacement plan complete before the first filesystem write.
 */
export async function writeLocalSelector(env = process.env, home = homedir(), platform = process.platform, cwd = process.cwd()) {
  const paths = misePaths(env, home, platform, cwd);
  // Resolve the inheritance first: an unreadable or malformed source must abort
  // before a single byte is planned, let alone written or backed up.
  const inherited = adoptFromFiles(paths).env;
  // Raw utf-8 instead of readSafe: that helper strips a BOM, and every byte
  // outside the rewritten assignment has to survive unchanged.
  const target = readTextOrNull(paths.localMiserc) ?? "";
  // Planning is pure and throws on a conflicting target shape ([env] table,
  // dotted key, unrepresentable name), so a rejected target never reaches the
  // writer and the target directory is never created.
  const text = writePmsecEnv(target, inherited, paths.localMiserc);
  // The single write, always to localMiserc; shared and system stay read-only.
  await writeAtomic(paths.localMiserc, text);
  return { path: paths.localMiserc };
}
