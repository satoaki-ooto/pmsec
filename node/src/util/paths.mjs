import { homedir } from "node:os";
import { dirname, join, isAbsolute, parse } from "node:path";
import { existsSync } from "node:fs";

export function npmrcPath(env = process.env, home = homedir()) {
  return env.NPM_CONFIG_USERCONFIG || join(home, ".npmrc");
}

// pnpm reads its global rc from a dedicated location separate from ~/.npmrc.
// Writing pnpm-only keys here keeps npm from warning (and, in npm 12, erroring)
// about unknown user config. pnpm itself respects XDG_CONFIG_HOME on every OS.
export function pnpmRcPath(env = process.env, home = homedir(), platform = process.platform) {
  if (env.PMSEC_PNPM_CONFIG_FILE) return env.PMSEC_PNPM_CONFIG_FILE;
  if (env.XDG_CONFIG_HOME) return join(env.XDG_CONFIG_HOME, "pnpm", "rc");
  if (platform === "darwin") return join(home, "Library", "Preferences", "pnpm", "rc");
  if (platform === "win32") {
    const base = env.LOCALAPPDATA || join(home, "AppData", "Local");
    return join(base, "pnpm", "config", "rc");
  }
  return join(home, ".config", "pnpm", "rc");
}

// pnpm >= 11 reads pnpm-specific settings from config.yaml (camelCase) instead
// of the registry/auth-only rc file. Keep it next to the rc path so custom
// PMSEC_PNPM_CONFIG_FILE overrides remain self-contained.
export function pnpmConfigPath(env = process.env, home = homedir(), platform = process.platform) {
  if (env.PMSEC_PNPM_CONFIG_YAML) return env.PMSEC_PNPM_CONFIG_YAML;
  return join(dirname(pnpmRcPath(env, home, platform)), "config.yaml");
}

export function uvConfigPath(env = process.env, home = homedir(), platform = process.platform) {
  if (env.UV_CONFIG_FILE) return env.UV_CONFIG_FILE;
  if (platform === "win32") {
    const base = env.APPDATA || join(home, "AppData", "Roaming");
    return join(base, "uv", "uv.toml");
  }
  const base = env.XDG_CONFIG_HOME || join(home, ".config");
  return join(base, "uv", "uv.toml");
}

// bun reads $XDG_CONFIG_HOME/.bunfig.toml *instead of* $HOME/.bunfig.toml
// whenever XDG_CONFIG_HOME is set to an absolute path.
export function bunConfigPath(env = process.env, home = homedir()) {
  if (env.BUN_CONFIG_FILE) return env.BUN_CONFIG_FILE;
  if (env.XDG_CONFIG_HOME && isAbsolute(env.XDG_CONFIG_HOME)) return join(env.XDG_CONFIG_HOME, ".bunfig.toml");
  return join(home, ".bunfig.toml");
}

export function yarnrcPath(env = process.env, home = homedir()) {
  return env.YARN_RC_FILENAME || join(home, ".yarnrc.yml");
}

export function cargoConfigPath(env = process.env, home = homedir()) {
  if (env.CARGO_HOME) return join(env.CARGO_HOME, "config.toml");
  return join(home, ".cargo", "config.toml");
}

// Bundler's global config. BUNDLE_USER_CONFIG points at the file directly;
// BUNDLE_USER_HOME points at the home dir (config lives at <home>/config).
// Both default to ~/.bundle, matching bundler's own resolution order.
export function bundleConfigPath(env = process.env, home = homedir()) {
  if (env.BUNDLE_USER_CONFIG) return env.BUNDLE_USER_CONFIG;
  if (env.BUNDLE_USER_HOME) return join(env.BUNDLE_USER_HOME, "config");
  return join(home, ".bundle", "config");
}

export function miseConfigPath(env = process.env, home = homedir(), platform = process.platform) {
  if (env.MISE_GLOBAL_CONFIG_FILE) return env.MISE_GLOBAL_CONFIG_FILE;
  // mise reads its global config from MISE_CONFIG_DIR when set, so the legacy
  // destination must follow it; a default-path write would leave the active
  // config without the bundle after a downgrade migration.
  if (env.MISE_CONFIG_DIR) return join(env.MISE_CONFIG_DIR, "config.toml");
  if (platform === "win32") {
    const base = env.LOCALAPPDATA || join(home, "AppData", "Local");
    return join(base, "mise", "config.toml");
  }
  const base = env.XDG_CONFIG_HOME || join(home, ".config");
  return join(base, "mise", "config.toml");
}

// mise's global config directory (https://mise.jdx.dev/directories.html).
// Unlike the legacy single-file path above this is the same on every OS:
// win32 uses %USERPROFILE%\.config\mise, not %LOCALAPPDATA%\mise.
export function miseConfigDir(env = process.env, home = homedir()) {
  if (env.MISE_CONFIG_DIR) return env.MISE_CONFIG_DIR;
  if (env.XDG_CONFIG_HOME) return join(env.XDG_CONFIG_HOME, "mise");
  return join(home, ".config", "mise");
}

export function miseBaseConfigPath(env = process.env, home = homedir()) {
  return join(miseConfigDir(env, home), "config.toml");
}

export function misePmsecConfigPath(env = process.env, home = homedir()) {
  return join(miseConfigDir(env, home), "config.pmsec.toml");
}

// mise loads config.<environment>.toml for every selected environment next to
// the global config; enable must consider those layers when preserving
// stricter cooldowns. The name comes from the selector, so only safe
// spellings resolve inside the dir.
export function miseEnvConfigPath(name, env = process.env, home = homedir()) {
  if (!/^[A-Za-z0-9_-]+$/.test(name)) throw new Error(`unsafe mise environment name: ${name}`);
  return join(miseConfigDir(env, home), `config.${name}.toml`);
}

export function miseLocalMisercPath(env = process.env, home = homedir()) {
  return join(miseConfigDir(env, home), "miserc.local.toml");
}

export function miseSharedMisercPath(env = process.env, home = homedir()) {
  return join(miseConfigDir(env, home), "miserc.toml");
}

export function miseSystemMisercPath(env = process.env, home = homedir(), platform = process.platform) {
  if (env.MISE_SYSTEM_CONFIG_DIR) return join(env.MISE_SYSTEM_CONFIG_DIR, "miserc.toml");
  if (platform === "win32") {
    // `home` may be a simulated Windows path on a POSIX test runner, so read
    // the drive letter from the string instead of node:path's parse().
    const drive = home.match(/^[A-Za-z]:[\\/]/)?.[0] ?? parse(home).root ?? "C:\\";
    return join(drive, "etc", "mise", "miserc.toml");
  }
  return "/etc/mise/miserc.toml";
}

export function aubeConfigPath(env = process.env, home = homedir(), platform = process.platform) {
  if (env.AUBE_CONFIG_FILE) return env.AUBE_CONFIG_FILE;
  if (platform === "win32") {
    const base = env.LOCALAPPDATA || join(home, "AppData", "Local");
    return join(base, "aube", "config.toml");
  }
  const base = env.XDG_CONFIG_HOME || join(home, ".config");
  return join(base, "aube", "config.toml");
}

// Composer keeps its global config in $COMPOSER_HOME/config.json. The default
// COMPOSER_HOME follows platform conventions (XDG on Unix, Application Support
// on macOS, APPDATA on Windows), matching Composer's own resolution. An
// explicit XDG_CONFIG_HOME wins on every non-Windows platform, including macOS.
// Mirrors Composer's Factory::getHomeDir: COMPOSER_HOME, else %APPDATA%/Composer
// on Windows, else (when any XDG_* variable is set or /etc/xdg exists) the
// first existing of $XDG_CONFIG_HOME/composer and ~/.composer, defaulting to
// the XDG one; without XDG, ~/.composer. Composer never uses Application
// Support on macOS.
export function composerConfigPath(env = process.env, home = homedir(), platform = process.platform) {
  if (env.COMPOSER_HOME) return join(env.COMPOSER_HOME, "config.json");
  if (platform === "win32") {
    const base = env.APPDATA || join(home, "AppData", "Roaming");
    return join(base, "Composer", "config.json");
  }
  // The /etc/xdg probe describes the host, so it only applies when the
  // requested platform is the host platform (tests pass foreign platforms).
  const useXdg = Object.keys(env).some(k => k.startsWith("XDG_"))
    || (platform === process.platform && existsSync("/etc/xdg"));
  const dirs = [];
  if (useXdg) dirs.push(join(env.XDG_CONFIG_HOME || join(home, ".config"), "composer"));
  dirs.push(join(home, ".composer"));
  const dir = dirs.find(d => existsSync(d)) ?? dirs[0];
  return join(dir, "config.json");
}
