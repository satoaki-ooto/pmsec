import { test } from "node:test";
import assert from "node:assert/strict";
import { miseConfigPath, misePaths } from "../src/util/paths.mjs";

const HOME = "/home/user";
const WIN_HOME = "C:\\Users\\user";
const WIN_LOCALAPPDATA = "C:\\Users\\user\\AppData\\Local";
const POSIX_LEGACY = "/home/user/.config/mise/config.toml";
const WIN_LEGACY = "C:/Users/user/AppData/Local/mise/config.toml";

// `legacyConfig` deliberately keeps delegating to the unchanged `miseConfigPath`,
// which still uses host path semantics, so separators are normalized before
// comparing. Every new field uses platform-selected joins and is compared exactly.
const norm = s => s.replace(/\\/g, "/");

test("POSIX default resolves every new path under ~/.config/mise", () => {
  const p = misePaths({}, HOME, "linux");
  assert.deepEqual(Object.keys(p).sort(), [
    "baseConfig", "legacyConfig", "localMiserc", "miseDir",
    "pmsecConfig", "sharedMiserc", "systemMiserc",
  ]);
  assert.deepEqual(
    { ...p, legacyConfig: norm(p.legacyConfig) },
    {
      legacyConfig: POSIX_LEGACY,
      miseDir: "/home/user/.config/mise",
      baseConfig: "/home/user/.config/mise/config.toml",
      pmsecConfig: "/home/user/.config/mise/config.pmsec.toml",
      localMiserc: "/home/user/.config/mise/miserc.local.toml",
      sharedMiserc: "/home/user/.config/mise/miserc.toml",
      systemMiserc: "/etc/mise/miserc.toml",
    },
  );
});

test("XDG_CONFIG_HOME moves miseDir (and the legacy file) on POSIX", () => {
  const p = misePaths({ XDG_CONFIG_HOME: "/xdg" }, HOME, "linux");
  assert.equal(p.miseDir, "/xdg/mise");
  assert.equal(norm(p.legacyConfig), "/xdg/mise/config.toml");
  assert.equal(p.baseConfig, "/xdg/mise/config.toml");
  assert.equal(p.pmsecConfig, "/xdg/mise/config.pmsec.toml");
  assert.equal(p.localMiserc, "/xdg/mise/miserc.local.toml");
  assert.equal(p.sharedMiserc, "/xdg/mise/miserc.toml");
  assert.equal(p.systemMiserc, "/etc/mise/miserc.toml");
});

test("MISE_CONFIG_DIR beats XDG_CONFIG_HOME", () => {
  const p = misePaths({ MISE_CONFIG_DIR: "/opt/mise", XDG_CONFIG_HOME: "/xdg" }, HOME, "linux");
  assert.equal(p.miseDir, "/opt/mise");
  assert.equal(p.baseConfig, "/opt/mise/config.toml");
  assert.equal(p.pmsecConfig, "/opt/mise/config.pmsec.toml");
  assert.equal(p.localMiserc, "/opt/mise/miserc.local.toml");
  assert.equal(p.sharedMiserc, "/opt/mise/miserc.toml");
  // The legacy resolver still honors XDG, so the two disagree on purpose.
  assert.equal(norm(p.legacyConfig), "/xdg/mise/config.toml");
});

test("empty MISE_CONFIG_DIR and empty XDG_CONFIG_HOME count as unset", () => {
  const p = misePaths({ MISE_CONFIG_DIR: "", XDG_CONFIG_HOME: "" }, HOME, "linux");
  assert.equal(p.miseDir, "/home/user/.config/mise");
  assert.equal(p.baseConfig, "/home/user/.config/mise/config.toml");
  assert.equal(norm(p.legacyConfig), POSIX_LEGACY);
});

test("macOS uses ~/.config/mise, never Application Support", () => {
  const p = misePaths({}, "/Users/user", "darwin");
  assert.equal(p.miseDir, "/Users/user/.config/mise");
  assert.equal(norm(p.legacyConfig), "/Users/user/.config/mise/config.toml");
});

test("systemMiserc defaults to /etc/mise/miserc.toml on POSIX", () => {
  assert.equal(misePaths({}, HOME, "linux").systemMiserc, "/etc/mise/miserc.toml");
  assert.equal(misePaths({}, HOME, "darwin").systemMiserc, "/etc/mise/miserc.toml");
});

test("MISE_SYSTEM_CONFIG_DIR overrides systemMiserc on POSIX", () => {
  const p = misePaths({ MISE_SYSTEM_CONFIG_DIR: "/opt/mise-system" }, HOME, "linux");
  assert.equal(p.systemMiserc, "/opt/mise-system/miserc.toml");
});

test("empty MISE_SYSTEM_CONFIG_DIR falls through to the default", () => {
  const p = misePaths({ MISE_SYSTEM_CONFIG_DIR: "" }, HOME, "linux");
  assert.equal(p.systemMiserc, "/etc/mise/miserc.toml");
});

test("legacy MISE_GLOBAL_CONFIG_FILE only moves legacyConfig", () => {
  const p = misePaths({ MISE_GLOBAL_CONFIG_FILE: "/custom/mise.toml" }, HOME, "linux");
  assert.equal(norm(p.legacyConfig), "/custom/mise.toml");
  assert.equal(p.miseDir, "/home/user/.config/mise");
  assert.equal(p.baseConfig, "/home/user/.config/mise/config.toml");
  assert.equal(p.pmsecConfig, "/home/user/.config/mise/config.pmsec.toml");
  assert.equal(p.localMiserc, "/home/user/.config/mise/miserc.local.toml");
  assert.equal(p.sharedMiserc, "/home/user/.config/mise/miserc.toml");
});

test("empty MISE_GLOBAL_CONFIG_FILE keeps the legacy default", () => {
  const p = misePaths({ MISE_GLOBAL_CONFIG_FILE: "" }, HOME, "linux");
  assert.equal(norm(p.legacyConfig), POSIX_LEGACY);
  assert.equal(p.miseDir, "/home/user/.config/mise");
});

test("MISE_CONFIG_DIR never moves legacyConfig", () => {
  const env = { MISE_CONFIG_DIR: "/opt/mise" };
  const p = misePaths(env, HOME, "linux");
  assert.equal(p.legacyConfig, miseConfigPath(env, HOME, "linux"));
  assert.equal(norm(p.legacyConfig), POSIX_LEGACY);
});

test("win32 keeps legacy under LOCALAPPDATA while miseDir uses ~/.config", () => {
  const env = { LOCALAPPDATA: WIN_LOCALAPPDATA };
  const p = misePaths(env, WIN_HOME, "win32", "C:\\work");
  assert.equal(norm(p.legacyConfig), WIN_LEGACY);
  assert.equal(p.miseDir, "C:\\Users\\user\\.config\\mise");
  assert.equal(p.baseConfig, "C:\\Users\\user\\.config\\mise\\config.toml");
  assert.equal(p.pmsecConfig, "C:\\Users\\user\\.config\\mise\\config.pmsec.toml");
  assert.equal(p.localMiserc, "C:\\Users\\user\\.config\\mise\\miserc.local.toml");
  assert.equal(p.sharedMiserc, "C:\\Users\\user\\.config\\mise\\miserc.toml");
  assert.equal(p.systemMiserc, "C:\\etc\\mise\\miserc.toml");
});

test("win32 legacy default is LOCALAPPDATA-derived even when LOCALAPPDATA is unset", () => {
  const p = misePaths({}, WIN_HOME, "win32", "C:\\work");
  assert.equal(norm(p.legacyConfig), WIN_LEGACY);
  assert.equal(p.miseDir, "C:\\Users\\user\\.config\\mise");
});

test("win32 honors XDG_CONFIG_HOME for miseDir but not for legacy", () => {
  const env = { XDG_CONFIG_HOME: "D:\\xdg", LOCALAPPDATA: WIN_LOCALAPPDATA };
  const p = misePaths(env, WIN_HOME, "win32", "C:\\work");
  assert.equal(p.miseDir, "D:\\xdg\\mise");
  assert.equal(p.baseConfig, "D:\\xdg\\mise\\config.toml");
  assert.equal(p.pmsecConfig, "D:\\xdg\\mise\\config.pmsec.toml");
  assert.equal(norm(p.legacyConfig), WIN_LEGACY);
});

test("win32 MISE_CONFIG_DIR beats XDG_CONFIG_HOME", () => {
  const env = { MISE_CONFIG_DIR: "E:\\mise", XDG_CONFIG_HOME: "D:\\xdg" };
  const p = misePaths(env, WIN_HOME, "win32", "C:\\work");
  assert.equal(p.miseDir, "E:\\mise");
  assert.equal(p.sharedMiserc, "E:\\mise\\miserc.toml");
  assert.equal(p.localMiserc, "E:\\mise\\miserc.local.toml");
  assert.equal(p.legacyConfig, miseConfigPath(env, WIN_HOME, "win32"));
});

test("win32 systemMiserc follows the injected cwd drive root", () => {
  assert.equal(misePaths({}, WIN_HOME, "win32", "D:\\work").systemMiserc, "D:\\etc\\mise\\miserc.toml");
  assert.equal(misePaths({}, WIN_HOME, "win32", "C:\\a\\b").systemMiserc, "C:\\etc\\mise\\miserc.toml");
});

test("win32 MISE_SYSTEM_CONFIG_DIR overrides the drive-root default", () => {
  const env = { MISE_SYSTEM_CONFIG_DIR: "E:\\mise-system" };
  assert.equal(misePaths(env, WIN_HOME, "win32", "D:\\work").systemMiserc, "E:\\mise-system\\miserc.toml");
});

test("empty env values are treated as unset on win32 too", () => {
  const env = { MISE_CONFIG_DIR: "", XDG_CONFIG_HOME: "", MISE_SYSTEM_CONFIG_DIR: "", MISE_GLOBAL_CONFIG_FILE: "" };
  const p = misePaths(env, WIN_HOME, "win32", "D:\\work");
  assert.equal(p.miseDir, "C:\\Users\\user\\.config\\mise");
  assert.equal(p.systemMiserc, "D:\\etc\\mise\\miserc.toml");
  assert.equal(norm(p.legacyConfig), WIN_LEGACY);
});
