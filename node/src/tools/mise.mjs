import { existsSync, lstatSync, readFileSync, realpathSync, statSync } from "node:fs";
import { unlink } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import {
  miseConfigPath, miseConfigDir, miseBaseConfigPath, misePmsecConfigPath,
  miseEnvConfigPath, miseLocalMisercPath, miseSharedMisercPath, miseSystemMisercPath,
} from "../util/paths.mjs";
import { readSafe, writeAtomic } from "../util/io.mjs";
import { readKey, setKey, removeKey } from "../util/lines.mjs";
import { readExtras, applyExtras, removeExtras } from "../util/extras.mjs";
import { buildPreflight, detectVersion, gte } from "../util/version.mjs";
import { parseEnv, setEnvValues, removeEnvValue, envListFrom } from "../util/miseconf.mjs";

export const name = "mise";
export const key = "minimum_release_age";
export const section = "settings";
export const docs = "https://mise.jdx.dev/configuration/settings.html#minimum_release_age";
export const minBin = [2026, 4, 22];
export const newModeMin = [2026, 11, 0];
export const extras = [
  { key: "paranoid", expected: "true", line: "paranoid = true", section },
  { key: "gpg_verify", expected: "true", line: "gpg_verify = true", section },
  { key: "github_attestations", expected: "true", line: "github_attestations = true", section },
  { key: "slsa", expected: "true", line: "slsa = true", section },
  { key: "locked_verify_provenance", expected: "true", line: "locked_verify_provenance = true", section },
  { key: "ruby.github_attestations", expected: "true", line: "ruby.github_attestations = true", section },
  { key: "python.github_attestations", expected: "true", line: "python.github_attestations = true", section },
  { key: "provenance_api_failures_fatal", expected: "true", line: "provenance_api_failures_fatal = true", section },
  { key: "aqua.github_attestations", expected: "true", line: "aqua.github_attestations = true", section },
  { key: "aqua.cosign", expected: "true", line: "aqua.cosign = true", section },
  { key: "aqua.minisign", expected: "true", line: "aqua.minisign = true", section },
  { key: "aqua.slsa", expected: "true", line: "aqua.slsa = true", section },
  { key: "github.github_attestations", expected: "true", line: "github.github_attestations = true", section },
  { key: "github.slsa", expected: "true", line: "github.slsa = true", section },
  { key: "node.gpg_verify", expected: "true", line: "node.gpg_verify = true", section },
  { key: "swift.gpg_verify", expected: "true", line: "swift.gpg_verify = true", section },
  { key: "not_found_system_fallback", expected: "false", line: "not_found_system_fallback = false", section },
];

export const preflight = buildPreflight(name, minBin,
  "setting was named install_before before 2026.4.22 and minimum_release_age is silently ignored on older mise. Upgrade mise (`mise self-update`) to enforce the cooldown.");

const MIGRATION_WARN = "a previous new-style mise configuration exists (config.pmsec.toml or the pmsec miserc selector); run `pmsec` to consolidate it";
const MISE_ENV_WARN = "MISE_ENV overrides miserc and the pmsec environment is not active in this shell";

export function path(ctx) { return miseConfigPath(ctx.env, ctx.home, ctx.platform); }

export function paths(ctx) {
  return {
    legacy: miseConfigPath(ctx.env, ctx.home, ctx.platform),
    dir: miseConfigDir(ctx.env, ctx.home),
    base: miseBaseConfigPath(ctx.env, ctx.home),
    pmsec: misePmsecConfigPath(ctx.env, ctx.home),
    local: miseLocalMisercPath(ctx.env, ctx.home),
    shared: miseSharedMisercPath(ctx.env, ctx.home),
    system: miseSystemMisercPath(ctx.env, ctx.home, ctx.platform),
  };
}

function parseDays(value) {
  if (value === null) return null;
  const m = value.match(/^"?\s*(\d+)\s*(d|days?|w|weeks?|m|months?|y|years?)\s*"?$/i);
  if (!m) return null;
  const n = Number(m[1]);
  const unit = m[2].toLowerCase();
  if (/^(w|weeks?)$/.test(unit)) return n * 7;
  if (/^(m|months?)$/.test(unit)) return n * 30;
  if (/^(y|years?)$/.test(unit)) return n * 365;
  return n;
}

function supportsNewMode(ctx) {
  const v = detectVersion("mise", ["--version"], { env: ctx.env, overrideKey: "PMSEC_MISE_VERSION" });
  return gte(v, newModeMin) === true && !ctx.env.MISE_GLOBAL_CONFIG_FILE;
}

async function hasNewArtifacts(ctx, p) {
  // A leftover config.pmsec.toml that defines no managed keys and is not
  // selected anywhere is inert — mise loads the layer only when the pmsec
  // environment is active — so legacy mode must converge instead of failing
  // forever on a file the cleanup intentionally keeps. An artifact is an
  // active selector (MISE_ENV or the effective miserc) or managed keys in the
  // file. Only the first miserc that defines env counts: a pmsec name in a
  // lower-precedence miserc is shadowed and never selects the layer. A
  // nonempty MISE_ENV replaces the miserc list entirely, so the miserc files
  // are not scanned when the variable names any environment.
  const envList = envListFrom(ctx.env.MISE_ENV);
  if (envList.includes("pmsec")) return true;
  if (envList.length === 0) {
    for (const file of [p.local, p.shared, p.system]) {
      if (!existsSync(file)) continue;
      // A read error propagates: an unreadable selector may still activate pmsec.
      const text = await readSafe(file);
      let parsed;
      try { parsed = parseEnv(text); } catch { continue; /* surfaced by the selector paths */ }
      if (!parsed.defined) continue;
      if (parsed.values.includes("pmsec")) return true;
      break;
    }
  }
  // An aliased pmsec file is the legacy destination itself, not a leftover.
  if (aliasState(p) === "aliased") return false;
  // An unreadable pmsec file may hold managed keys: propagate the error so a
  // legacy check cannot report OK from a file it could not inspect.
  const r = readOne(await readSafe(p.pmsec));
  if (r.configured !== null || r.extras.some(e => e.configured !== null)) return true;
  return false;
}

// MISE_GLOBAL_CONFIG_FILE can point at <MISE_CONFIG_DIR>/config.pmsec.toml;
// then the legacy destination IS the new generation and the reverse-migration
// cleanup must not remove what it just wrote (or delete the global config).
// Absolute path with the directory's symlinks resolved, so different
// spellings of the same file (relative, via a symlinked dir) compare equal.
function canonicalPath(file) {
  const abs = resolve(file);
  try { return join(realpathSync(dirname(abs)), basename(abs)); } catch { return abs; }
}

// ENOENT is only proof of absence when the nearest existing ancestor is a
// real directory; a dangling symlink ancestor leaves the outcome unknown.
function provablyMissing(file) {
  let dir = dirname(resolve(file));
  for (;;) {
    let st;
    try { st = lstatSync(dir, { bigint: true }); }
    catch (e) {
      if (e?.code === "ENOENT" || e?.code === "ENOTDIR") { dir = dirname(dir); continue; }
      return false;
    }
    return st.isDirectory();
  }
}

// "missing", null when the identity cannot be determined, else dev:ino.
function fileId(file) {
  try {
    const s = statSync(file, { bigint: true });
    return s.ino === 0n ? null : `${s.dev}:${s.ino}`;
  } catch (e) {
    if (e?.code !== "ENOENT" && e?.code !== "ENOTDIR") return null;
    return provablyMissing(file) ? "missing" : null;
  }
}

// File identity catches spellings a path comparison cannot: case variants on
// case-insensitive filesystems, junctions, 8.3 short names, hard links.
// "aliased" / "distinct" / "unknown": unknown must not hide artifacts or
// report a skipped destructive cleanup as success, so callers treat it as
// fail-closed (inspect the pmsec file, refuse to delete it).
function aliasState(p) {
  if (canonicalPath(p.legacy) === canonicalPath(p.pmsec)) return "aliased";
  const a = fileId(p.legacy), b = fileId(p.pmsec);
  if (a === "missing" || b === "missing") return "distinct";
  if (a === null || b === null) return "unknown";
  return a === b ? "aliased" : "distinct";
}

// Destructive cleanup requires provable distinctness. When the identity is
// unknown but the pmsec file still holds managed keys, the row must fail
// rather than claim convergence while the settings may still be selected.
function requireDistinctForCleanup(p) {
  const state = aliasState(p);
  if (state === "unknown" && hasManagedKeys(p.pmsec)) {
    throw new Error(`cannot verify ${p.pmsec} is distinct from ${p.legacy}; left untouched`);
  }
  return state === "distinct";
}

function readOne(raw) {
  const value = readKey(raw, key, { section });
  return { configured: value, days: parseDays(value), extras: readExtras(raw, extras) };
}

function mergeReads(reads) {
  let best = null;
  let fallback = null;
  for (const r of reads) {
    if (r.configured !== null && fallback === null) fallback = r;
    if (r.days !== null && (best === null || r.days > best.days)) best = r;
  }
  const chosen = best ?? fallback;
  const extrasMerged = extras.map((e, i) => {
    const values = reads.map(r => r.extras[i]).filter(Boolean);
    const okOne = values.find(v => v.ok);
    const defined = values.find(v => v.configured !== null);
    return okOne ?? defined ?? { key: e.key, configured: null, expected: e.expected, ok: false };
  });
  return {
    configured: chosen ? chosen.configured : null,
    days: best ? best.days : (chosen ? chosen.days : null),
    extras: extrasMerged,
  };
}

async function readFiles(files) {
  return Promise.all(files.map(async p => readOne(await readSafe(p))));
}

function distinctFiles(paths) {
  return [...new Set(paths)];
}

async function firstEnv(p) {
  for (const file of [p.local, p.shared, p.system]) {
    if (!existsSync(file)) continue;
    const parsed = parseEnv(await readSafe(file));
    if (parsed.defined) return { values: parsed.values, path: file };
  }
  return { values: [], path: null };
}

// pmsec is only the effective layer when it loads last: later environments
// override earlier ones, so membership alone cannot prove the hardened
// values win.
async function selectorState(ctx, p) {
  const fromVar = envListFrom(ctx.env.MISE_ENV);
  if (fromVar.length) {
    return { path: "MISE_ENV", env: fromVar, wired: fromVar[fromVar.length - 1] === "pmsec" };
  }
  const inherited = await firstEnv(p);
  return {
    path: inherited.path ?? p.local,
    env: inherited.values,
    wired: inherited.values[inherited.values.length - 1] === "pmsec",
  };
}

function envWarning(ctx) {
  const values = envListFrom(ctx.env.MISE_ENV);
  if (values.length && !values.includes("pmsec")) return MISE_ENV_WARN;
  return null;
}

function isEmptyStructure(text) {
  return text.split(/\r?\n/).every(line => {
    const t = line.trim();
    return t === "" || t.startsWith("#") || /^\[\[?[^\]]*\]\]?\s*(#.*)?$/.test(t);
  });
}

async function deleteQuietly(p) {
  try { await unlink(p); } catch (e) { if (e.code !== "ENOENT") throw e; }
}

async function removeManagedConfig(p) {
  const before = await readSafe(p);
  if (before === "") return false;
  const cooldown = removeKey(before, key, { section });
  const ex = removeExtras(cooldown.text, extras);
  if (!cooldown.removed && !ex.removed) return false;
  if (isEmptyStructure(ex.text)) await deleteQuietly(p);
  else await writeAtomic(p, ex.text);
  return true;
}

async function removeManagedFrom(path_) {
  const before = await readSafe(path_);
  if (before === "") return false;
  const cooldown = removeKey(before, key, { section });
  const ex = removeExtras(cooldown.text, extras);
  const removed = cooldown.removed || ex.removed;
  if (removed) await writeAtomic(path_, ex.text);
  return removed;
}

async function applySettings(text, days, ctx) {
  let out = setKey(text, key, `${key} = "${days}d"`, { section });
  out = applyExtras(out, extras, ctx);
  return out;
}

async function removeSelector(p) {
  const before = await readSafe(p.local);
  if (before !== "") {
    const r = removeEnvValue(before, "pmsec");
    if (r.removed) {
      if (r.empty) await deleteQuietly(p.local);
      else await writeAtomic(p.local, r.text);
      return true;
    }
  }
  // The local miserc holds no pmsec name. When the effective selector lives
  // in shared/system, materialize the cleaned list into the local file so
  // legacy checks converge: the foreign file (often root-owned) stays
  // untouched, mirroring how forward migration materializes inherited names.
  const inherited = await firstEnv(p);
  if (inherited.path && inherited.path !== p.local && inherited.values.includes("pmsec")) {
    await writeAtomic(p.local, setEnvValues(before, inherited.values.filter(v => v !== "pmsec")));
    return true;
  }
  return false;
}

function buildSelectorText(text, values) {
  return setEnvValues(text, values);
}

export async function read(ctx) {
  const p = paths(ctx);
  const action = ctx.action ?? "check";
  if (supportsNewMode(ctx)) {
    let files = action === "enable" ? [p.legacy, p.base, p.pmsec] : [p.pmsec];
    if (action === "enable") {
      // Later environments override earlier keys, so a stricter cooldown in
      // any layer that stays active after enable must be preserved too: both
      // the MISE_ENV layers of this shell and the inherited miserc layers that
      // write keeps ahead of pmsec in the persistent selector.
      const envs = new Set([...envListFrom(ctx.env.MISE_ENV), ...(await firstEnv(p)).values]);
      for (const name of envs) {
        if (name === "pmsec") continue;
        // A name that cannot map to a config.<env>.toml path must fail the
        // enable rather than be skipped: silently dropping an active layer
        // lets a stricter cooldown be lowered without --force.
        files.push(miseEnvConfigPath(name, ctx.env, ctx.home));
      }
    }
    const merged = mergeReads(await readFiles(distinctFiles(files)));
    const selector = await selectorState(ctx, p);
    return {
      path: p.pmsec,
      ...merged,
      selector,
      warn: envWarning(ctx),
      rowFail: selector.wired === false,
    };
  }
  const artifacts = await hasNewArtifacts(ctx, p);
  const files = action === "enable" && artifacts
    ? distinctFiles([p.legacy, p.base, p.pmsec])
    : [p.legacy];
  const merged = mergeReads(await readFiles(files));
  return {
    path: p.legacy,
    ...merged,
    warn: artifacts ? MIGRATION_WARN : null,
    rowFail: artifacts,
  };
}

export async function write(days, ctx) {
  const p = paths(ctx);
  if (supportsNewMode(ctx)) {
    // Resolve the selector before touching any file: an invalid env array
    // must fail without leaving a half-migrated pair of generations.
    const inherited = await firstEnv(p);
    const values = [...inherited.values.filter(v => v !== "pmsec"), "pmsec"];
    const localBefore = await readSafe(p.local);
    const localAfter = buildSelectorText(localBefore, values);

    const settings = await applySettings(await readSafe(p.pmsec), days, ctx);
    await writeAtomic(p.pmsec, settings);
    await writeAtomic(p.local, localAfter);
    // The legacy single-file generation is never the destination in new mode;
    // drop only managed keys and leave user content in place.
    await removeManagedFrom(p.legacy);
    return { path: p.pmsec, warn: envWarning(ctx) };
  }

  // Judged before the write so an unreadable miserc fails without touching
  // the config, and again after: replacing a hard-linked legacy file leaves
  // the pmsec link as a distinct file that still holds managed keys.
  const artifacts = await hasNewArtifacts(ctx, p);
  const settings = await applySettings(await readSafe(p.legacy), days, ctx);
  await writeAtomic(p.legacy, settings);
  if (artifacts || await hasNewArtifacts(ctx, p)) {
    // Reverse migration writes the destination first, then removes the new
    // generation so an interrupted cleanup cannot leave no configuration.
    if (requireDistinctForCleanup(p)) await removeManagedConfig(p.pmsec);
    // A nonempty MISE_ENV hides the persistent selector from this shell; a
    // shell that cannot see it must not delete it. The selector artifact
    // reappears on the next clean-shell check and converges there.
    if (envListFrom(ctx.env.MISE_ENV).length === 0) await removeSelector(p);
  }
  return { path: p.legacy, warn: null };
}

export async function unset(ctx) {
  const p = paths(ctx);
  const newMode = supportsNewMode(ctx);
  const legacyRemoved = await removeManagedFrom(p.legacy);
  const pmsecRemoved = requireDistinctForCleanup(p) ? await removeManagedConfig(p.pmsec) : false;
  const selectorRemoved = await removeSelector(p);
  return {
    path: newMode ? p.pmsec : p.legacy,
    removed: legacyRemoved || pmsecRemoved || selectorRemoved,
  };
}

// An unreadable file counts as managed: cleanup would have to touch it.
function hasManagedKeys(file) {
  let text;
  try { text = readFileSync(file, "utf8").replace(/^\uFEFF/, ""); } catch (e) { return e?.code !== "ENOENT"; }
  return removeKey(text, key, { section }).removed || removeExtras(text, extras).removed;
}

export function doctorPaths(ctx) {
  const p = paths(ctx);
  if (supportsNewMode(ctx)) {
    // The selector is always written; the legacy config only when cleanup
    // has managed keys to strip from it.
    const blockingExtraPaths = hasManagedKeys(p.legacy) ? [p.legacy, p.local] : [p.local];
    return { path: p.pmsec, extraPaths: [p.legacy, p.local], blockingExtraPaths };
  }
  return { path: p.legacy, extraPaths: [] };
}
