#!/usr/bin/env bash
# Mirrors node/test/cli.test.mjs — runs the bash port against a fresh $HOME
# and checks the same on-disk shape.
set -o pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
PMSEC="$HERE/../pmsec"
PASS=0
FAIL=0
LAST_FAIL=""

setup_home() {
  local d
  d=$(mktemp -d -t pmsec-bash.XXXXXX)
  printf '%s' "$d"
}

# run [extra envs...] -- pmsec args...
# `PMSEC_PNPM_VERSION=none` hides the host pnpm so version-aware extras
# (pnpm 11 default enforcement) don't depend on what's installed locally.
# `PMSEC_BUNDLER_VERSION=none` likewise hides the host bundler so its
# preflight warning doesn't leak into stderr-sensitive assertions.
# `PMSEC_MISE_VERSION=none` hides the host mise so mise mode detection stays
# host-independent (the mode gate is not wired into the CLI yet, but pinning it
# here keeps the suite honest when it is).
# Test cases that exercise pnpm 11 behavior pass an override in `extra`, which
# lands after the defaults on the `env` command line and therefore wins.
run_pmsec() {
  local home="$1"; shift
  local extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    extra[${#extra[@]}]="$1"; shift
  done
  shift
  if [ "${#extra[@]}" -eq 0 ]; then
    env -i PATH="$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
      PMSEC_PNPM_VERSION=none PMSEC_BUNDLER_VERSION=none PMSEC_MISE_VERSION=none \
      bash "$PMSEC" "$@"
  else
    env -i PATH="$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
      PMSEC_PNPM_VERSION=none PMSEC_BUNDLER_VERSION=none PMSEC_MISE_VERSION=none \
      "${extra[@]}" bash "$PMSEC" "$@"
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    return 0
  fi
  LAST_FAIL="$label
  expected: $(printf '%q' "$expected")
  actual:   $(printf '%q' "$actual")"
  return 1
}

assert_file_eq() {
  local label="$1" expected_content="$2" path="$3" tmp diff_out
  tmp=$(mktemp)
  printf '%s' "$expected_content" > "$tmp"
  if diff_out=$(diff -u "$tmp" "$path" 2>&1); then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  LAST_FAIL="$label
$diff_out"
  return 1
}

assert_match() {
  local label="$1" pattern="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -E -q -- "$pattern"; then
    return 0
  fi
  LAST_FAIL="$label
  pattern: $pattern
  body:    $(printf '%s' "$haystack" | head -c 400)"
  return 1
}

T() {
  local name="$1"; shift
  # A test fails when it returns nonzero *or* recorded an assertion failure.
  # The second half is what makes cleanup unable to mask anything: a trailing
  # `rm_tree` (or any other successful command) used to become the function's
  # status and turn a failed assertion into a pass. LAST_FAIL is the record —
  # every assertion sets it only when it fails, so a non-empty value after the
  # call is a failure no matter what the function returned.
  LAST_FAIL=""
  if "$@" && [ -z "$LAST_FAIL" ]; then
    PASS=$((PASS+1))
    printf 'PASS  %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    printf 'FAIL  %s\n%s\n' "$name" "${LAST_FAIL:-(no assertion detail)}"
  fi
}

# ---------- tests ----------

t_enable_writes_all() {
  local home; home=$(setup_home)
  run_pmsec "$home" -- >/dev/null
  local npmrc pnpmrc pnmyaml bunfig yarnrc uvtoml mise bundle
  npmrc=$(cat "$home/.npmrc")
  pnpmrc=$(cat "$home/.config/pnpm/rc")
  pnmyaml=$(cat "$home/.config/pnpm/config.yaml")
  bunfig=$(cat "$home/.config/.bunfig.toml")
  yarnrc=$(cat "$home/.yarnrc.yml")
  uvtoml=$(cat "$home/.config/uv/uv.toml")
  mise=$(cat "$home/.config/mise/config.toml")
  aube=$(cat "$home/.config/aube/config.toml")
  bundle=$(cat "$home/.bundle/config")
  local composer
  composer=$(cat "$home/.config/composer/config.json")
  assert_match "npm key" '^min-release-age=1$' "$npmrc" || return
  assert_match "pnpm key" '^minimum-release-age=1440$' "$pnpmrc" || return
  if printf '%s' "$npmrc" | grep -q 'minimum-release-age'; then
    LAST_FAIL="pnpm key leaked into .npmrc"; return 1
  fi
  assert_match "bun section" '^\[install\]$' "$bunfig" || return
  assert_match "bun key" '^minimumReleaseAge = 86400$' "$bunfig" || return
  assert_match "bun ignoreScripts extra" '^ignoreScripts = true$' "$bunfig" || return
  assert_match "yarn key" '^npmMinimalAgeGate: 1440$' "$yarnrc" || return
  assert_match "uv key" '^exclude-newer = "1 days"$' "$uvtoml" || return
  assert_match "uv index-strategy extra" '^index-strategy = "first-index"$' "$uvtoml" || return
  assert_match "uv audit section" '^\[audit\]$' "$uvtoml" || return
  assert_match "uv malware-check extra" '^malware-check = true$' "$uvtoml" || return
  assert_match "mise section" '^\[settings\]$' "$mise" || return
  assert_match "mise key" '^minimum_release_age = "1d"$' "$mise" || return
  assert_match "mise paranoid extra" '^paranoid = true$' "$mise" || return
  assert_match "mise gpg_verify extra" '^gpg_verify = true$' "$mise" || return
  assert_match "mise github_attestations extra" '^github_attestations = true$' "$mise" || return
  assert_match "mise slsa extra" '^slsa = true$' "$mise" || return
  assert_match "mise locked_verify_provenance extra" '^locked_verify_provenance = true$' "$mise" || return
  assert_match "aube key" '^minimumReleaseAge = 1440$' "$aube" || return
  assert_match "aube paranoid extra" '^paranoid = true$' "$aube" || return
  assert_match "npm audit-level extra" '^audit-level=high$' "$npmrc" || return
  assert_match "npm allow-git extra" '^allow-git=none$' "$npmrc" || return
  assert_match "npm allow-remote extra" '^allow-remote=none$' "$npmrc" || return
  assert_match "npm allow-file extra" '^allow-file=root$' "$npmrc" || return
  assert_match "npm allow-directory extra" '^allow-directory=root$' "$npmrc" || return
  assert_match "npm strict-allow-scripts extra" '^strict-allow-scripts=true$' "$npmrc" || return
  assert_match "npm dangerously-allow-all-scripts extra" '^dangerously-allow-all-scripts=false$' "$npmrc" || return
  assert_match "npm allow-scripts-pin extra" '^allow-scripts-pin=true$' "$npmrc" || return
  assert_match "npm ignore-extension extra" '^ignore-extension=true$' "$npmrc" || return
  assert_match "pnpm trust-policy extra" '^trust-policy=no-downgrade$' "$pnpmrc" || return
  assert_match "pnpm block-exotic-subdeps extra" '^block-exotic-subdeps=true$' "$pnpmrc" || return
  assert_match "pnpm strict-dep-builds extra" '^strict-dep-builds=true$' "$pnpmrc" || return
  assert_match "pnpm verify-deps-before-run extra" '^verify-deps-before-run=error$' "$pnpmrc" || return
  assert_match "pnpm minimum-release-age-strict extra" '^minimum-release-age-strict=true$' "$pnpmrc" || return
  assert_match "pnpm dangerously-allow-all-builds extra" '^dangerously-allow-all-builds=false$' "$pnpmrc" || return
  assert_match "pnpm trust-lockfile extra" '^trust-lockfile=false$' "$pnpmrc" || return
  assert_match "pnpm minimum-release-age-ignore-missing-time extra" '^minimum-release-age-ignore-missing-time=false$' "$pnpmrc" || return
  assert_match "pnpm yaml cooldown" '^minimumReleaseAge: 1440$' "$pnmyaml" || return
  assert_match "pnpm yaml trustPolicy" '^trustPolicy: no-downgrade$' "$pnmyaml" || return
  assert_match "pnpm yaml blockExoticSubdeps" '^blockExoticSubdeps: true$' "$pnmyaml" || return
  assert_match "pnpm yaml strictDepBuilds" '^strictDepBuilds: true$' "$pnmyaml" || return
  assert_match "pnpm yaml verifyDepsBeforeRun" '^verifyDepsBeforeRun: error$' "$pnmyaml" || return
  assert_match "pnpm yaml minimumReleaseAgeStrict" '^minimumReleaseAgeStrict: true$' "$pnmyaml" || return
  assert_match "pnpm yaml dangerouslyAllowAllBuilds" '^dangerouslyAllowAllBuilds: false$' "$pnmyaml" || return
  assert_match "pnpm yaml trustLockfile" '^trustLockfile: false$' "$pnmyaml" || return
  assert_match "pnpm yaml minimumReleaseAgeIgnoreMissingTime" '^minimumReleaseAgeIgnoreMissingTime: false$' "$pnmyaml" || return
  assert_match "yarn enableHardenedMode extra" '^enableHardenedMode: true$' "$yarnrc" || return
  assert_match "yarn enableScripts extra" '^enableScripts: false$' "$yarnrc" || return
  assert_match "yarn approvedGitRepositories extra" '^approvedGitRepositories: \[\]$' "$yarnrc" || return
  assert_match "mise ruby.github_attestations extra" '^ruby\.github_attestations = true$' "$mise" || return
  assert_match "mise python.github_attestations extra" '^python\.github_attestations = true$' "$mise" || return
  assert_match "mise provenance_api_failures_fatal extra" '^provenance_api_failures_fatal = true$' "$mise" || return
  assert_match "mise aqua.github_attestations extra" '^aqua\.github_attestations = true$' "$mise" || return
  assert_match "mise aqua.cosign extra" '^aqua\.cosign = true$' "$mise" || return
  assert_match "mise aqua.minisign extra" '^aqua\.minisign = true$' "$mise" || return
  assert_match "mise aqua.slsa extra" '^aqua\.slsa = true$' "$mise" || return
  assert_match "mise github.github_attestations extra" '^github\.github_attestations = true$' "$mise" || return
  assert_match "mise github.slsa extra" '^github\.slsa = true$' "$mise" || return
  assert_match "mise node.gpg_verify extra" '^node\.gpg_verify = true$' "$mise" || return
  assert_match "mise swift.gpg_verify extra" '^swift\.gpg_verify = true$' "$mise" || return
  assert_match "mise not_found_system_fallback extra" '^not_found_system_fallback = false$' "$mise" || return
  assert_match "bundler key" '^BUNDLE_COOLDOWN: "1"$' "$bundle" || return
  assert_match "composer cooldown" '"period": "1 days"' "$composer" || return
  assert_match "composer allow-plugins" '"allow-plugins": false' "$composer" || return
  assert_match "composer secure-http" '"secure-http": true' "$composer" || return
  assert_match "composer disable-tls" '"disable-tls": false' "$composer" || return
  assert_match "composer audit abandoned" '"abandoned": "fail"' "$composer" || return
  rm -rf -- "$home"
}

t_check_passes_after_enable() {
  local home; home=$(setup_home)
  run_pmsec "$home" -- >/dev/null
  run_pmsec "$home" -- --check >/dev/null
  local rc=$?
  rm -rf -- "$home"
  assert_eq "exit code" "0" "$rc"
}

t_check_fails_when_missing() {
  local home; home=$(setup_home)
  local out rc
  out=$(run_pmsec "$home" -- --check 2>/dev/null)
  rc=$?
  rm -rf -- "$home"
  assert_eq "exit code" "1" "$rc" || return
  for t in npm pnpm yarn bun cargo mise uv bundler aube composer; do
    assert_match "MISSING $t" "MISSING $t" "$out" || return
  done
}

t_disable_preserves_unrelated_keys() {
  local home; home=$(setup_home)
  printf 'registry=https://r/\nmin-release-age=3\n' > "$home/.npmrc"
  mkdir -p "$home/.config/pnpm"
  printf 'minimum-release-age=4320\nstore-dir=/tmp/pstore\n' > "$home/.config/pnpm/rc"
  printf 'minimumReleaseAge: 4320\nstoreDir: /tmp/pstore\n' > "$home/.config/pnpm/config.yaml"
  mkdir -p "$home/.config/uv"
  printf 'exclude-newer = "3 days"\nlink-mode = "copy"\n' > "$home/.config/uv/uv.toml"
  printf '[install]\nminimumReleaseAge = 259200\nregistry = "https://x/"\n' > "$home/.config/.bunfig.toml"
  printf 'npmMinimalAgeGate: "3d"\nnpmRegistryServer: "https://r/"\n' > "$home/.yarnrc.yml"
  run_pmsec "$home" -- --disable >/dev/null
  assert_file_eq "npmrc" 'registry=https://r/
' "$home/.npmrc" || { rm -rf "$home"; return 1; }
  assert_file_eq "pnpm rc" 'store-dir=/tmp/pstore
' "$home/.config/pnpm/rc" || { rm -rf "$home"; return 1; }
  assert_file_eq "pnpm config.yaml" 'storeDir: /tmp/pstore
' "$home/.config/pnpm/config.yaml" || { rm -rf "$home"; return 1; }
  assert_file_eq "uv.toml" 'link-mode = "copy"
' "$home/.config/uv/uv.toml" || { rm -rf "$home"; return 1; }
  assert_file_eq "bunfig" '[install]
registry = "https://x/"
' "$home/.config/.bunfig.toml" || { rm -rf "$home"; return 1; }
  assert_file_eq "yarnrc" 'npmRegistryServer: "https://r/"
' "$home/.yarnrc.yml" || { rm -rf "$home"; return 1; }
  rm -rf -- "$home"
}

t_enable_upgrades_weak_existing_value() {
  local home; home=$(setup_home)
  printf 'min-release-age=3\nregistry=https://r/\n' > "$home/.npmrc"
  run_pmsec "$home" -- --tool npm --days 7 >/dev/null
  assert_file_eq "npmrc" 'min-release-age=7
registry=https://r/
audit-level=high
allow-git=none
allow-remote=none
allow-file=root
allow-directory=root
strict-allow-scripts=true
dangerously-allow-all-scripts=false
allow-scripts-pin=true
ignore-extension=true
' "$home/.npmrc" || { rm -rf "$home"; return 1; }
  rm -rf -- "$home"
}

t_enable_preserves_stricter_existing_cooldown() {
  local home; home=$(setup_home)
  printf 'min-release-age=99\nregistry=https://r/\n' > "$home/.npmrc"
  local out
  out=$(run_pmsec "$home" -- --tool npm)
  assert_match "keep line fully formatted" '^keep[[:space:]]+npm[[:space:]]+\[[^]]+\][[:space:]]+\(kept existing 99d .* 1d\)' "$out" || { rm -rf "$home"; return 1; }
  assert_file_eq "npmrc preserves 99" 'min-release-age=99
registry=https://r/
audit-level=high
allow-git=none
allow-remote=none
allow-file=root
allow-directory=root
strict-allow-scripts=true
dangerously-allow-all-scripts=false
allow-scripts-pin=true
ignore-extension=true
' "$home/.npmrc" || { rm -rf "$home"; return 1; }
  rm -rf -- "$home"
}

t_enable_force_overwrites_stricter_existing() {
  local home; home=$(setup_home)
  printf 'min-release-age=99\n' > "$home/.npmrc"
  run_pmsec "$home" -- --tool npm --days 1 --force >/dev/null
  assert_match "force downgraded to 1" '^min-release-age=1$' "$(cat "$home/.npmrc")" || { rm -rf "$home"; return 1; }
  rm -rf -- "$home"
}

t_enable_days_upgrades_when_request_exceeds_existing() {
  local home; home=$(setup_home)
  printf 'min-release-age=3\n' > "$home/.npmrc"
  run_pmsec "$home" -- --tool npm --days 14 >/dev/null
  assert_match "upgraded to 14" '^min-release-age=14$' "$(cat "$home/.npmrc")" || { rm -rf "$home"; return 1; }
  rm -rf -- "$home"
}

t_tool_filter_restricts() {
  local home; home=$(setup_home)
  run_pmsec "$home" -- --tool npm,bun >/dev/null
  [ -f "$home/.npmrc" ] || { LAST_FAIL=".npmrc not written"; rm -rf "$home"; return 1; }
  [ -f "$home/.config/.bunfig.toml" ] || { LAST_FAIL=".bunfig.toml not written"; rm -rf "$home"; return 1; }
  [ ! -f "$home/.config/uv/uv.toml" ] || { LAST_FAIL="uv.toml unexpectedly written"; rm -rf "$home"; return 1; }
  rm -rf -- "$home"
}

t_windows_uv_path() {
  local home; home=$(setup_home)
  local appdata="$home/AppData/Roaming"
  env -i PATH="$PATH" HOME="$home" APPDATA="$appdata" PMSEC_PLATFORM=win32 \
    bash "$PMSEC" --tool uv >/dev/null
  assert_match "uv key" '^exclude-newer = "1 days"$' "$(cat "$appdata/uv/uv.toml")" || { rm -rf "$home"; return 1; }
  rm -rf -- "$home"
}

t_json_check() {
  local home; home=$(setup_home)
  local out
  out=$(run_pmsec "$home" -- --check --json)
  rm -rf -- "$home"
  assert_match "ok false" '"ok": false' "$out" || return
  assert_match "bundleDays 1" '"bundleDays": 1' "$out" || return
  assert_match "rows include uv" '"tool": "uv"' "$out" || return
  assert_match "rows include cargo" '"tool": "cargo"' "$out" || return
}

t_bun_inserts_into_existing_section() {
  local home; home=$(setup_home)
  mkdir -p "$home/.config"
  printf '[install]\nregistry = "https://x/"\n' > "$home/.config/.bunfig.toml"
  run_pmsec "$home" -- --tool bun >/dev/null
  assert_file_eq "bunfig" '[install]
ignoreScripts = true
minimumReleaseAge = 86400
registry = "https://x/"
' "$home/.config/.bunfig.toml" || { rm -rf "$home"; return 1; }
  rm -rf -- "$home"
}

t_bun_creates_section_if_missing() {
  local home; home=$(setup_home)
  mkdir -p "$home/.config"
  printf 'telemetry = false\n' > "$home/.config/.bunfig.toml"
  run_pmsec "$home" -- --tool bun >/dev/null
  assert_file_eq "bunfig" 'telemetry = false

[install]
ignoreScripts = true
minimumReleaseAge = 86400
' "$home/.config/.bunfig.toml" || { rm -rf "$home"; return 1; }
  rm -rf -- "$home"
}

t_yarn_check_parses_days() {
  local home; home=$(setup_home)
  printf 'npmMinimalAgeGate: "14d"\nenableHardenedMode: true\nenableScripts: false\napprovedGitRepositories: []\n' > "$home/.yarnrc.yml"
  local out
  out=$(run_pmsec "$home" -- --check --json --tool yarn)
  rm -rf -- "$home"
  assert_match "yarn ok" '"ok": true' "$out" || return
  assert_match "yarn days" '"days": 14' "$out" || return
}

t_pnpm_normalizes_minutes() {
  local home; home=$(setup_home)
  mkdir -p "$home/.config/pnpm"
  printf 'minimum-release-age=20160\n' > "$home/.config/pnpm/rc"
  local out
  out=$(run_pmsec "$home" PMSEC_PNPM_VERSION=10.26.0 -- --check --json --tool pnpm)
  rm -rf -- "$home"
  assert_match "pnpm days" '"days": 14' "$out" || return
}

t_bundler_enable_preserves_unrelated_keys() {
  local home; home=$(setup_home)
  mkdir -p "$home/.bundle"
  printf -- '---\nBUNDLE_PATH: "vendor/bundle"\n' > "$home/.bundle/config"
  run_pmsec "$home" -- --tool bundler --days 7 >/dev/null
  local text; text=$(cat "$home/.bundle/config")
  rm -rf -- "$home"
  assert_match "bundler cooldown" '^BUNDLE_COOLDOWN: "7"$' "$text" || return
  assert_match "bundler unrelated key preserved" '^BUNDLE_PATH: "vendor/bundle"$' "$text" || return
}

t_bundler_check_parses_days() {
  local home; home=$(setup_home)
  mkdir -p "$home/.bundle"
  printf -- '---\nBUNDLE_COOLDOWN: "14"\n' > "$home/.bundle/config"
  local out
  out=$(run_pmsec "$home" -- --check --json --tool bundler)
  rm -rf -- "$home"
  assert_match "bundler ok" '"ok": true' "$out" || return
  assert_match "bundler days" '"days": 14' "$out" || return
}

t_bak_created_once() {
  local home; home=$(setup_home)
  printf 'registry=https://original/\n' > "$home/.npmrc"
  run_pmsec "$home" -- --tool npm >/dev/null
  run_pmsec "$home" -- --disable --tool npm >/dev/null
  run_pmsec "$home" -- --tool npm >/dev/null
  assert_file_eq "bak" 'registry=https://original/
' "$home/.npmrc.bak" || { rm -rf "$home"; return 1; }
  rm -rf -- "$home"
}

t_days_overrides_bundle_cooldown() {
  local home; home=$(setup_home)
  run_pmsec "$home" -- --days 7 >/dev/null
  assert_match "npm cooldown 7" '^min-release-age=7$' "$(cat "$home/.npmrc")" || { rm -rf "$home"; return 1; }
  assert_match "pnpm cooldown 10080m" '^minimum-release-age=10080$' "$(cat "$home/.config/pnpm/rc")" || { rm -rf "$home"; return 1; }
  assert_match "pnpm yaml cooldown 10080m" '^minimumReleaseAge: 10080$' "$(cat "$home/.config/pnpm/config.yaml")" || { rm -rf "$home"; return 1; }
  assert_match "uv 7 days" 'exclude-newer = "7 days"' "$(cat "$home/.config/uv/uv.toml")" || { rm -rf "$home"; return 1; }
  assert_match "bun 7d secs" 'minimumReleaseAge = 604800' "$(cat "$home/.config/.bunfig.toml")" || { rm -rf "$home"; return 1; }
  assert_match "aube 7d mins" 'minimumReleaseAge = 10080' "$(cat "$home/.config/aube/config.toml")" || { rm -rf "$home"; return 1; }

  local out rc
  out=$(run_pmsec "$home" -- --check --json --days 7); rc=$?
  assert_eq "check days=7 exit" "0" "$rc" || { rm -rf "$home"; return 1; }
  assert_match "json days=7" '"bundleDays": 7' "$out" || { rm -rf "$home"; return 1; }

  run_pmsec "$home" -- --check >/dev/null; rc=$?
  assert_eq "default check still passes" "0" "$rc" || { rm -rf "$home"; return 1; }

  run_pmsec "$home" -- --check --days 30 >/dev/null 2>&1; rc=$?
  assert_eq "stricter check fails" "1" "$rc" || { rm -rf "$home"; return 1; }
  rm -rf -- "$home"
}

t_days_rejects_invalid() {
  local home; home=$(setup_home)
  local rc
  for bad in 0 -1 abc ""; do
    run_pmsec "$home" -- --days "$bad" >/dev/null 2>&1; rc=$?
    assert_eq "days=$bad exit 2" "2" "$rc" || { rm -rf "$home"; return 1; }
  done
  rm -rf -- "$home"
}

t_enable_rejects_positional_arg() {
  local home; home=$(setup_home)
  local err rc
  err=$(run_pmsec "$home" -- enable 2>&1 1>/dev/null)
  rc=$?
  rm -rf -- "$home"
  assert_eq "exit code" "2" "$rc" || return 1
  assert_match "msg" "unexpected argument: enable" "$err"
}

t_check_and_disable_mutually_exclusive() {
  local home; home=$(setup_home)
  local err rc
  err=$(run_pmsec "$home" -- --check --disable 2>&1 1>/dev/null)
  rc=$?
  rm -rf -- "$home"
  assert_eq "exit code" "2" "$rc" || return 1
  assert_match "msg" "mutually exclusive" "$err"
}

t_version_flag() {
  local expected
  expected=$(grep -E '^PMSEC_VERSION=' "$PMSEC" | head -1 | sed -E 's/^PMSEC_VERSION="([^"]+)".*/\1/')
  for flag in --version -V; do
    local home out rc
    home=$(setup_home)
    out=$(run_pmsec "$home" -- "$flag" 2>&1)
    rc=$?
    rm -rf -- "$home"
    assert_eq "$flag exit" "0" "$rc" || return 1
    assert_eq "$flag out" "pmsec $expected" "$out" || return 1
  done
}

t_hardening_extras_roundtrip() {
  local home pnpmrc; home=$(setup_home); pnpmrc="$home/.config/pnpm/rc"
  mkdir -p "$home/.config/pnpm"
  printf 'minimum-release-age=20160\n' > "$pnpmrc"
  local out rc
  out=$(run_pmsec "$home" -- --check --json --tool pnpm 2>/dev/null); rc=$?
  assert_eq "extras-missing exit" "1" "$rc" || { rm -rf "$home"; return 1; }
  assert_match "extras-missing ok=false" '"ok": false' "$out" || { rm -rf "$home"; return 1; }
  run_pmsec "$home" -- --tool pnpm >/dev/null
  assert_match "trust-policy written" '^trust-policy=no-downgrade$' "$(cat "$pnpmrc")" || { rm -rf "$home"; return 1; }
  assert_match "block-exotic-subdeps written" '^block-exotic-subdeps=true$' "$(cat "$pnpmrc")" || { rm -rf "$home"; return 1; }
  assert_match "strict-dep-builds written" '^strict-dep-builds=true$' "$(cat "$pnpmrc")" || { rm -rf "$home"; return 1; }
  assert_match "verify-deps-before-run written" '^verify-deps-before-run=error$' "$(cat "$pnpmrc")" || { rm -rf "$home"; return 1; }
  assert_match "minimum-release-age-strict written" '^minimum-release-age-strict=true$' "$(cat "$pnpmrc")" || { rm -rf "$home"; return 1; }
  out=$(run_pmsec "$home" -- --check --json --tool pnpm); rc=$?
  assert_eq "after-enable exit" "0" "$rc" || { rm -rf "$home"; return 1; }
  assert_match "after-enable ok=true" '"ok": true' "$out" || { rm -rf "$home"; return 1; }
  run_pmsec "$home" -- --disable --tool pnpm >/dev/null
  local after; after=$(cat "$pnpmrc")
  ! printf '%s' "$after" | grep -q 'trust-policy' || { LAST_FAIL="trust-policy not removed"; rm -rf "$home"; return 1; }
  ! printf '%s' "$after" | grep -q 'block-exotic-subdeps' || { LAST_FAIL="block-exotic-subdeps not removed"; rm -rf "$home"; return 1; }
  ! printf '%s' "$after" | grep -q 'strict-dep-builds' || { LAST_FAIL="strict-dep-builds not removed"; rm -rf "$home"; return 1; }
  ! printf '%s' "$after" | grep -q 'verify-deps-before-run' || { LAST_FAIL="verify-deps-before-run not removed"; rm -rf "$home"; return 1; }
  rm -rf -- "$home"
}

# Catches a class of formatting bug where the human-readable output
# leaks unresolved placeholders ({N}) because of a string-construction
# mistake (e.g. operator precedence between concat and format). This
# scans every code path that emits a formatted line.
t_human_output_has_no_unresolved_placeholders() {
  local home out scenario
  for scenario in 'enable' 'keep' 'upgrade' 'check_fail' 'check_pass' 'disable'; do
    home=$(setup_home)
    case "$scenario" in
      enable)     out=$(run_pmsec "$home" -- --tool npm --days 7 2>&1) ;;
      keep)       printf 'min-release-age=99\n' > "$home/.npmrc"
                  out=$(run_pmsec "$home" -- --tool npm 2>&1) ;;
      upgrade)    printf 'min-release-age=3\n' > "$home/.npmrc"
                  out=$(run_pmsec "$home" -- --tool npm --days 7 2>&1) ;;
      check_fail) out=$(run_pmsec "$home" -- --check 2>&1; true) ;;
      check_pass) run_pmsec "$home" -- >/dev/null 2>&1
                  out=$(run_pmsec "$home" -- --check 2>&1) ;;
      disable)    run_pmsec "$home" -- --tool npm >/dev/null 2>&1
                  out=$(run_pmsec "$home" -- --disable --tool npm 2>&1) ;;
    esac
    rm -rf -- "$home"
    if printf '%s' "$out" | grep -Eq '\{[0-9]+\}'; then
      LAST_FAIL="scenario=$scenario leaked placeholder. output: $out"
      return 1
    fi
  done
  return 0
}
T "human output never leaks unresolved placeholders" t_human_output_has_no_unresolved_placeholders
T "enable writes the bundle for every tool" t_enable_writes_all
T "check passes after enable across all tools" t_check_passes_after_enable
T "check fails when bundle missing" t_check_fails_when_missing
T "disable preserves unrelated keys per file" t_disable_preserves_unrelated_keys
T "enable upgrades values that are weaker than the request" t_enable_upgrades_weak_existing_value
T "enable preserves stricter existing cooldowns" t_enable_preserves_stricter_existing_cooldown
T "enable --days upgrades when request exceeds existing" t_enable_days_upgrades_when_request_exceeds_existing
T "enable --force overwrites stricter existing values" t_enable_force_overwrites_stricter_existing
T "--tool restricts which tools get written" t_tool_filter_restricts
T "Windows uv path uses APPDATA" t_windows_uv_path
T "--json emits parseable JSON for check" t_json_check
T "bun enable inserts into existing [install] section" t_bun_inserts_into_existing_section
T "bun enable creates [install] section if missing" t_bun_creates_section_if_missing
T "yarn check parses npmMinimalAgeGate days correctly" t_yarn_check_parses_days
T "pnpm check normalizes minutes to days" t_pnpm_normalizes_minutes
T "bundler enable writes quoted days and preserves unrelated keys" t_bundler_enable_preserves_unrelated_keys
T "bundler check parses BUNDLE_COOLDOWN days" t_bundler_check_parses_days
T ".bak is created once and never overwritten" t_bak_created_once
T "--days N overrides bundle cooldown for enable and check" t_days_overrides_bundle_cooldown
T "--days rejects non-positive integers with exit 2" t_days_rejects_invalid
T "rejects positional argument with exit 2" t_enable_rejects_positional_arg
T "--check and --disable are mutually exclusive" t_check_and_disable_mutually_exclusive
T "--version prints PMSEC_VERSION" t_version_flag
t_pnpm_11_default_enforced() {
  local home; home=$(setup_home)
  mkdir -p "$home/.config/pnpm"
  printf 'minimumReleaseAge: 4320\n' > "$home/.config/pnpm/config.yaml"
  local out rc
  out=$(run_pmsec "$home" PMSEC_PNPM_VERSION=11.0.0 -- --check --json --tool pnpm 2>/dev/null); rc=$?
  rm -rf -- "$home"
  # pnpm 11 reads config.yaml, not the legacy rc file.
  assert_match "yaml path" '"path": ".*/config.yaml"' "$out" || return 1
  assert_match "yaml key" '"key": "minimumReleaseAge"' "$out" || return 1
  # blockExoticSubdeps should be reported as ok+defaultEnforced; trustPolicy still missing.
  assert_match "blockExoticSubdeps default-enforced" '"key": "blockExoticSubdeps", "configured": null,[^}]*"ok": true,[^}]*"defaultEnforced": true' "$out" || return 1
  assert_match "trustPolicy still failing" '"key": "trustPolicy", "configured": null,[^}]*"ok": false' "$out" || return 1
  assert_eq "exit code (trustPolicy still failing)" "1" "$rc"
}

t_pnpm_11_ignores_legacy_rc() {
  local home; home=$(setup_home)
  mkdir -p "$home/.config/pnpm"
  printf 'minimum-release-age=10080\ntrust-policy=no-downgrade\n' > "$home/.config/pnpm/rc"
  local out rc
  out=$(run_pmsec "$home" PMSEC_PNPM_VERSION=11.28.5 -- --check --json --tool pnpm 2>/dev/null); rc=$?
  rm -rf -- "$home"
  assert_eq "legacy rc-only check fails" "1" "$rc" || return 1
  assert_match "legacy rc value ignored" '"configured": null' "$out" || return 1
  assert_match "yaml path" '"path": ".*/config.yaml"' "$out"
}

t_pnpm_pre11_no_default_enforcement() {
  local home; home=$(setup_home)
  mkdir -p "$home/.config/pnpm"
  printf 'minimum-release-age=4320\n' > "$home/.config/pnpm/rc"
  local out
  out=$(run_pmsec "$home" PMSEC_PNPM_VERSION=10.26.0 -- --check --json --tool pnpm 2>/dev/null)
  rm -rf -- "$home"
  # pnpm 10 still reads rc. No defaultEnforced field, ok must be false.
  assert_match "rc path" '"path": ".*/rc"' "$out" || return 1
  ! printf '%s' "$out" | grep -q 'defaultEnforced' || { LAST_FAIL="pnpm 10 must not set defaultEnforced"; return 1; }
  assert_match "block-exotic-subdeps not ok under pnpm 10" '"key": "block-exotic-subdeps", "configured": null, "expected": "true", "ok": false' "$out"
}

T "hardening extras roundtrip (check / enable / disable)" t_hardening_extras_roundtrip
T "pnpm 11 reads config.yaml and default-enforces missing blockExoticSubdeps" t_pnpm_11_default_enforced
T "pnpm 11 ignores legacy rc values" t_pnpm_11_ignores_legacy_rc
T "pnpm <11 still flags missing block-exotic-subdeps" t_pnpm_pre11_no_default_enforcement

# PMSEC_HOME redirects writes off of $HOME so root-context orchestrators
# (Jamf, Intune, Ansible, SCCM, scheduled tasks, RMM, …) can target the
# logged-in user's home without overriding every per-tool env var.
t_pmsec_home_redirects() {
  local real fake; real=$(setup_home); fake=$(setup_home)
  # HOME points at $real but PMSEC_HOME redirects everything to $fake.
  env -i PATH="$PATH" HOME="$real" XDG_CONFIG_HOME="$fake/.config" \
    PMSEC_PNPM_VERSION=none PMSEC_MISE_VERSION=none PMSEC_HOME="$fake" \
    bash "$PMSEC" >/dev/null 2>&1
  local rc=$?
  local has_real=0 has_fake=0
  [ -e "$real/.npmrc" ] && has_real=1
  [ -e "$fake/.npmrc" ] && has_fake=1
  rm -rf -- "$real" "$fake"
  assert_eq "exit code 0" "0" "$rc" || return 1
  assert_eq "$HOME/.npmrc untouched" "0" "$has_real" || return 1
  assert_eq "PMSEC_HOME/.npmrc written" "1" "$has_fake" || return 1
}

T "PMSEC_HOME overrides \$HOME" t_pmsec_home_redirects

# `pmsec --doctor --json` reports per-tool path resolution and parent-dir
# writability — the read-only diagnostic an operator runs to figure out
# where pmsec would land before they care about the actual write.
t_doctor_json_shape() {
  local home; home=$(setup_home)
  local out rc
  out=$(run_pmsec "$home" -- --doctor --json); rc=$?
  rm -rf -- "$home"
  assert_eq "exit code 0 on fresh home" "0" "$rc" || return 1
  assert_match "doctor=true" '"doctor": true' "$out" || return 1
  assert_match "ok=true" '"ok": true' "$out" || return 1
  assert_match "pmsecHomeSource=HOME" '"pmsecHomeSource": "HOME"' "$out" || return 1
  for tool in npm pnpm yarn bun cargo mise aube uv bundler composer; do
    assert_match "$tool entry present" "\"tool\": \"$tool\"" "$out" || return 1
  done
  assert_match "parentWritable surfaced" '"parentWritable": true' "$out" || return 1
}

T "doctor --json reports per-tool writability on fresh home" t_doctor_json_shape

# When the parent dir is read-only, doctor must flip ok=false and exit 1.
t_doctor_blocks_on_unwritable_parent() {
  local home; home=$(setup_home)
  local ro="$home/ro"
  mkdir -p "$ro"
  chmod 500 "$ro"
  local out rc
  out=$(env -i PATH="$PATH" HOME="$ro" XDG_CONFIG_HOME="$ro/.config" \
    NPM_CONFIG_USERCONFIG="$ro/.npmrc" PMSEC_PNPM_VERSION=none \
    bash "$PMSEC" --doctor --json --tool npm); rc=$?
  chmod 700 "$ro"
  rm -rf -- "$home"
  assert_eq "exit code 1 when parent read-only" "1" "$rc" || return 1
  assert_match "ok=false" '"ok": false' "$out" || return 1
  assert_match "parentWritable=false" '"parentWritable": false' "$out" || return 1
}

if [ "$(id -u)" -eq 0 ]; then
  printf 'SKIP  doctor blocks when parent directory is not writable (root bypasses permission bits)\n'
else
  T "doctor blocks when parent directory is not writable" t_doctor_blocks_on_unwritable_parent
fi

# explain_fs_error must surface a chown hint when the underlying write fails
# with Permission denied. We force this by chmod 500-ing the home dir so the
# atomic rename inside write_atomic fails.
t_explain_chown_hint_on_eacces() {
  local home; home=$(setup_home)
  printf 'registry=https://r/\n' > "$home/.npmrc"
  chmod 400 "$home/.npmrc"
  chmod 500 "$home"
  local err
  err=$(run_pmsec "$home" -- --tool npm 2>&1 >/dev/null)
  chmod 700 "$home"
  chmod 600 "$home/.npmrc"
  rm -rf -- "$home"
  assert_match "chown hint present" 'Check file ownership' "$err"
}

if [ "$(id -u)" -eq 0 ]; then
  printf 'SKIP  explain_fs_error emits chown hint on EACCES (root bypasses permission bits)\n'
else
  T "explain_fs_error emits chown hint on EACCES" t_explain_chown_hint_on_eacces
fi

# write_atomic step labels: when the target file is a symlink we refuse and
# emit a labeled error. Use that to verify the prefix exists.
t_write_atomic_step_label_on_symlink() {
  local home; home=$(setup_home)
  ln -s /nonexistent-target "$home/.npmrc"
  local err
  err=$(run_pmsec "$home" -- --tool npm 2>&1 >/dev/null)
  rm -rf -- "$home"
  assert_match "symlink refusal labeled" 'refusing to write through symlink' "$err"
}

T "write_atomic refuses to follow a symlink with a labeled error" t_write_atomic_step_label_on_symlink

# A dangling symlink planted at the .bak path passes `! -e`; cp would then
# create the backup (possibly holding registry tokens) at the link target.
t_write_atomic_refuses_symlink_bak() {
  local home; home=$(setup_home)
  printf 'registry=https://original/\n' > "$home/.npmrc"
  ln -s /nonexistent-target "$home/.npmrc.bak"
  local err code
  err=$(run_pmsec "$home" -- --tool npm 2>&1 >/dev/null); code=$?
  local content; content=$(cat "$home/.npmrc")
  rm -rf -- "$home"
  assert_match "bak symlink refusal" 'refusing to write backup through symlink' "$err" || return
  [ "$code" -ne 0 ] || { printf 'expected non-zero exit\n'; return 1; }
  assert_match "config untouched" '^registry=https://original/$' "$content"
}

T "write_atomic refuses a symlink planted at the .bak path" t_write_atomic_refuses_symlink_bak

# cargo writes [registry].global-min-publish-age, tracking --days, and check
# accepts any value at least as strict. The old [install].minimum-release-age
# key was never supported by cargo and must be removed on write.
t_cargo_global_min_publish_age() {
  local home; home=$(setup_home)
  local ch="$home/cargo" out rc
  run_pmsec "$home" CARGO_HOME="$ch" -- --tool cargo --days 7 >/dev/null
  out=$(cat "$ch/config.toml")
  assert_match "registry publish age" '^global-min-publish-age = "7 days"$' "$out" || { rm -rf -- "$home"; return 1; }
  ! printf '%s' "$out" | grep -q 'minimum-release-age' || { LAST_FAIL="legacy install key still written"; rm -rf -- "$home"; return 1; }
  out=$(run_pmsec "$home" CARGO_HOME="$ch" -- --check --tool cargo --days 7 --json); rc=$?
  assert_eq "check passes" "0" "$rc" || { rm -rf -- "$home"; return 1; }
  assert_match "primary row" '"key": "global-min-publish-age", "path": "[^"]*config.toml", "configured": "\\"7 days\\"", "days": 7' "$out" || { rm -rf -- "$home"; return 1; }
  assert_match "no extra rows" '"extras": \[\]' "$out" || { rm -rf -- "$home"; return 1; }
  printf '[registry]\nglobal-min-publish-age = "1 days"\n' > "$ch/config.toml"
  run_pmsec "$home" CARGO_HOME="$ch" -- --check --tool cargo --days 7 >/dev/null 2>&1; rc=$?
  assert_eq "weaker publish age fails check" "1" "$rc" || { rm -rf -- "$home"; return 1; }
  printf '[registry]\nglobal-min-publish-age = "2 weeks"\n' > "$ch/config.toml"
  run_pmsec "$home" CARGO_HOME="$ch" -- --check --tool cargo --days 7 >/dev/null 2>&1; rc=$?
  assert_eq "stricter publish age passes check" "0" "$rc" || { rm -rf -- "$home"; return 1; }
  printf '[install]\nminimum-release-age = "7d"\n[registry]\nglobal-min-publish-age = "1 days"\n' > "$ch/config.toml"
  run_pmsec "$home" CARGO_HOME="$ch" -- --disable --tool cargo >/dev/null
  assert_file_eq "disable removes both" '[install]
[registry]
' "$ch/config.toml" || { rm -rf -- "$home"; return 1; }
  rm -rf -- "$home"
}

T "cargo writes global-min-publish-age tracking --days" t_cargo_global_min_publish_age

t_composer_roundtrip() {
  local home; home=$(setup_home)
  local cfg="$home/.config/composer/config.json"
  run_pmsec "$home" -- --tool composer --days 7 >/dev/null
  local text; text=$(cat "$cfg")
  assert_match "composer cooldown" '"period": "7 days"' "$text" || { rm -rf "$home"; return 1; }
  assert_match "composer allow-plugins" '"allow-plugins": false' "$text" || { rm -rf "$home"; return 1; }
  assert_match "composer secure-http" '"secure-http": true' "$text" || { rm -rf "$home"; return 1; }
  assert_match "composer disable-tls" '"disable-tls": false' "$text" || { rm -rf "$home"; return 1; }
  assert_match "composer abandoned" '"abandoned": "fail"' "$text" || { rm -rf "$home"; return 1; }
  run_pmsec "$home" -- --check --json --tool composer --days 7 >/dev/null
  assert_eq "composer check exit" "0" "$?" || { rm -rf "$home"; return 1; }
  run_pmsec "$home" -- --disable --tool composer >/dev/null
  local out; out=$(run_pmsec "$home" -- --check --tool composer 2>/dev/null)
  rm -rf -- "$home"
  assert_match "composer missing after disable" 'MISSING composer' "$out"
}

T "composer writes JSON config and check/disable roundtrip" t_composer_roundtrip

t_composer_preserves_unrelated_keys() {
  local home; home=$(setup_home)
  local ch="$home/composer-home"
  mkdir -p "$ch"
  printf '{\n  "config": {\n    "preferred-install": "dist",\n    "audit": {\n      "ignore": ["vendor/pkg"]\n    }\n  },\n  "repositories": {\n    "packagist": false\n  }\n}\n' > "$ch/config.json"
  run_pmsec "$home" COMPOSER_HOME="$ch" -- --tool composer >/dev/null
  local text; text=$(cat "$ch/config.json")
  assert_match "unrelated config preserved" '"preferred-install": "dist"' "$text" || { rm -rf "$home"; return 1; }
  assert_match "unrelated audit entry preserved" '"ignore": \["vendor/pkg"\]' "$text" || { rm -rf "$home"; return 1; }
  assert_match "unrelated top-level preserved" '"packagist": false' "$text" || { rm -rf "$home"; return 1; }
  run_pmsec "$home" COMPOSER_HOME="$ch" -- --disable --tool composer >/dev/null
  text=$(cat "$ch/config.json")
  rm -rf -- "$home"
  assert_match "unrelated config kept after disable" '"preferred-install": "dist"' "$text" || return 1
  ! printf '%s' "$text" | grep -q '"period"' || { LAST_FAIL="composer cooldown not removed"; return 1; }
  return 0
}

T "composer preserves unrelated JSON keys" t_composer_preserves_unrelated_keys

# ---------- mise config layer: substrate helpers ----------
# Phase 2 adds substrate only: the new path family and the mode gate exist but
# nothing in the CLI calls them yet, so these tests reach the helpers directly.
# `source bash/pmsec` defines them without running main (see the guard at the
# bottom of that file).
# shellcheck source=../pmsec
. "$PMSEC"

# call_helper [VAR=val ...] -- FN [args ...]
# Run a sourced pmsec helper in a scrubbed environment (env -i, like
# run_pmsec) so the host's MISE_*/XDG_*/LOCALAPPDATA can't leak into the
# expectation. Callers append `2>&1` when "prints nothing" must cover stderr.
call_helper() {
  local extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    extra[${#extra[@]}]="$1"; shift
  done
  shift
  local fn="$1"; shift
  if [ "${#extra[@]}" -eq 0 ]; then
    env -i PATH="$PATH" bash -c '. "$1"; shift; "$@"' _ "$PMSEC" "$fn" "$@"
  else
    env -i PATH="$PATH" "${extra[@]}" bash -c '. "$1"; shift; "$@"' _ "$PMSEC" "$fn" "$@"
  fi
}

# call_snippet [VAR=val ...] -- SNIPPET [ARG ...]
# Source the port, then run SNIPPET through bash -c. call_helper only returns
# stdout, so a probe that has to read the globals a helper sets needs its own
# snippet. ARGs arrive as "$@" and may carry raw text: an argv element keeps
# newlines, quotes and trailing blanks that a $(...) capture would eat.
call_snippet() {
  local extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    extra[${#extra[@]}]="$1"; shift
  done
  shift
  local snippet="$1"; shift
  if [ "${#extra[@]}" -eq 0 ]; then
    env -i PATH="$PATH" bash -c '
      . "$1"; shift
      snippet=$1; shift
      eval "$snippet"
    ' _ "$PMSEC" "$snippet" "$@"
  else
    env -i PATH="$PATH" "${extra[@]}" bash -c '
      . "$1"; shift
      snippet=$1; shift
      eval "$snippet"
    ' _ "$PMSEC" "$snippet" "$@"
  fi
}

# field NAME BLOCK — the value of the first `NAME=...` line in a probe block.
field() {
  local name="$1" rest="$2" line
  while [ -n "$rest" ]; do
    case "$rest" in
      *$'\n'*) line="${rest%%$'\n'*}"; rest="${rest#*$'\n'}" ;;
      *) line="$rest"; rest="" ;;
    esac
    case "$line" in
      "$name="*) printf '%s' "${line#"$name="}"; return 0 ;;
    esac
  done
  return 0
}

# Probe snippets for the miserc helpers. A quoted heredoc keeps every `$'...'`
# escape and quote literal, and the probes spell newlines as <LF> and CRs as
# <CR> so a trailing newline survives `$(...)`.
MISERC_PARSE_PROBE=$(cat <<'SNIPPET'
miserc_env_parse_text "$1" "$2"; rc=$?
printf 'rc=%s\npath=%s\nreason=%s\nfound=%s\nstart=%s\nend=%s\n' \
  "$rc" "${MISEC_ERROR_PATH-}" "${MISEC_ERROR_REASON-}" "${MISEC_ENV_FOUND-}" \
  "${MISEC_ENV_START-}" "${MISEC_ENV_END-}"
names=""; tokens=""; sep=""; i=0
while [ "$i" -lt "${#MISEC_ENV_VALUES[@]}" ]; do
  names="$names$sep${MISEC_ENV_VALUES[i]}"
  tokens="$tokens$sep${MISEC_ENV_TOKENS[i]}"
  sep='|'
  i=$((i+1))
done
printf 'nvalues=%s\nnames=%s\ntokens=%s\n' "${#MISEC_ENV_VALUES[@]}" "$names" "$tokens"
SNIPPET
)

MISERC_WRITE_PROBE=$(cat <<'SNIPPET'
label=$1; text=$2; shift 2
miserc_env_write_pmsec_text "$label" "$text" "$@"; rc=$?
printf 'rc=%s\npath=%s\nreason=%s\nset=%s\n' \
  "$rc" "${MISEC_ERROR_PATH-}" "${MISEC_ERROR_REASON-}" "${MISEC_ENV_OUTPUT+1}"
if [ -n "${MISEC_ENV_OUTPUT+1}" ]; then
  out="${MISEC_ENV_OUTPUT//$'\r'/<CR>}"
  printf 'out=%s\n' "${out//$'\n'/<LF>}"
fi
SNIPPET
)

MISERC_SPLICE_PROBE=$(cat <<'SNIPPET'
miserc_env_parse_text "$1" "$2" || exit 1
t=$2
pre="${t:0:MISEC_ENV_START}"
mid="${t:MISEC_ENV_START:MISEC_ENV_END-MISEC_ENV_START}"
post="${t:MISEC_ENV_END}"
printf 'pre=%s\nmid=%s\npost=%s\n' "${pre//$'\n'/<LF>}" "${mid//$'\n'/<LF>}" "${post//$'\n'/<LF>}"
SNIPPET
)

MISERC_TWICE_PROBE=$(cat <<'SNIPPET'
label=$1; text=$2; shift 2
miserc_env_write_pmsec_text "$label" "$text" "$@" || { printf 'rc=1\nreason=%s\n' "$MISEC_ERROR_REASON"; exit 0; }
first=$MISEC_ENV_OUTPUT
miserc_env_write_pmsec_text "$label" "$first" "$@" || { printf 'rc=2\nreason=%s\n' "$MISEC_ERROR_REASON"; exit 0; }
second=$MISEC_ENV_OUTPUT
if [ "$first" = "$second" ]; then printf 'same=1\n'; else printf 'same=0\n'; fi
printf 'first=%s\nsecond=%s\n' "${first//$'\n'/<LF>}" "${second//$'\n'/<LF>}"
SNIPPET
)

miserc_parse() { call_snippet -- "$MISERC_PARSE_PROBE" "$1" "$2"; }
miserc_write() { call_snippet -- "$MISERC_WRITE_PROBE" "$@"; }
miserc_splice() { call_snippet -- "$MISERC_SPLICE_PROBE" "$1" "$2"; }
miserc_twice() { call_snippet -- "$MISERC_TWICE_PROBE" "$@"; }

# accept_case LABEL TEXT FOUND NAMES [TOKENS]
# The parse must succeed, report FOUND, and decode exactly NAMES (`|`-joined,
# in order). When TOKENS is given the raw tokens must match too.
accept_case() {
  local label="$1" text="$2" found="$3" names="$4" tokens="${5-}" out
  out=$(miserc_parse "$label" "$text")
  assert_eq "accept[$label]: rc" "0" "$(field rc "$out")" || return 1
  assert_eq "accept[$label]: path" "" "$(field path "$out")" || return 1
  assert_eq "accept[$label]: found" "$found" "$(field found "$out")" || return 1
  assert_eq "accept[$label]: names" "$names" "$(field names "$out")" || return 1
  if [ "$#" -ge 5 ]; then
    assert_eq "accept[$label]: tokens" "$tokens" "$(field tokens "$out")"
  fi
}

# reject_case LABEL TEXT REASON
# The parse must fail with exactly REASON, LABEL in MISEC_ERROR_PATH, and no
# output at all.
reject_case() {
  local label="$1" text="$2" reason="$3" out quiet
  out=$(miserc_parse "$label" "$text")
  assert_eq "reject[$reason]: rc" "1" "$(field rc "$out")" || return 1
  assert_eq "reject[$reason]: path" "$label" "$(field path "$out")" || return 1
  assert_eq "reject[$reason]: reason" "$reason" "$(field reason "$out")" || return 1
  quiet=$(call_helper -- miserc_env_parse_text "$label" "$text" 2>&1)
  assert_eq "reject[$reason]: silent" "" "$quiet"
}

# Sourcing the port must define the helpers and do nothing else: no output, no
# writes, no CLI run.
t_source_guard_defines_without_running_main() {
  local home out rc wrote=0
  home=$(setup_home)
  out=$(env -i PATH="$PATH" HOME="$home" XDG_CONFIG_HOME="$home/.config" \
    bash -c '. "$1" || exit 1
      for fn in path_mise_dir path_mise_system_miserc mise_supports_new_mode \
                miserc_env_parse_text miserc_env_write_pmsec_text \
                mise_selector_read miserc_env_write_pmsec; do
        declare -F "$fn" >/dev/null || exit 1
      done' \
    _ "$PMSEC" 2>&1); rc=$?
  [ -e "$home/.npmrc" ] && wrote=1
  rm -rf -- "$home"
  assert_eq "source exits 0" "0" "$rc" || return 1
  assert_eq "source prints nothing" "" "$out" || return 1
  assert_eq "source does not run main" "0" "$wrote"
}

# The legacy resolver keeps its own rules: MISE_CONFIG_DIR and the new-mode
# default must never move it, and an empty MISE_GLOBAL_CONFIG_FILE is unset.
t_path_mise_legacy_untouched() {
  local h=/pmsec-nohome out
  out=$(call_helper HOME="$h" XDG_CONFIG_HOME="$h/xdg" -- path_mise)
  assert_eq "legacy: XDG default" "$h/xdg/mise/config.toml" "$out" || return 1
  out=$(call_helper HOME="$h" XDG_CONFIG_HOME="$h/xdg" MISE_GLOBAL_CONFIG_FILE="$h/global.toml" -- path_mise)
  assert_eq "legacy: MISE_GLOBAL_CONFIG_FILE wins" "$h/global.toml" "$out" || return 1
  out=$(call_helper HOME="$h" XDG_CONFIG_HOME="$h/xdg" MISE_GLOBAL_CONFIG_FILE= -- path_mise)
  assert_eq "legacy: empty MISE_GLOBAL_CONFIG_FILE falls through" "$h/xdg/mise/config.toml" "$out" || return 1
  out=$(call_helper HOME="$h" XDG_CONFIG_HOME="$h/xdg" MISE_CONFIG_DIR="$h/mise-dir" -- path_mise)
  assert_eq "legacy: MISE_CONFIG_DIR does not redirect" "$h/xdg/mise/config.toml" "$out" || return 1
  out=$(call_helper HOME="$h" PMSEC_PLATFORM=win32 LOCALAPPDATA="$h/appdata" -- path_mise)
  assert_eq "legacy: win32 uses LOCALAPPDATA" "$h/appdata/mise/config.toml" "$out"
}

t_path_mise_dir_overrides() {
  local h=/pmsec-nohome out
  out=$(call_helper HOME="$h" -- path_mise_dir)
  assert_eq "dir: HOME default" "$h/.config/mise" "$out" || return 1
  out=$(call_helper HOME="$h" PMSEC_HOME="$h/redirect" -- path_mise_dir)
  assert_eq "dir: PMSEC_HOME wins over HOME" "$h/redirect/.config/mise" "$out" || return 1
  out=$(call_helper HOME="$h" XDG_CONFIG_HOME="$h/xdg" -- path_mise_dir)
  assert_eq "dir: XDG override" "$h/xdg/mise" "$out" || return 1
  out=$(call_helper HOME="$h" XDG_CONFIG_HOME="$h/xdg" MISE_CONFIG_DIR="$h/mise-dir" -- path_mise_dir)
  assert_eq "dir: MISE_CONFIG_DIR wins over XDG" "$h/mise-dir" "$out" || return 1
  out=$(call_helper HOME="$h" XDG_CONFIG_HOME="$h/xdg" MISE_CONFIG_DIR= -- path_mise_dir)
  assert_eq "dir: empty MISE_CONFIG_DIR falls through" "$h/xdg/mise" "$out" || return 1
  out=$(call_helper HOME="$h" XDG_CONFIG_HOME= -- path_mise_dir)
  assert_eq "dir: empty XDG falls through" "$h/.config/mise" "$out" || return 1
  out=$(call_helper HOME="$h" PMSEC_PLATFORM=win32 LOCALAPPDATA="$h/appdata" -- path_mise_dir)
  assert_eq "dir: win32 default ignores LOCALAPPDATA" "$h/.config/mise" "$out"
}

t_path_mise_derived_family() {
  local h=/pmsec-nohome d out
  d="$h/mise-dir"
  out=$(call_helper HOME="$h" MISE_CONFIG_DIR="$d" -- path_mise_base_config)
  assert_eq "derived: base config" "$d/config.toml" "$out" || return 1
  out=$(call_helper HOME="$h" MISE_CONFIG_DIR="$d" -- path_mise_pmsec_config)
  assert_eq "derived: pmsec config" "$d/config.pmsec.toml" "$out" || return 1
  out=$(call_helper HOME="$h" MISE_CONFIG_DIR="$d" -- path_mise_local_miserc)
  assert_eq "derived: local miserc" "$d/miserc.local.toml" "$out" || return 1
  out=$(call_helper HOME="$h" MISE_CONFIG_DIR="$d" -- path_mise_shared_miserc)
  assert_eq "derived: shared miserc" "$d/miserc.toml" "$out" || return 1
  # The same family must follow the XDG-derived default, not just the override.
  out=$(call_helper HOME="$h" XDG_CONFIG_HOME="$h/xdg" -- path_mise_pmsec_config)
  assert_eq "derived: follows XDG" "$h/xdg/mise/config.pmsec.toml" "$out"
}

t_path_mise_system_miserc() {
  local h=/pmsec-nohome s out
  s="$h/sys"
  out=$(call_helper HOME="$h" MISE_SYSTEM_CONFIG_DIR="$s" -- path_mise_system_miserc)
  assert_eq "system: override" "$s/miserc.toml" "$out" || return 1
  out=$(call_helper HOME="$h" -- path_mise_system_miserc)
  assert_eq "system: POSIX default" "/etc/mise/miserc.toml" "$out" || return 1
  # win32 default lives on the drive mise runs from, not SYSTEMDRIVE. The drive
  # root is injected so the case is host-independent.
  out=$(call_helper HOME="$h" MISE_SYSTEM_CONFIG_DIR= PMSEC_PLATFORM=win32 -- path_mise_system_miserc "D:/")
  assert_eq "system: empty override falls to drive root" 'D:\etc\mise\miserc.toml' "$out" || return 1
  out=$(call_helper HOME="$h" PMSEC_PLATFORM=win32 -- path_mise_system_miserc 'D:\')
  assert_eq "system: backslash drive root normalized" 'D:\etc\mise\miserc.toml' "$out" || return 1
  out=$(call_helper HOME="$h" MISE_SYSTEM_CONFIG_DIR="$s" PMSEC_PLATFORM=win32 -- path_mise_system_miserc "D:/")
  assert_eq "system: override beats drive root" "$s/miserc.toml" "$out"
}

# Only mise >= 2026.11.0 with no legacy override opts into the new mode; an
# empty MISE_GLOBAL_CONFIG_FILE counts as unset. Versions come from
# PMSEC_MISE_VERSION, so no host mise binary is consulted.
t_mise_supports_new_mode_matrix() {
  local version override out rc expect seq
  for version in 2026.11.0 2026.10.25 2026.12.0 none; do
    for override in unset empty set; do
      case "$override" in
        unset) out=$(call_helper PMSEC_MISE_VERSION="$version" -- mise_supports_new_mode 2>&1) ;;
        empty) out=$(call_helper PMSEC_MISE_VERSION="$version" MISE_GLOBAL_CONFIG_FILE= -- mise_supports_new_mode 2>&1) ;;
        set)   out=$(call_helper PMSEC_MISE_VERSION="$version" MISE_GLOBAL_CONFIG_FILE=/pmsec-nohome/global.toml -- mise_supports_new_mode 2>&1) ;;
      esac
      rc=$?
      expect=1
      if [ "$override" != "set" ]; then
        case "$version" in
          2026.11.0|2026.12.0) expect=0 ;;
        esac
      fi
      assert_eq "mode: mise $version, override $override (exit)" "$expect" "$rc" || return 1
      assert_eq "mode: mise $version, override $override (silent)" "" "$out" || return 1
    done
  done
  # No caching: a second call in the same shell must see the changed env.
  seq=$(env -i PATH="$PATH" PMSEC_MISE_VERSION=2026.11.0 bash -c '
    . "$1"
    mise_supports_new_mode; printf "first=%s " "$?"
    MISE_GLOBAL_CONFIG_FILE=/pmsec-nohome/global.toml
    mise_supports_new_mode; printf "second=%s" "$?"
  ' _ "$PMSEC" 2>&1)
  assert_eq "mode: re-detected on every call" "first=0 second=1" "$seq"
}

# ---------- mise config layer: narrow miserc env parser ----------

# No top-level env array at all reads as "not defined" — including the shapes
# the writer refuses to touch ([env] tables and dotted env.* keys).
t_miserc_parse_absent() {
  accept_case "no env: empty text" "" 0 "" || return 1
  accept_case "no env: [env] table" '[env]
A = "b"' 0 "" || return 1
  accept_case "no env: dotted key" 'env.foo = 1' 0 "" || return 1
  accept_case "no env: dotted key with spaces" 'env . foo = 1' 0 "" || return 1
  accept_case "no env: env-prefixed keys" 'envelope = true
environment = "x"
env2 = 1
envx=1' 0 ""
}

# Every accepted array shape, plus the tokens the writer reuses.
t_miserc_parse_shapes() {
  accept_case "empty array" 'env = []' 1 "" || return 1
  accept_case "empty array spaced" 'env = [ ]' 1 "" || return 1
  accept_case "empty array multiline" 'env = [
  # nothing yet
]' 1 "" || return 1
  accept_case "single element" 'env = ["work"]' 1 'work' '"work"' || return 1
  accept_case "inline pair" 'env = ["a", "b"]' 1 'a|b' || return 1
  accept_case "tight spacing" 'env=["a","b"]' 1 'a|b' || return 1
  accept_case "trailing comma" 'env = ["a", ]' 1 'a' || return 1
  accept_case "trailing comma on its own line" 'env = [
  "a",
]' 1 'a' || return 1
  accept_case "multiline with comments" 'env = [
  # leading
  "work", # trailing
  '"'"'lit'"'"',
]' 1 'work|lit' "\"work\"|'lit'" || return 1
  accept_case "indented key" '  env = ["a"]' 1 'a' || return 1
  accept_case "tab-indented key" '	env = ["a"]' 1 'a' || return 1
  accept_case "tabs around the assignment" $'env\t=\t["a"]\t' 1 'a' || return 1
  accept_case "comments between every token" 'env = [
  "a" # one
  , # the separator sits on its own line
  "b"
]' 1 'a|b' || return 1
  accept_case "duplicate names" 'env = ["a", "a"]' 1 'a|a' || return 1
  accept_case "literal keeps its backslash" "env = ['C:\\tmp']" 1 'C:\tmp' "'C:\\tmp'" || return 1
  accept_case "meta bytes inside strings" 'env = ["a # b", "c[d]", "e,f", " g "]' 1 'a # b|c[d]|e,f| g ' || return 1
  accept_case "name with a single quote" 'env = ["it'"'"'s"]' 1 "it's" || return 1
  accept_case "multibyte name" 'env = ["日本"]' 1 '日本' '"日本"'
}

# START/END are byte offsets: splicing them back out has to reproduce the exact
# assignment, with a BOM, indentation, comments and following lines untouched.
t_miserc_parse_splice_offsets() {
  local out text bom=$'\xEF\xBB\xBF'
  text='before = 1
env = [ "a",
  "b" ]
after = 2'
  out=$(miserc_splice misc "$text")
  assert_eq "splice: multiline array" 'pre=before = 1<LF>|mid=env = [ "a",<LF>  "b" ]|post=<LF>after = 2' \
    "pre=$(field pre "$out")|mid=$(field mid "$out")|post=$(field post "$out")" || return 1

  # START sits on the bare key, so the indentation in front of it (and the BOM
  # before the first line) is outside the replaced range.
  text="${bom}note = \"x\"
  env = ['a']   # keep
[tail]"
  out=$(miserc_splice misc "$text")
  assert_eq "splice: BOM, indentation and trailing comment" \
    "pre=${bom}note = \"x\"<LF>  |mid=env = ['a']|post=   # keep<LF>[tail]" \
    "pre=$(field pre "$out")|mid=$(field mid "$out")|post=$(field post "$out")" || return 1

  # Nothing is printed on a successful parse.
  out=$(call_helper -- miserc_env_parse_text misc 'env = ["a"]' 2>&1)
  assert_eq "splice: successful parse is silent" "" "$out"
}

# Strings and comments are opaque: env-like text inside them is never an
# assignment, and a `[table]` inside a multiline string never ends the root
# region.
t_miserc_parse_ignores_strings_and_comments() {
  local text
  text=$(cat <<'TXT'
note = "env = [\"x\"]"
flag = 'env = ["y"]'
doc = """
env = ["fake"]
[not.a.table]
"""
# env = ["commented"]
key = 1
TXT
)
  accept_case "env-like text in strings and comments" "$text" 0 "" || return 1

  text=$(cat <<'TXT'
doc = """
[env]
"""
env = ["top"]
TXT
)
  accept_case "table header inside a multiline string" "$text" 1 'top' || return 1

  text=$(cat <<'TXT'
doc = '''
[env]
'''
[tool]
env = ["scoped"]
TXT
)
  accept_case "env inside a table is not top-level" "$text" 0 ""
}

# A line-start `[` inside an open array or inline table is a value, never a
# table header, and a line-start `env` inside one is a table member, never the
# root key: neither the root region nor the assignment may reach into a
# container that has not closed yet.
t_miserc_parse_nested_containers() {
  accept_case "nested array before env" 'items = [
  [1, 2],
]
env = ["work"]' 1 'work' || return 1
  accept_case "nested array after env" 'env = ["work"]
items = [
  [1, 2],
]' 1 'work' || return 1
  accept_case "inline table on one line" 'a = { env = ["fake"] }
env = ["real"]' 1 'real' || return 1
  accept_case "inline table across lines" 'a = {
  env = ["fake"],
}
env = ["real"]' 1 'real' || return 1
  # Brackets and env-like text inside strings of a nested array are opaque too.
  accept_case "brackets inside strings" 'a = "[env]"
b = [
  "[env]",
  "env = [\"fake\"]",
]
env = ["real"]' 1 'real' || return 1
  # A header-shaped line inside an array must not end the root region either:
  # the `[b]` below is the first real header, so `env` belongs to that table.
  accept_case "header-shaped array element" 'a = [
  "[env]",
]
[b]
x = 1
env = ["scoped"]' 0 '' || return 1
  # `[[items]]` is a real header too: it ends the root region like `[items]`,
  # so an `env` key under it is scoped to that table.
  accept_case "array-of-tables header ends the root region" '[[items]]
x = 1
env = ["scoped"]' 0 '' || return 1
  accept_case "env before an array-of-tables header" 'env = ["work"]
[[items]]
x = 1' 1 'work'
}

# A basic (`"""`) block honours `\`, so an escaped triple quote is content and
# the block keeps going; a literal (`'''`) block has no escape semantics, so
# there the first closer always wins.
t_miserc_parse_multiline_escape_closer() {
  accept_case "escaped triple quote in a basic block" 'note = """
\"""
env = ["fake"]
"""
env = ["real"]' 1 'real' || return 1
  # `\\` is an escaped backslash, so the triple quote right after it closes.
  accept_case "escaped backslash then a closer" 'note = """
\\"""
env = ["real"]' 1 'real' || return 1
  accept_case "literal block closes on the first closer" "note = '''
\\'''
env = ['real']" 1 'real' || return 1
  # The escaped closer really is content: a block that stops there never closes.
  reject_case misc 'doc = """
\"""' "unterminated string in file"
}

# TOML lets the last one or two quotes before a multiline delimiter belong to
# the content (`"""a""""`), so the closer is a RUN of quotes and the whole run
# has to be consumed. Consuming exactly three left a stray quote behind, and
# that quote opened a one-line string which swallowed the `]` of the array the
# block sat in — hiding the root env assignment entirely (PR #5, Devin
# follow-up). The expected values below are node's quoteRun and PowerShell's
# Get-MisercQuoteRun verbatim: the run is capped at five, so six or more quotes
# close after the first five and the leftovers re-enter the scanner as quoting.
t_miserc_parse_multiline_quote_run() {
  # A run inside an array does not close the array when it is read as content.
  accept_case "four-quote closer keeps the array closed" 'items = ["""foo""""]
env = ["work"]' 1 'work' || return 1
  accept_case "five-quote closer keeps the array closed" 'items = ["""foo"""""]
env = ["work"]' 1 'work' || return 1
  # Runs of six and seven pins the cap, not just "consume everything": node
  # reads six as a five-quote closer plus a stray quote (so the `]` is
  # swallowed and no root env exists), and seven as a five-quote closer plus a
  # literal `""` (so the array closes). Both must survive here byte for byte.
  accept_case "six-quote run hides the root env like node" 'items = ["""foo""""""]
env = ["work"]' 0 '' || return 1
  accept_case "seven-quote run closes after the five-quote cap" 'items = ["""foo"""""""]
env = ["work"]' 1 'work' || return 1
  # Eight quotes leave a `"""` behind, which opens a block that never closes.
  reject_case misc 'items = ["""foo""""""""]
env = ["work"]' "unterminated string in file" || return 1
  # A literal block has no escapes, so its first `'''` is the closer and the
  # run still consumes the extra quote.
  accept_case "literal four-quote closer" "items = ['''foo'''']
env = ['work']" 1 'work' || return 1
  # Only a run of three or more closes; the run is the closer, so whatever
  # follows it is code again. Both shapes read the same in node.
  accept_case "four quotes close before trailing junk" 'a = ["""x"""" y]
env = ["w"]' 1 'w' || return 1
  accept_case "four quotes close before a comma" 'a = ["""x"""", 1]
env = ["w"]' 1 'w' || return 1
  # An escape pair still wins over the run: two backslashes are one escaped
  # backslash, so the four quotes after it close; four backslashes leave a `\`
  # escaping the first quote of the run, and the six-quote cap then behaves
  # exactly like node's.
  accept_case "escaped backslash then a four-quote closer" 'a = ["""x\\""""]
env = ["w"]' 1 'w' || return 1
  accept_case "two escaped backslashes then a six-quote run" 'a = ["""x\\\\""""""]
env = ["w"]' 0 '' || return 1
  # The array-element rejection is a separate path and must not have moved.
  reject_case misc 'env = ["""foo""""]
' "multiline strings are unsupported" || return 1
  # A block that never closes is still the same error, quotes at the end or not.
  reject_case misc 'items = ["""foo""
' "unterminated string in file"
}

# The writer splices around [START, END), so the same run must leave the real
# assignment byte-exact: replacing it is what keeps the file from growing a
# second `env` key on every run.
t_miserc_write_multiline_quote_run() {
  local out
  out=$(miserc_write misc 'items = ["""foo""""]
env = ["work"]' other)
  assert_eq "write quote-run 4: rc" "0" "$(field rc "$out")" || return 1
  assert_eq "write quote-run 4: replaces the real assignment" \
    'items = ["""foo""""]<LF>env = ["other", "pmsec"]' "$(field out "$out")" || return 1

  out=$(miserc_write misc 'items = ["""foo"""""]
env = ["work"]' other)
  assert_eq "write quote-run 5: replaces the real assignment" \
    'items = ["""foo"""""]<LF>env = ["other", "pmsec"]' "$(field out "$out")" || return 1

  # Six quotes hide the root env, so the writer inserts instead of replacing:
  # node does the same, which is why this is pinned rather than "fixed".
  out=$(miserc_write misc 'items = ["""foo""""""]
env = ["work"]' other)
  assert_eq "write quote-run 6: inserts above the broken value" \
    'env = ["other", "pmsec"]<LF>items = ["""foo""""""]<LF>env = ["work"]' "$(field out "$out")" || return 1

  out=$(miserc_write misc 'items = ["""foo"""""""]
env = ["work"]' other)
  assert_eq "write quote-run 7: replaces the real assignment" \
    'items = ["""foo"""""""]<LF>env = ["other", "pmsec"]' "$(field out "$out")"
}

# A one-line string that reaches the end of its line ends there: the subset does
# not validate general TOML, so the rest of the line is string content and
# scanning resumes on the next line. `unterminated string in file` is reserved
# for a `"""`/`'''` block that never closes.
t_miserc_parse_line_terminated_strings() {
  accept_case "unterminated basic string ends at the line" 'x = "abc
env = ["work"]' 1 'work' || return 1
  accept_case "unterminated literal string ends at the line" "x = 'abc
env = ['work']" 1 'work' || return 1
  # What follows the opener is string content: an env-like tail on that line is
  # not an assignment, and a `#` in it does not start a comment.
  accept_case "line-terminated string hides an env-like tail" 'x = "abc # env = ["fake"]
env = ["work"]' 1 'work' || return 1
  # An escaped quote does not close a basic string, so the line still ends it.
  accept_case "escaped quote does not close the string" 'x = "a\"b
env = ["work"]' 1 'work' || return 1
  # Past the last newline the string simply ends with the file.
  accept_case "unterminated string on the last line" 'env = ["work"]
x = "abc' 1 'work'
}

t_miserc_parse_reject_quoted_key() {
  reject_case miserc.local.toml '"env" = ["a"]' "quoted env key is unsupported" || return 1
  reject_case misc "'env' = ['a']" "quoted env key is unsupported"
}

# The scanner has to keep going after the first valid assignment to find a
# duplicate further down.
t_miserc_parse_reject_duplicate() {
  reject_case misc 'env = ["a"]
env = ["b"]' "duplicate top-level env assignment" || return 1
  reject_case misc 'env = ["a"]
key = 1

env = ["b"]' "duplicate top-level env assignment" || return 1
  # A second assignment after the first table header belongs to that table.
  accept_case "second env under a table is not a duplicate" 'env = ["a"]
[t]
env = ["b"]' 1 'a'
}

t_miserc_parse_reject_not_array() {
  reject_case misc 'env = "a"' "env must be an array" || return 1
  reject_case misc 'env = 1' "env must be an array" || return 1
  reject_case misc 'env = true' "env must be an array" || return 1
  reject_case misc 'env = { a = "b" }' "env must be an array"
}

t_miserc_parse_reject_element_forms() {
  reject_case misc 'env = [bare]' "env array elements must be single-line quoted strings" || return 1
  reject_case misc 'env = [["a"]]' "env array elements must be single-line quoted strings" || return 1
  reject_case misc 'env = [{ a = 1 }]' "env array elements must be single-line quoted strings" || return 1
  reject_case misc 'env = ["a", 1]' "env array elements must be single-line quoted strings"
}

t_miserc_parse_reject_escapes_and_multiline_elements() {
  reject_case misc 'env = ["a\tb"]' "escape sequences are unsupported" || return 1
  reject_case misc 'env = ["a\"b"]' "escape sequences are unsupported" || return 1
  reject_case misc 'env = ["""
a
"""]' "multiline strings are unsupported" || return 1
  reject_case misc "env = ['''
a
''']" "multiline strings are unsupported"
}

t_miserc_parse_reject_unterminated() {
  reject_case misc 'env = [' "unterminated env assignment" || return 1
  reject_case misc 'env = ["a"' "unterminated env assignment" || return 1
  reject_case misc 'env = ["a",' "unterminated env assignment" || return 1
  reject_case misc 'env =' "unterminated env assignment" || return 1
  reject_case misc 'env = [
  "a"
' "unterminated env assignment"
}

t_miserc_parse_reject_malformed_key() {
  reject_case misc 'env ["a"]' "malformed env assignment" || return 1
  reject_case misc 'env' "malformed env assignment" || return 1
  # A second top-level `env` key is reported as a duplicate even when its value
  # form would not parse: the key itself is what collides.
  reject_case misc 'env = ["a"]

env ["b"]' "duplicate top-level env assignment"
}

# Decision (PR #5, finding A4): comments and newlines between the key and `=`
# are accepted, matching the other three ports. Strict TOML rejects the shape,
# but a file mise cannot read is never made authoritative by accepting it, so
# parity costs nothing here.
t_miserc_parse_trivia_before_equals() {
  local out
  accept_case "comment between key and =" 'env # c
= ["work"]' 1 'work' || return 1
  accept_case "newline between key and =" 'env
= ["work"]' 1 'work' || return 1
  accept_case "comment line between key and =" 'env
# c
= ["work"]' 1 'work' || return 1
  accept_case "tab before the comment" $'env\t# c\n= ["a", "b"]' 1 'a|b' || return 1
  # The trivia sits inside [START, END): the rewrite consumes it with the key
  # and the value instead of leaving a stray comment behind.
  out=$(miserc_write misc 'env # c
= ["work"]' work)
  assert_eq "write: comment between key and = is replaced too" 'env = ["work", "pmsec"]' \
    "$(field out "$out")" || return 1
  # Skipping trivia never invents an `=`: a bare `env` stays malformed.
  reject_case misc 'env # c
x = 1' "malformed env assignment"
}

# A bare `env` with nothing after it is a half-written assignment, not "not
# defined": reporting "not defined" would let the writer append a second env
# array next to the broken one.
t_miserc_parse_bare_env_at_eof() {
  reject_case misc 'env' "malformed env assignment" || return 1
  reject_case misc 'env
' "malformed env assignment" || return 1
  reject_case misc 'env   ' "malformed env assignment" || return 1
  reject_case misc 'env # no value' "malformed env assignment" || return 1
  reject_case misc 'env
# only a comment' "malformed env assignment"
}

t_miserc_parse_reject_separators() {
  reject_case misc 'env = ["a" "b"]' "malformed env array separator" || return 1
  reject_case misc 'env = ["a",, "b"]' "malformed env array separator" || return 1
  reject_case misc 'env = [, "a"]' "malformed env array separator"
}

t_miserc_parse_reject_trailing_junk() {
  reject_case misc 'env = ["a"] junk' "unexpected content after env array" || return 1
  reject_case misc 'env = ["a"] x = 1' "unexpected content after env array" || return 1
  # A comment is not junk.
  accept_case "comment after the array" 'env = ["a"] # ok' 1 'a'
}

# Only a multiline block that never closes is an unrelated unterminated string;
# a one-line opener ends with its line (see t_miserc_parse_line_terminated_strings).
t_miserc_parse_reject_unterminated_file_string() {
  reject_case misc 'doc = """
never closed' "unterminated string in file" || return 1
  reject_case misc "doc = '''
never closed" "unterminated string in file"
}

# One structured diagnostic per failure, in the shared cross-port shape.
t_miserc_error_text_shape() {
  local out
  out=$(call_snippet -- '
    miserc_env_parse_text "path/miserc.local.toml" "env = 1" || miserc_error_text
  ')
  assert_eq "error text: shape" "invalid env in path/miserc.local.toml: env must be an array" "$out"
}

# ---------- mise config layer: narrow miserc env writer ----------

t_miserc_write_fresh() {
  local out quiet
  out=$(miserc_write misc "")
  assert_eq "write: empty input rc" "0" "$(field rc "$out")" || return 1
  assert_eq "write: empty input" 'env = ["pmsec"]<LF>' "$(field out "$out")" || return 1
  out=$(miserc_write misc "" work)
  assert_eq "write: one inherited name" 'env = ["work", "pmsec"]<LF>' "$(field out "$out")" || return 1
  quiet=$(call_helper -- miserc_env_write_pmsec_text misc 'x = 1' a 2>&1)
  assert_eq "write: prints nothing" "" "$quiet"
}

# `pmsec` is always last and appears exactly once, wherever it came in.
t_miserc_write_pmsec_last_once() {
  local out
  out=$(miserc_write misc "" pmsec work pmsec extra pmsec)
  assert_eq "write: pmsec first/middle/duplicated" 'env = ["work", "extra", "pmsec"]<LF>' "$(field out "$out")" || return 1
  out=$(miserc_write misc "" work)
  assert_eq "write: pmsec appended after the inherited list" 'env = ["work", "pmsec"]<LF>' "$(field out "$out")"
}

t_miserc_write_collapses_multiline() {
  local out
  out=$(miserc_write misc 'env = [
  "work",
  "pmsec",
]
other = 1' work)
  assert_eq "write: multiline array becomes one line" 'env = ["work", "pmsec"]<LF>other = 1' "$(field out "$out")"
}

# Everything outside [START, END) is byte-identical: BOM, CRLF, a missing final
# newline, indentation in front of the key, comments after it.
t_miserc_write_preserves_bytes() {
  local out text bom=$'\xEF\xBB\xBF'
  text="${bom}a = 1"$'\r\n'"env = [\"w\"]  # keep"$'\r\n'"[t]"$'\r\n'"k = 1"$'\r\n'
  out=$(miserc_write misc "$text" w)
  assert_eq "write: BOM, CRLF, trailing comment" \
    "${bom}a = 1<CR><LF>env = [\"w\", \"pmsec\"]  # keep<CR><LF>[t]<CR><LF>k = 1<CR><LF>" \
    "$(field out "$out")" || return 1

  out=$(miserc_write misc 'env = ["a"]
x = 1' a)
  assert_eq "write: no final newline" 'env = ["a", "pmsec"]<LF>x = 1' "$(field out "$out")" || return 1

  out=$(miserc_write misc '  env = ["a"]' a)
  assert_eq "write: indentation stays in front" '  env = ["a", "pmsec"]' "$(field out "$out")"
}

t_miserc_write_inserts_before_first_table() {
  local out
  out=$(miserc_write misc 'key = "v"

[tool]
x = 1' work)
  assert_eq "write: inserted before the first table" 'key = "v"<LF><LF>env = ["work", "pmsec"]<LF>[tool]<LF>x = 1' \
    "$(field out "$out")" || return 1

  out=$(miserc_write misc 'key = "v"' work)
  assert_eq "write: inserted at EOF with a trailing newline" 'key = "v"<LF>env = ["work", "pmsec"]<LF>' \
    "$(field out "$out")" || return 1

  # A header inside a multiline string does not move the insertion point.
  out=$(miserc_write misc 'doc = """
[tool]
"""
[real]' work)
  assert_eq "write: insertion ignores headers inside strings" \
    'doc = """<LF>[tool]<LF>"""<LF>env = ["work", "pmsec"]<LF>[real]' "$(field out "$out")"
}

# Neither the replaced range nor the insertion point may land inside an open
# array or inline table: a nested `[\n[1, 2],\n]` looks like a header at line
# start, and a writer that believed it would splice the new array into it.
t_miserc_write_nested_containers() {
  local out
  out=$(miserc_write misc 'items = [
  [1, 2],
]
env = ["work"]' work)
  assert_eq "write nested: rc" "0" "$(field rc "$out")" || return 1
  assert_eq "write nested: replaces the real assignment only" \
    'items = [<LF>  [1, 2],<LF>]<LF>env = ["work", "pmsec"]' "$(field out "$out")" || return 1

  out=$(miserc_write misc 'items = [
  [1, 2],
]' work)
  assert_eq "write nested: inserted after the closed array" \
    'items = [<LF>  [1, 2],<LF>]<LF>env = ["work", "pmsec"]<LF>' "$(field out "$out")" || return 1

  out=$(miserc_write misc 'items = [
  [1],
]
[tool]
x = 1' work)
  assert_eq "write nested: insertion point is the real header" \
    'items = [<LF>  [1],<LF>]<LF>env = ["work", "pmsec"]<LF>[tool]<LF>x = 1' "$(field out "$out")"
}

# A truncated file that ends inside an array or inline table has no usable EOF
# boundary: the insertion point is the line that opened the outermost still-open
# value, so the new assignment lands ABOVE the broken value instead of becoming
# one more element of it. A header still wins, and a value that closes normally
# leaves the boundary at EOF exactly as before.
t_miserc_write_open_value_at_eof() {
  local out
  out=$(miserc_write misc 'name = "x"
items = [
  1,
')
  assert_eq "write open value: rc" "0" "$(field rc "$out")" || return 1
  assert_eq "write open value: unclosed array after a key" \
    'name = "x"<LF>env = ["pmsec"]<LF>items = [<LF>  1,<LF>' "$(field out "$out")" || return 1

  # Same shape without a preceding key: the file's first line is the boundary,
  # so the assignment goes above it with no blank line invented in front.
  out=$(miserc_write misc 'items = [
  1,
')
  assert_eq "write open value: unclosed array on the first line" \
    'env = ["pmsec"]<LF>items = [<LF>  1,<LF>' "$(field out "$out")" || return 1

  # Inline tables leave the depth open in exactly the same way.
  out=$(miserc_write misc 'name = "x"
x = {
')
  assert_eq "write open value: unclosed inline table after a key" \
    'name = "x"<LF>env = ["pmsec"]<LF>x = {<LF>' "$(field out "$out")" || return 1
  out=$(miserc_write misc 'x = {
')
  assert_eq "write open value: unclosed inline table on the first line" \
    'env = ["pmsec"]<LF>x = {<LF>' "$(field out "$out")" || return 1

  # Only the OUTERMOST opener matters: a nested array still belongs to the line
  # the outer `[` sits on.
  out=$(miserc_write misc 'name = "x"
items = [
  [1,
')
  assert_eq "write open value: nested unclosed array uses the outer line" \
    'name = "x"<LF>env = ["pmsec"]<LF>items = [<LF>  [1,<LF>' "$(field out "$out")" || return 1

  # A closed value earlier in the file must not pin the boundary: the record
  # tracks the value that is still open at EOF.
  out=$(miserc_write misc 'a = [1]
name = "x"
items = [
')
  assert_eq "write open value: a closed value does not move the boundary" \
    'a = [1]<LF>name = "x"<LF>env = ["pmsec"]<LF>items = [<LF>' "$(field out "$out")" || return 1

  # A depth-0 header already ends the root region above any later open value.
  out=$(miserc_write misc '[tool]
x = [
')
  assert_eq "write open value: the first header wins over a later open value" \
    'env = ["pmsec"]<LF>[tool]<LF>x = [<LF>' "$(field out "$out")" || return 1

  # Controls: a value that closes leaves the boundary at EOF, or at the header.
  out=$(miserc_write misc 'items = [
  1,
]')
  assert_eq "write open value: closed array still inserts at EOF" \
    'items = [<LF>  1,<LF>]<LF>env = ["pmsec"]<LF>' "$(field out "$out")" || return 1
  out=$(miserc_write misc 'items = [
  1,
]
[tool]
x = 1')
  assert_eq "write open value: closed array still inserts before the header" \
    'items = [<LF>  1,<LF>]<LF>env = ["pmsec"]<LF>[tool]<LF>x = 1' "$(field out "$out")" || return 1

  # An existing assignment is replaced in place whatever follows it, so a broken
  # value later in the file never moves the spliced range.
  out=$(miserc_write misc 'env = []
items = [
')
  assert_eq "write open value: the existing assignment is still replaced" \
    'env = ["pmsec"]<LF>items = [<LF>' "$(field out "$out")" || return 1

  # Inherited names land in the same spot, byte for byte.
  out=$(miserc_write misc 'name = "x"
items = [
  1,
' work)
  assert_eq "write open value: inherited names use the same boundary" \
    'name = "x"<LF>env = ["work", "pmsec"]<LF>items = [<LF>  1,<LF>' "$(field out "$out")"
}

t_miserc_write_reuses_local_tokens() {
  local out
  out=$(miserc_write misc "env = ['work']" work)
  assert_eq "write: literal token reused" "env = ['work', \"pmsec\"]" "$(field out "$out")" || return 1
  out=$(miserc_write misc 'env = ["work"]' work)
  assert_eq "write: basic token reused" 'env = ["work", "pmsec"]' "$(field out "$out")" || return 1
  out=$(miserc_write misc 'env = ["drop", "work"]' work)
  assert_eq "write: name that is not inherited is dropped" 'env = ["work", "pmsec"]' "$(field out "$out")"
}

t_miserc_write_canonical_quoting() {
  local out
  out=$(miserc_write misc "" 'say "hi"')
  assert_eq "write: double quote forces single quotes" "env = ['say \"hi\"', \"pmsec\"]<LF>" "$(field out "$out")" || return 1
  out=$(miserc_write misc "" 'C:\tmp')
  assert_eq "write: backslash forces single quotes" "env = ['C:\\tmp', \"pmsec\"]<LF>" "$(field out "$out")" || return 1
  out=$(miserc_write misc "" "it's")
  assert_eq "write: lone single quote stays double-quoted" "env = [\"it's\", \"pmsec\"]<LF>" "$(field out "$out")"
}

t_miserc_write_rejects_unrepresentable() {
  local out
  out=$(miserc_write misc "" 'a"b'"'"'c')
  assert_eq "write: both quote kinds (rc)" "1" "$(field rc "$out")" || return 1
  assert_eq "write: both quote kinds (reason)" "env name cannot be represented without escapes" \
    "$(field reason "$out")" || return 1
  assert_eq "write: both quote kinds (no output)" "" "$(field set "$out")" || return 1
  out=$(miserc_write misc "" "a'b\\c")
  assert_eq "write: quote plus backslash (reason)" "env name cannot be represented without escapes" \
    "$(field reason "$out")" || return 1
  out=$(miserc_write misc "" "$(printf 'a\tb')")
  assert_eq "write: control byte (reason)" "env name cannot be represented without escapes" \
    "$(field reason "$out")" || return 1
  assert_eq "write: control byte (no output)" "" "$(field set "$out")" || return 1
  out=$(miserc_write misc "" "$(printf 'a\nb')")
  assert_eq "write: embedded newline (reason)" "env name cannot be represented without escapes" \
    "$(field reason "$out")" || return 1
  assert_eq "write: embedded newline (no output)" "" "$(field set "$out")"
}

# The env key already being a table anywhere in the file means the array and the
# table would collide, so the write fails instead of producing invalid TOML.
t_miserc_write_rejects_conflicts() {
  local out text
  out=$(miserc_write misc '[env]
x = 1')
  assert_eq "write: [env] table (rc)" "1" "$(field rc "$out")" || return 1
  assert_eq "write: [env] table (reason)" "env table conflicts with the env array" "$(field reason "$out")" || return 1
  assert_eq "write: [env] table (no output)" "" "$(field set "$out")" || return 1
  out=$(miserc_write misc '[[env]]
x = 1')
  assert_eq "write: [[env]] table (reason)" "env table conflicts with the env array" "$(field reason "$out")" || return 1
  out=$(miserc_write misc 'env.foo = 1')
  assert_eq "write: dotted env key (reason)" "env table conflicts with the env array" "$(field reason "$out")" || return 1
  out=$(miserc_write misc '[tool]
env.foo = 1')
  assert_eq "write: scoped dotted env key (reason)" "env table conflicts with the env array" "$(field reason "$out")" || return 1

  # Every header spelling whose FIRST decoded segment is `env` names the key the
  # array owns, however it is quoted and however deep the table goes.
  for text in '[ env ]' '["env"]' "['env']" '[ "env" ]' '[env.foo]' '["env".x]' '[env."foo"]'; do
    out=$(miserc_write misc "$text
a = 1")
    assert_eq "write: header $text (rc)" "1" "$(field rc "$out")" || return 1
    assert_eq "write: header $text (reason)" "env table conflicts with the env array" \
      "$(field reason "$out")" || return 1
    assert_eq "write: header $text (no output)" "" "$(field set "$out")" || return 1
  done
  # A dotted root key is the same table written inline, in every spelling.
  for text in 'env.foo = 1' 'env . foo = 1' 'env."foo" = 1' '"env".foo = 1' "'env'.foo = 1"; do
    out=$(miserc_write misc "$text")
    assert_eq "write: key $text (reason)" "env table conflicts with the env array" \
      "$(field reason "$out")" || return 1
  done
  # Not the env key: a deeper table, a longer first segment and an unrelated
  # env-like key all leave the write possible, and the new array goes in front
  # of the first real header.
  out=$(miserc_write misc '[x.env]
a = 1
[envsub]
b = 2
envelope = 1' work)
  assert_eq "write: unrelated env-like keys (rc)" "0" "$(field rc "$out")" || return 1
  assert_eq "write: unrelated env-like keys (insertion)" \
    'env = ["work", "pmsec"]<LF>[x.env]<LF>a = 1<LF>[envsub]<LF>b = 2<LF>envelope = 1' \
    "$(field out "$out")"
}

t_miserc_write_idempotent() {
  local out
  out=$(miserc_twice misc 'note = 1
[tool]' work extra)
  assert_eq "write: second write is identical (rc)" "" "$(field rc "$out")" || return 1
  assert_eq "write: second write is identical" "1" "$(field same "$out")" || return 1
  assert_eq "write: second write output" 'note = 1<LF>env = ["work", "extra", "pmsec"]<LF>[tool]' \
    "$(field second "$out")"
}

# A failed write must not leave the previous write's text in MISEC_ENV_OUTPUT.
t_miserc_write_error_clears_output() {
  local out
  out=$(call_snippet -- '
    miserc_env_write_pmsec_text misc "" work || exit 1
    printf "first=1\n"
    miserc_env_write_pmsec_text misc "env = 1" work
    printf "rc=%s set=%s\n" "$?" "${MISEC_ENV_OUTPUT+1}"
  ')
  assert_eq "write: failure unsets the output" 'first=1
rc=1 set=' "$out"
}

# ---------- mise config layer: selector and local writer ----------
# Same direct-call convention as the helpers above: nothing on stdout, the
# result lives in globals. Every call passes MISE_CONFIG_DIR and
# MISE_SYSTEM_CONFIG_DIR so neither the host's mise config nor the real
# /etc/mise/miserc.toml can leak into an expectation.

MISE_SELECTOR_PROBE=$(cat <<'SNIPPET'
mise_selector_read; rc=$?
printf 'rc=%s\npath=%s\nwired=%s\nerrpath=%s\nerrreason=%s\n' \
  "$rc" "${MISE_SELECTOR_PATH-}" "${MISE_SELECTOR_WIRED-}" \
  "${MISE_ERROR_PATH-}" "${MISE_ERROR_REASON-}"
names=""; sep=""; i=0
while [ "$i" -lt "${#MISE_SELECTOR_ENV[@]}" ]; do
  names="$names$sep${MISE_SELECTOR_ENV[i]}"
  sep='|'
  i=$((i+1))
done
printf 'nenv=%s\nnames=%s\n' "${#MISE_SELECTOR_ENV[@]}" "$names"
SNIPPET
)

MISERC_LOCAL_WRITE_PROBE=$(cat <<'SNIPPET'
miserc_env_write_pmsec; rc=$?
printf 'rc=%s\nerrpath=%s\nerrreason=%s\n' \
  "$rc" "${MISE_ERROR_PATH-}" "${MISE_ERROR_REASON-}"
SNIPPET
)

miserc_selector() { call_snippet "$@" -- "$MISE_SELECTOR_PROBE"; }
miserc_local_write() { call_snippet "$@" -- "$MISERC_LOCAL_WRITE_PROBE"; }

# selector_expect LABEL NAMES WIRED [VAR=val ...]
# The read must succeed and adopt exactly NAMES (`|`-joined, "" for none) with
# the wired flag WIRED.
selector_expect() {
  local label="$1" names="$2" wired="$3"; shift 3
  local out
  out=$(miserc_selector "$@")
  assert_eq "selector[$label]: rc" "0" "$(field rc "$out")" || return 1
  assert_eq "selector[$label]: names" "$names" "$(field names "$out")" || return 1
  assert_eq "selector[$label]: wired" "$wired" "$(field wired "$out")"
}

# write_file PATH CONTENT — `printf '%s'` keeps CONTENT byte-exact, so a test
# can build BOM / CRLF / no-final-newline bodies inline.
write_file() { printf '%s' "$2" > "$1"; }

# count_scratch DIR — backup and atomic-writer scratch files left in DIR. A
# successful first write legitimately leaves one .bak; a failed one leaves none
# and never leaves a mktemp scratch file.
count_scratch() {
  local n=0 f
  for f in "$1"/*.bak "$1"/*.tmp "$1"/*.??????; do
    if [ -e "$f" ]; then n=$((n+1)); fi
  done
  printf '%s' "$n"
}

# assert_same_file LABEL A B — the two files must be byte-identical.
assert_same_file() {
  if cmp -s -- "$2" "$3"; then return 0; fi
  LAST_FAIL="$1
  $(diff -u -- "$2" "$3" 2>&1 | head -20)"
  return 1
}

# rm_tree DIR — restore modes first: a chmod 000 fixture would otherwise make
# the temp tree undeletable for a non-root test user.
rm_tree() {
  chmod -R u+rwx -- "$1" 2>/dev/null || true
  rm -rf -- "$1"
}

# MISE_ENV decides on its own, with mise 2026.11.0 tokenization: commas split,
# empty elements vanish, nothing is trimmed. `wired` is exact and
# case-sensitive, so "Pmsec", " pmsec" and "pmsecx" never count.
t_selector_mise_env_branch() {
  local h d s out
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  selector_expect "duplicates and empty elements" "a|pmsec|b" 1 \
    MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" MISE_ENV="a,,pmsec,b" || return 1
  selector_expect "trailing comma" "a" 0 \
    MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" MISE_ENV="a," || return 1
  selector_expect "only commas" "" 0 \
    MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" MISE_ENV=",," || return 1
  selector_expect "spaces are not trimmed" "a| b" 0 \
    MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" MISE_ENV="a, b" || return 1
  selector_expect "space keeps pmsec inexact" " pmsec" 0 \
    MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" MISE_ENV=" pmsec" || return 1
  selector_expect "case sensitive" "Pmsec" 0 \
    MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" MISE_ENV="Pmsec" || return 1
  selector_expect "prefix is not pmsec" "pmsecx" 0 \
    MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" MISE_ENV="pmsecx" || return 1
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" MISE_ENV="work,pmsec")
  assert_eq "selector[MISE_ENV path]: MISE_ENV" "MISE_ENV" "$(field path "$out")" || return 1
  assert_eq "selector[MISE_ENV path]: wired last" "1" "$(field wired "$out")" || return 1
  assert_eq "selector[MISE_ENV path]: no error path" "" "$(field errpath "$out")" || return 1
  rm_tree "$h"
}

# The MISE_ENV branch must not touch the filesystem at all: a directory (or an
# unreadable file) where the local miserc belongs would fail the file branch
# with "cannot read file", so success here proves nothing was opened.
t_selector_mise_env_no_filesystem() {
  local h d s out
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  mkdir "$d/miserc.local.toml"
  mkdir "$s/miserc.toml"
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" MISE_ENV="work")
  assert_eq "MISE_ENV fs: rc over a directory" "0" "$(field rc "$out")" || return 1
  assert_eq "MISE_ENV fs: path over a directory" "MISE_ENV" "$(field path "$out")" || return 1
  assert_eq "MISE_ENV fs: names over a directory" "work" "$(field names "$out")" || return 1
  assert_eq "MISE_ENV fs: no error reason" "" "$(field errreason "$out")" || return 1
  rmdir "$d/miserc.local.toml" "$s/miserc.toml"
  write_file "$d/miserc.local.toml" 'env = ["x"]'
  chmod 000 "$d/miserc.local.toml"
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" MISE_ENV="pmsec")
  assert_eq "MISE_ENV fs: rc over an unreadable file" "0" "$(field rc "$out")" || return 1
  assert_eq "MISE_ENV fs: wired over an unreadable file" "1" "$(field wired "$out")" || return 1
  rm_tree "$h"
}

# MISE_ENV="" is the settled "unset" spelling, so it falls back to the files.
t_selector_mise_env_empty_falls_back() {
  local h d s out
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  write_file "$d/miserc.local.toml" 'env = ["work"]'
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" MISE_ENV=)
  assert_eq "empty MISE_ENV: path" "$d/miserc.local.toml" "$(field path "$out")" || return 1
  assert_eq "empty MISE_ENV: names" "work" "$(field names "$out")" || return 1
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "unset MISE_ENV: path" "$d/miserc.local.toml" "$(field path "$out")" || return 1
  assert_eq "unset MISE_ENV: names" "work" "$(field names "$out")" || return 1
  rm_tree "$h"
}

# local, then shared, then system; the first definition is adopted whole and
# nothing lower is read. The lower-precedence files carry chmod 000 wherever the
# stop is the point: a fallback would fail the call instead of quietly adopting
# a different list.
t_selector_file_precedence() {
  local h d s out
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  write_file "$s/miserc.toml" 'env = ["system"]'
  chmod 000 "$s/miserc.toml"

  write_file "$d/miserc.local.toml" 'env = ["work", "pmsec"]'
  write_file "$d/miserc.toml" 'env = ["shared"]'
  chmod 000 "$d/miserc.toml"
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "local defines: rc" "0" "$(field rc "$out")" || return 1
  assert_eq "local defines: path" "$d/miserc.local.toml" "$(field path "$out")" || return 1
  assert_eq "local defines: names" "work|pmsec" "$(field names "$out")" || return 1
  assert_eq "local defines: wired" "1" "$(field wired "$out")" || return 1
  assert_eq "local defines: no error" "" "$(field errreason "$out")" || return 1

  rm -f "$d/miserc.local.toml"
  chmod 644 "$d/miserc.toml"
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "shared defines: rc" "0" "$(field rc "$out")" || return 1
  assert_eq "shared defines: path" "$d/miserc.toml" "$(field path "$out")" || return 1
  assert_eq "shared defines: names" "shared" "$(field names "$out")" || return 1
  assert_eq "shared defines: wired" "0" "$(field wired "$out")" || return 1
  assert_eq "shared defines: no error" "" "$(field errreason "$out")" || return 1

  rm -f "$d/miserc.toml"
  chmod 644 "$s/miserc.toml"
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "system defines: rc" "0" "$(field rc "$out")" || return 1
  assert_eq "system defines: path" "$s/miserc.toml" "$(field path "$out")" || return 1
  assert_eq "system defines: names" "system" "$(field names "$out")" || return 1
  rm_tree "$h"
}

# The selector reads through the same scan, so a nested array before the
# assignment must not change which list is adopted or which file is attributed.
t_selector_nested_containers() {
  local h d s out
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  write_file "$d/miserc.local.toml" 'items = [
  [1, 2],
]
env = ["work", "pmsec"]'
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "selector nested: rc" "0" "$(field rc "$out")" || return 1
  assert_eq "selector nested: path" "$d/miserc.local.toml" "$(field path "$out")" || return 1
  assert_eq "selector nested: names" "work|pmsec" "$(field names "$out")" || return 1
  assert_eq "selector nested: wired" "1" "$(field wired "$out")" || return 1
  rm_tree "$h"
}

# The selector reads through the same scan, so a multiline block that closes
# with a run of four quotes must not hide the list it shares the file with.
t_selector_multiline_quote_run() {
  local h d s out
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  write_file "$d/miserc.toml" 'items = ["""foo""""]
env = ["work", "pmsec"]'
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "selector quote-run: rc" "0" "$(field rc "$out")" || return 1
  assert_eq "selector quote-run: path" "$d/miserc.toml" "$(field path "$out")" || return 1
  assert_eq "selector quote-run: names" "work|pmsec" "$(field names "$out")" || return 1
  assert_eq "selector quote-run: wired" "1" "$(field wired "$out")" || return 1
  rm_tree "$h"
}

# `env = []` is a definition: it adopts an empty list and stops the search, so
# a shared list can never reappear under an explicit local reset.
t_selector_empty_array_stops_inheritance() {
  local h d s out
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  write_file "$d/miserc.local.toml" 'env = []'
  write_file "$d/miserc.toml" 'env = ["shared", "pmsec"]'
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "env = []: rc" "0" "$(field rc "$out")" || return 1
  assert_eq "env = []: path" "$d/miserc.local.toml" "$(field path "$out")" || return 1
  assert_eq "env = []: nenv" "0" "$(field nenv "$out")" || return 1
  assert_eq "env = []: wired" "0" "$(field wired "$out")" || return 1
  rm_tree "$h"
}

t_selector_no_definition() {
  local h d s out
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "no definition: rc" "0" "$(field rc "$out")" || return 1
  assert_eq "no definition: path is the local file" "$d/miserc.local.toml" "$(field path "$out")" || return 1
  assert_eq "no definition: nenv" "0" "$(field nenv "$out")" || return 1
  assert_eq "no definition: wired" "0" "$(field wired "$out")" || return 1
  rm_tree "$h"
}

# A local file that cannot be parsed or read fails closed with the parser's own
# reason and path — never a silent skip and never a fallback to shared/system.
t_selector_fails_closed() {
  local h d s out quiet
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  write_file "$d/miserc.toml" 'env = ["shared"]'
  write_file "$d/miserc.local.toml" 'env = "work"'
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "selector parse error: rc" "1" "$(field rc "$out")" || return 1
  assert_eq "selector parse error: reason" "env must be an array" "$(field errreason "$out")" || return 1
  assert_eq "selector parse error: path" "$d/miserc.local.toml" "$(field errpath "$out")" || return 1
  assert_eq "selector parse error: wired" "0" "$(field wired "$out")" || return 1
  quiet=$(call_helper MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" -- mise_selector_read 2>&1)
  assert_eq "selector parse error: silent" "" "$quiet" || return 1

  write_file "$d/miserc.local.toml" 'env = ["work"]'
  chmod 000 "$d/miserc.local.toml"
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "selector read error: rc" "1" "$(field rc "$out")" || return 1
  assert_eq "selector read error: reason" "cannot read file" "$(field errreason "$out")" || return 1
  assert_eq "selector read error: path" "$d/miserc.local.toml" "$(field errpath "$out")" || return 1
  quiet=$(call_helper MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" -- mise_selector_read 2>&1)
  assert_eq "selector read error: silent" "" "$quiet" || return 1

  # A directory in the miserc slot is a read error too, not "absent".
  rm -f "$d/miserc.local.toml"
  mkdir "$d/miserc.local.toml"
  out=$(miserc_selector MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "selector directory: reason" "cannot read file" "$(field errreason "$out")" || return 1
  rm_tree "$h"
}

t_local_write_fresh() {
  local h d s out
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  out=$(miserc_local_write MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "write fresh: rc" "0" "$(field rc "$out")" || return 1
  assert_eq "write fresh: no error" "" "$(field errreason "$out")" || return 1
  assert_file_eq "write fresh: local file bytes" 'env = ["pmsec"]'$'\n' "$d/miserc.local.toml" || return 1
  assert_eq "write fresh: no .bak or scratch" "0" "$(count_scratch "$d")" || return 1
  rm_tree "$h"
}

# The inherited list comes from the first file that defines one, and only the
# local file is ever written. Chmod 000 keeps "the shared/system file was not
# rewritten" honest even for a writer that tried and failed.
t_local_write_inherits_shared() {
  local h d s out expected_shared expected_sys
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  expected_shared='env = ["work", "pmsec", "y"]'$'\n'
  expected_sys='env = ["sys"]'$'\n'
  write_file "$d/miserc.toml" "$expected_shared"
  write_file "$s/miserc.toml" "$expected_sys"
  chmod 000 "$s/miserc.toml"
  out=$(miserc_local_write MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "write shared: rc" "0" "$(field rc "$out")" || return 1
  assert_file_eq "write shared: local inherits minus pmsec plus pmsec" \
    'env = ["work", "y", "pmsec"]'$'\n' "$d/miserc.local.toml" || return 1
  assert_file_eq "write shared: shared unchanged" "$expected_shared" "$d/miserc.toml" || return 1
  rm_tree "$h"
}

t_local_write_inherits_system() {
  local h d s out expected_sys
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  expected_sys='# system
env = ["z"]
'$'\n'
  write_file "$s/miserc.toml" "$expected_sys"
  out=$(miserc_local_write MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "write system: rc" "0" "$(field rc "$out")" || return 1
  assert_file_eq "write system: local inherits the system list" \
    'env = ["z", "pmsec"]'$'\n' "$d/miserc.local.toml" || return 1
  assert_file_eq "write system: system unchanged" "$expected_sys" "$s/miserc.toml" || return 1
  rm_tree "$h"
}

# Replacing an existing assignment keeps the file's local quoting and every
# byte outside the assignment: BOM, CRLF, a trailing comment, a missing final
# newline and unrelated tables.
t_local_write_replaces_assignment() {
  local h d s out original bom=$'\xEF\xBB\xBF'
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  original="${bom}a = 1"$'\r\n'"env = ['work']  # keep"$'\r\n'"[t]"$'\r\n'"k = 1"
  write_file "$d/miserc.local.toml" "$original"
  out=$(miserc_local_write MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "write local: rc" "0" "$(field rc "$out")" || return 1
  assert_file_eq "write local: token reused and bytes preserved" \
    "${bom}a = 1"$'\r\n'"env = ['work', \"pmsec\"]  # keep"$'\r\n'"[t]"$'\r\n'"k = 1" \
    "$d/miserc.local.toml" || return 1
  assert_file_eq "write local: one-shot backup holds the original" "$original" "$d/miserc.local.toml.bak" || return 1

  write_file "$d/miserc.local.toml" 'env = ["work"]'
  out=$(miserc_local_write MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "write local: double-quoted rc" "0" "$(field rc "$out")" || return 1
  assert_file_eq "write local: double-quoted token stays" 'env = ["work", "pmsec"]' "$d/miserc.local.toml" || return 1
  rm_tree "$h"
}

t_local_write_idempotent() {
  local h d s out
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  write_file "$d/miserc.local.toml" 'note = 1
env = ["work"]
[tool]
x = 1
'
  out=$(miserc_local_write MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "write twice: first rc" "0" "$(field rc "$out")" || return 1
  cp -- "$d/miserc.local.toml" "$h/first"
  cp -- "$d/miserc.local.toml.bak" "$h/first-bak"
  out=$(miserc_local_write MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "write twice: second rc" "0" "$(field rc "$out")" || return 1
  assert_same_file "write twice: bytes unchanged" "$h/first" "$d/miserc.local.toml" || return 1
  assert_same_file "write twice: existing .bak preserved" "$h/first-bak" "$d/miserc.local.toml.bak" || return 1
  assert_file_eq "write twice: first write shape" 'note = 1
env = ["work", "pmsec"]
[tool]
x = 1
' "$d/miserc.local.toml" || return 1
  rm_tree "$h"
}

# The writer inherits the file-based list only: a one-off MISE_ENV in the
# invoking shell must never reach the local file.
t_local_write_ignores_mise_env() {
  local h d s out
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  out=$(miserc_local_write MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" MISE_ENV="a,b")
  assert_eq "write ignores MISE_ENV: rc" "0" "$(field rc "$out")" || return 1
  assert_file_eq "write ignores MISE_ENV: no definition" 'env = ["pmsec"]'$'\n' "$d/miserc.local.toml" || return 1
  rm -f "$d/miserc.local.toml"
  write_file "$d/miserc.toml" 'env = ["y"]'
  out=$(miserc_local_write MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s" MISE_ENV="a,b")
  assert_eq "write ignores MISE_ENV: shared rc" "0" "$(field rc "$out")" || return 1
  assert_file_eq "write ignores MISE_ENV: shared list wins" 'env = ["y", "pmsec"]'$'\n' "$d/miserc.local.toml" || return 1
  rm_tree "$h"
}

t_local_write_local_empty_array() {
  local h d s out
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  write_file "$d/miserc.local.toml" 'env = []'
  write_file "$d/miserc.toml" 'env = ["shared"]'
  out=$(miserc_local_write MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "write local []: rc" "0" "$(field rc "$out")" || return 1
  # The fixture has no final newline (write_file writes none) and the writer
  # keeps it that way, so the expectation must not invent one either.
  assert_file_eq "write local []: becomes pmsec only" 'env = ["pmsec"]' "$d/miserc.local.toml" || return 1
  rm_tree "$h"
}

# Every failure mode must leave the target, its .bak and any scratch file
# exactly as they were: nothing is written before all reads and the plan have
# succeeded.
t_local_write_failure_leaves_target_untouched() {
  local h d s out original
  h=$(setup_home); d="$h/mise"; s="$h/sys"
  mkdir -p "$d" "$s"
  # The target must stay writable-looking but free of a top-level env, so the
  # scan really reaches the broken shared file instead of stopping at local.
  original='# keep me
x = 1
'
  write_file "$d/miserc.local.toml" "$original"

  write_file "$d/miserc.toml" 'env = "work"'
  out=$(miserc_local_write MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "write fail parse: rc" "1" "$(field rc "$out")" || return 1
  assert_eq "write fail parse: reason" "env must be an array" "$(field errreason "$out")" || return 1
  assert_eq "write fail parse: path" "$d/miserc.toml" "$(field errpath "$out")" || return 1
  assert_file_eq "write fail parse: local untouched" "$original" "$d/miserc.local.toml" || return 1
  assert_eq "write fail parse: no .bak or scratch" "0" "$(count_scratch "$d")" || return 1

  # Local collision: with no lower file left to fail on, planning against the
  # target itself must be what rejects the write.
  rm -f "$d/miserc.toml"
  write_file "$d/miserc.local.toml" '[env]
x = 1
'
  out=$(miserc_local_write MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "write fail conflict: rc" "1" "$(field rc "$out")" || return 1
  assert_eq "write fail conflict: reason" "env table conflicts with the env array" \
    "$(field errreason "$out")" || return 1
  assert_eq "write fail conflict: path" "$d/miserc.local.toml" "$(field errpath "$out")" || return 1
  assert_file_eq "write fail conflict: local untouched" '[env]
x = 1
' "$d/miserc.local.toml" || return 1
  assert_eq "write fail conflict: no .bak or scratch" "0" "$(count_scratch "$d")" || return 1

  write_file "$d/miserc.local.toml" "$original"
  write_file "$d/miserc.toml" 'env = ["a"]'
  chmod 000 "$d/miserc.toml"
  out=$(miserc_local_write MISE_CONFIG_DIR="$d" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "write fail unreadable: rc" "1" "$(field rc "$out")" || return 1
  assert_eq "write fail unreadable: reason" "cannot read file" "$(field errreason "$out")" || return 1
  assert_eq "write fail unreadable: path" "$d/miserc.toml" "$(field errpath "$out")" || return 1
  assert_file_eq "write fail unreadable: local untouched" "$original" "$d/miserc.local.toml" || return 1
  assert_eq "write fail unreadable: no .bak or scratch" "0" "$(count_scratch "$d")" || return 1
  rm_tree "$h"
}

# write_atomic creates missing parent directories, so the only thing keeping a
# rejected run from leaving an empty tree behind is that validation happens
# before the write.
t_local_write_failure_creates_no_directory() {
  local h s root out
  h=$(setup_home); s="$h/sys"; root="$h/missing/deep"
  mkdir -p "$s"
  write_file "$s/miserc.toml" 'env = "work"'
  out=$(miserc_local_write MISE_CONFIG_DIR="$root" MISE_SYSTEM_CONFIG_DIR="$s")
  assert_eq "write no dir: rc" "1" "$(field rc "$out")" || return 1
  assert_eq "write no dir: reason" "env must be an array" "$(field errreason "$out")" || return 1
  if [ -e "$h/missing" ]; then
    LAST_FAIL="a rejected write created $h/missing"
    rm_tree "$h"
    return 1
  fi
  rm_tree "$h"
}

T "sourcing bash/pmsec defines helpers without running main" t_source_guard_defines_without_running_main
T "legacy path_mise resolver is unchanged" t_path_mise_legacy_untouched
T "path_mise_dir override precedence" t_path_mise_dir_overrides
T "derived mise config paths follow path_mise_dir" t_path_mise_derived_family
T "system miserc resolution (override / POSIX / win32 drive root)" t_path_mise_system_miserc
T "mise_supports_new_mode version x override matrix" t_mise_supports_new_mode_matrix
T "miserc parse: no top-level env reads as not defined" t_miserc_parse_absent
T "miserc parse: accepted array shapes and tokens" t_miserc_parse_shapes
T "miserc parse: START/END byte offsets splice back exactly" t_miserc_parse_splice_offsets
T "miserc parse: strings and comments stay opaque" t_miserc_parse_ignores_strings_and_comments
T "miserc parse: nested arrays and inline tables stay opaque" t_miserc_parse_nested_containers
T "miserc parse: escaped triple quotes in a basic string" t_miserc_parse_multiline_escape_closer
T "miserc parse: a closing run of four or more quotes" t_miserc_parse_multiline_quote_run
T "miserc parse: one-line strings end with their line" t_miserc_parse_line_terminated_strings
T "miserc parse: quoted env key rejected" t_miserc_parse_reject_quoted_key
T "miserc parse: duplicate top-level env rejected" t_miserc_parse_reject_duplicate
T "miserc parse: non-array env rejected" t_miserc_parse_reject_not_array
T "miserc parse: non-string array elements rejected" t_miserc_parse_reject_element_forms
T "miserc parse: escapes and multiline elements rejected" t_miserc_parse_reject_escapes_and_multiline_elements
T "miserc parse: unterminated assignments rejected" t_miserc_parse_reject_unterminated
T "miserc parse: malformed env key rejected" t_miserc_parse_reject_malformed_key
T "miserc parse: comments and newlines before the equals sign" t_miserc_parse_trivia_before_equals
T "miserc parse: bare env at EOF rejected" t_miserc_parse_bare_env_at_eof
T "miserc parse: malformed array separators rejected" t_miserc_parse_reject_separators
T "miserc parse: trailing junk after the array rejected" t_miserc_parse_reject_trailing_junk
T "miserc parse: unterminated unrelated string rejected" t_miserc_parse_reject_unterminated_file_string
T "miserc error text shape" t_miserc_error_text_shape
T "miserc write: fresh file and inherited names" t_miserc_write_fresh
T "miserc write: pmsec last and once" t_miserc_write_pmsec_last_once
T "miserc write: multiline array collapsed" t_miserc_write_collapses_multiline
T "miserc write: a closing quote run keeps the assignment replaceable" t_miserc_write_multiline_quote_run
T "miserc write: surrounding bytes preserved" t_miserc_write_preserves_bytes
T "miserc write: absent assignment inserted before the first table" t_miserc_write_inserts_before_first_table
T "miserc write: nested containers never capture the new array" t_miserc_write_nested_containers
T "miserc write: a value open at EOF inserts above its opening line" t_miserc_write_open_value_at_eof
T "miserc write: existing tokens reused" t_miserc_write_reuses_local_tokens
T "miserc write: canonical quoting for new names" t_miserc_write_canonical_quoting
T "miserc write: unrepresentable names fail closed" t_miserc_write_rejects_unrepresentable
T "miserc write: env table conflicts rejected" t_miserc_write_rejects_conflicts
T "miserc write: idempotent" t_miserc_write_idempotent
T "miserc write: failure leaves no output" t_miserc_write_error_clears_output
T "selector: MISE_ENV tokenization and exact membership" t_selector_mise_env_branch
T "selector: MISE_ENV branch never touches the filesystem" t_selector_mise_env_no_filesystem
T "selector: empty and unset MISE_ENV fall back to files" t_selector_mise_env_empty_falls_back
T "selector: local / shared / system precedence" t_selector_file_precedence
T "selector: nested containers do not change the adopted list" t_selector_nested_containers
T "selector: a closing quote run does not hide the adopted list" t_selector_multiline_quote_run
T "selector: env = [] stops inheritance" t_selector_empty_array_stops_inheritance
T "selector: no definition attributes the local path" t_selector_no_definition
T "selector: parse and read errors fail closed" t_selector_fails_closed
T "local write: fresh file" t_local_write_fresh
T "local write: inherits a shared list, writes local only" t_local_write_inherits_shared
T "local write: inherits a system list" t_local_write_inherits_system
T "local write: replaces the assignment, surrounding bytes kept" t_local_write_replaces_assignment
T "local write: idempotent with the .bak preserved" t_local_write_idempotent
T "local write: MISE_ENV never feeds inheritance" t_local_write_ignores_mise_env
T "local write: local env = [] becomes [pmsec]" t_local_write_local_empty_array
T "local write: failures leave the target untouched" t_local_write_failure_leaves_target_untouched
T "local write: a rejected write creates no directory" t_local_write_failure_creates_no_directory

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
