#!/usr/bin/env pwsh
# Mirrors node/test/cli.test.mjs and bash/test/test.sh — runs pmsec.ps1
# under a fresh $HOME and diffs the on-disk shape against the same bytes
# the other suites verify.
$ErrorActionPreference = 'Stop'
$Here  = Split-Path -Parent $MyInvocation.MyCommand.Path
function _PathJoinBootstrap {
  if ($args.Count -eq 0) { return '' }
  $r = $args[0]
  for ($i = 1; $i -lt $args.Count; $i++) {
    foreach ($p in ($args[$i] -split '[\\/]')) { if ($p -ne '') { $r = Join-Path $r $p } }
  }
  return $r
}
$Pmsec = (Resolve-Path (_PathJoinBootstrap $Here '..' 'pmsec.ps1')).Path
$IntuneScript = (Resolve-Path (_PathJoinBootstrap $Here '..' 'intune-platform-script.ps1')).Path
$PwshExe = if ($IsWindows) {
  (Get-Process -Id $PID).Path
} else {
  (Get-Process -Id $PID).Path
}

$script:Pass = 0
$script:Fail = 0
$script:LastFail = ''

function PathJoin {
  if ($args.Count -eq 0) { return '' }
  $result = $args[0]
  for ($i = 1; $i -lt $args.Count; $i++) {
    foreach ($p in ($args[$i] -split '[\\/]')) {
      if ($p -ne '') { $result = Join-Path $result $p }
    }
  }
  return $result
}

function NewHome {
  $d = PathJoin ([System.IO.Path]::GetTempPath()) ('pmsec-ps-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  [void](New-Item -ItemType Directory -Path $d -Force)
  return $d
}

function InvokePmsec([string]$HomeDir, [hashtable]$Extra, [string[]]$Argv) {
  $envKeys = @(
    'NPM_CONFIG_USERCONFIG','UV_CONFIG_FILE','BUN_CONFIG_FILE',
    'PMSEC_PNPM_CONFIG_FILE','PMSEC_PNPM_CONFIG_YAML',
    'YARN_RC_FILENAME','CARGO_HOME','MISE_GLOBAL_CONFIG_FILE',
    'AUBE_CONFIG_FILE','COMPOSER_HOME',
    'BUNDLE_USER_CONFIG','BUNDLE_USER_HOME',
    'APPDATA','LOCALAPPDATA','XDG_CONFIG_HOME',
    'PMSEC_HOME','HOME','USERPROFILE','PMSEC_FAKE_SCOPES','PMSEC_NO_WSL',
    'PMSEC_NPM_VERSION','PMSEC_PNPM_VERSION','PMSEC_YARN_VERSION',
    'PMSEC_BUN_VERSION','PMSEC_CARGO_VERSION','PMSEC_MISE_VERSION','PMSEC_UV_VERSION',
    'PMSEC_AUBE_VERSION',
    'PMSEC_BUNDLER_VERSION','PMSEC_COMPOSER_VERSION',
    'MISE_CONFIG_DIR','MISE_SYSTEM_CONFIG_DIR','MISE_ENV','WSLENV'
  )
  $saved = @{}
  foreach ($k in $envKeys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
    [Environment]::SetEnvironmentVariable($k, $null, 'Process')
  }
  # Default scope = a single Linux scope rooted at $HomeDir. This stands in
  # for "one WSL distro" and reproduces the original behaviour of every
  # tool dropping its config under $HomeDir/... Tests can override via
  # $Extra.PMSEC_FAKE_SCOPES (e.g. for win32 APPDATA paths or multi-scope).
  [Environment]::SetEnvironmentVariable('PMSEC_FAKE_SCOPES', "test|$HomeDir|linux", 'Process')
  # Hide all tool binaries so preflight warnings and version-aware behaviour
  # (e.g. pnpm 11 block-exotic-subdeps default-enforcement) don't depend on
  # what's installed on the test machine.  Tests that exercise version-specific
  # behaviour pass an explicit override via $Extra.
  # Not setting these caused VersionDetect to spawn real binaries (npm --version
  # etc.) when a win32 scope was active in multi-scope tests, which hangs under
  # Windows PowerShell 5.1 on certain CI runners.
  [Environment]::SetEnvironmentVariable('PMSEC_NPM_VERSION',     'none', 'Process')
  [Environment]::SetEnvironmentVariable('PMSEC_PNPM_VERSION',    'none', 'Process')
  [Environment]::SetEnvironmentVariable('PMSEC_YARN_VERSION',    'none', 'Process')
  [Environment]::SetEnvironmentVariable('PMSEC_BUN_VERSION',     'none', 'Process')
  [Environment]::SetEnvironmentVariable('PMSEC_CARGO_VERSION',   'none', 'Process')
  [Environment]::SetEnvironmentVariable('PMSEC_MISE_VERSION',    'none', 'Process')
  [Environment]::SetEnvironmentVariable('PMSEC_UV_VERSION',      'none', 'Process')
  [Environment]::SetEnvironmentVariable('PMSEC_AUBE_VERSION',    'none', 'Process')
  [Environment]::SetEnvironmentVariable('PMSEC_BUNDLER_VERSION', 'none', 'Process')
  [Environment]::SetEnvironmentVariable('PMSEC_COMPOSER_VERSION', 'none', 'Process')
  if ($Extra) {
    foreach ($k in $Extra.Keys) {
      [Environment]::SetEnvironmentVariable($k, $Extra[$k], 'Process')
    }
  }
  $errFile = [System.IO.Path]::GetTempFileName()
  $oldEAP = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $stdout = (& $PwshExe -NoProfile -File $Pmsec @Argv 2>$errFile | Out-String)
    $code = $LASTEXITCODE
    $stderr = [System.IO.File]::ReadAllText($errFile)
  } finally {
    $ErrorActionPreference = $oldEAP
    Remove-Item -Force -LiteralPath $errFile -ErrorAction Ignore
    foreach ($k in $envKeys) {
      [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process')
    }
  }
  return @{ Code = $code; Out = $stdout; Err = $stderr }
}

function AssertFileEq([string]$Label, [string]$Expected, [string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    $script:LastFail = "$Label`n  file missing: $Path"
    return $false
  }
  $actual = [System.IO.File]::ReadAllText($Path)
  if ($actual -eq $Expected) { return $true }
  $script:LastFail = "$Label`n  expected: $($Expected | ConvertTo-Json)`n  actual:   $($actual | ConvertTo-Json)"
  return $false
}

function AssertMatch([string]$Label, [string]$Pattern, [string]$Haystack) {
  if ($Haystack -match $Pattern) { return $true }
  $script:LastFail = "$Label`n  pattern: $Pattern`n  body:    $($Haystack.Substring(0, [Math]::Min(400, $Haystack.Length)))"
  return $false
}

function T([string]$Name, [scriptblock]$Body) {
  try {
    if (& $Body) {
      $script:Pass++
      Write-Host "PASS  $Name"
    } else {
      $script:Fail++
      Write-Host "FAIL  $Name"
      Write-Host $script:LastFail
    }
  } catch {
    $script:Fail++
    Write-Host "FAIL  $Name (exception)"
    Write-Host $_.ToString()
  }
}

# ---------- tests ----------

T 'Intune Platform Script is upload-ready and registers the daily task internally' {
  $tokens = $null
  $parseErrors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile(
    $IntuneScript, [ref]$tokens, [ref]$parseErrors
  )
  if ($parseErrors.Count -gt 0) {
    $script:LastFail = "Intune script parse errors: $($parseErrors -join '; ')"
    return $false
  }
  $source = [System.IO.File]::ReadAllText($IntuneScript)
  if ($source -notmatch 'Register-ScheduledTask' -or
      $source -notmatch '(?m)-File \$installPath\s*$' -or
      $source -notmatch "\`$pmsecCommit\s*=\s*'[0-9a-f]{40}'" -or
      $source -match 'raw\.githubusercontent\.com/[^/]+/[^/]+/main/' -or
      $source -match '--install-daily-task') {
    $script:LastFail = 'Intune script must pin pmsec, register the task, and invoke plain pmsec internally'
    return $false
  }
  return $true
}

# Catches a class of formatting bug where the human-readable output
# leaks unresolved placeholders ({N}) because of operator-precedence
# mistakes between string concatenation and -f. Walks every code path
# that emits a formatted line.
T 'human output never leaks unresolved placeholders' {
  $scenarios = @(
    @{ name='enable';     setup={};                                                              args=@('--tool','npm','--days','7') },
    @{ name='keep';       setup={ param($h) [System.IO.File]::WriteAllText((Join-Path $h '.npmrc'), "min-release-age=99`n") }; args=@('--tool','npm') },
    @{ name='upgrade';    setup={ param($h) [System.IO.File]::WriteAllText((Join-Path $h '.npmrc'), "min-release-age=3`n") };  args=@('--tool','npm','--days','7') },
    @{ name='check_fail'; setup={};                                                              args=@('--check') },
    @{ name='check_pass'; setup={ param($h) [void](InvokePmsec $h $null @()) };                  args=@('--check') },
    @{ name='disable';    setup={ param($h) [void](InvokePmsec $h $null @('--tool','npm')) };    args=@('--disable','--tool','npm') }
  )
  foreach ($s in $scenarios) {
    $h = NewHome
    try {
      & $s.setup $h
      $r = InvokePmsec $h $null $s.args
      $combined = [string]$r.Out + [string]$r.Err
      if ($combined -match '\{[0-9]+\}') {
        $script:LastFail = "scenario=$($s.name) leaked placeholder. output: $combined"
        return $false
      }
    } finally { Remove-Item -Recurse -Force -LiteralPath $h }
  }
  return $true
}

T 'enable writes the bundle for every tool' {
  $h = NewHome
  try {
    $r = InvokePmsec $h $null @()
    if ($r.Code -ne 0) { $script:LastFail = "exit code $($r.Code)`n$($r.Out)"; return $false }
    $pnpmrcPath = PathJoin $h '.config' 'pnpm' 'rc'
    $pnmyamlPath = PathJoin $h '.config' 'pnpm' 'config.yaml'
    $ok = $true
    $ok = $ok -and (AssertMatch 'npm key' '(?m)^min-release-age=1$' ([System.IO.File]::ReadAllText((Join-Path $h '.npmrc'))))
    $ok = $ok -and (AssertMatch 'pnpm key' '(?m)^minimum-release-age=1440$' ([System.IO.File]::ReadAllText($pnpmrcPath)))
    if (([System.IO.File]::ReadAllText((Join-Path $h '.npmrc'))) -match 'minimum-release-age') {
      $script:LastFail = 'pnpm key leaked into .npmrc'; return $false
    }
    $ok = $ok -and (AssertMatch 'bun section' '(?m)^\[install\]$' ([System.IO.File]::ReadAllText((Join-Path $h '.bunfig.toml'))))
    $ok = $ok -and (AssertMatch 'bun key' '(?m)^minimumReleaseAge = 86400$' ([System.IO.File]::ReadAllText((Join-Path $h '.bunfig.toml'))))
    $ok = $ok -and (AssertMatch 'bun ignoreScripts extra' '(?m)^ignoreScripts = true$' ([System.IO.File]::ReadAllText((Join-Path $h '.bunfig.toml'))))
    $ok = $ok -and (AssertMatch 'yarn key' '(?m)^npmMinimalAgeGate: 1440$' ([System.IO.File]::ReadAllText((Join-Path $h '.yarnrc.yml'))))
    $ok = $ok -and (AssertMatch 'uv key' '(?m)^exclude-newer = "1 days"$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'uv' 'uv.toml'))))
    $ok = $ok -and (AssertMatch 'uv index-strategy extra' '(?m)^index-strategy = "first-index"$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'uv' 'uv.toml'))))
    $ok = $ok -and (AssertMatch 'uv audit section' '(?m)^\[audit\]$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'uv' 'uv.toml'))))
    $ok = $ok -and (AssertMatch 'uv malware-check extra' '(?m)^malware-check = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'uv' 'uv.toml'))))
    $ok = $ok -and (AssertMatch 'mise section' '(?m)^\[settings\]$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise key' '(?m)^minimum_release_age = "1d"$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise paranoid extra' '(?m)^paranoid = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise gpg_verify extra' '(?m)^gpg_verify = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise github_attestations extra' '(?m)^github_attestations = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise slsa extra' '(?m)^slsa = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise locked_verify_provenance extra' '(?m)^locked_verify_provenance = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise provenance_api_failures_fatal extra' '(?m)^provenance_api_failures_fatal = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise aqua.github_attestations extra' '(?m)^aqua\.github_attestations = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise aqua.cosign extra' '(?m)^aqua\.cosign = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise aqua.minisign extra' '(?m)^aqua\.minisign = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise aqua.slsa extra' '(?m)^aqua\.slsa = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise github.github_attestations extra' '(?m)^github\.github_attestations = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise github.slsa extra' '(?m)^github\.slsa = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise node.gpg_verify extra' '(?m)^node\.gpg_verify = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise swift.gpg_verify extra' '(?m)^swift\.gpg_verify = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'mise not_found_system_fallback extra' '(?m)^not_found_system_fallback = false$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'mise' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'aube key' '(?m)^minimumReleaseAge = 1440$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'aube' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'aube paranoid extra' '(?m)^paranoid = true$' ([System.IO.File]::ReadAllText((PathJoin $h '.config' 'aube' 'config.toml'))))
    $ok = $ok -and (AssertMatch 'npm audit-level extra' '(?m)^audit-level=high$' ([System.IO.File]::ReadAllText((Join-Path $h '.npmrc'))))
    $ok = $ok -and (AssertMatch 'npm allow-git extra' '(?m)^allow-git=none$' ([System.IO.File]::ReadAllText((Join-Path $h '.npmrc'))))
    $ok = $ok -and (AssertMatch 'npm allow-remote extra' '(?m)^allow-remote=none$' ([System.IO.File]::ReadAllText((Join-Path $h '.npmrc'))))
    $ok = $ok -and (AssertMatch 'npm allow-file extra' '(?m)^allow-file=root$' ([System.IO.File]::ReadAllText((Join-Path $h '.npmrc'))))
    $ok = $ok -and (AssertMatch 'npm allow-directory extra' '(?m)^allow-directory=root$' ([System.IO.File]::ReadAllText((Join-Path $h '.npmrc'))))
    $ok = $ok -and (AssertMatch 'npm strict-allow-scripts extra' '(?m)^strict-allow-scripts=true$' ([System.IO.File]::ReadAllText((Join-Path $h '.npmrc'))))
    $ok = $ok -and (AssertMatch 'npm dangerously-allow-all-scripts extra' '(?m)^dangerously-allow-all-scripts=false$' ([System.IO.File]::ReadAllText((Join-Path $h '.npmrc'))))
    $ok = $ok -and (AssertMatch 'npm allow-scripts-pin extra' '(?m)^allow-scripts-pin=true$' ([System.IO.File]::ReadAllText((Join-Path $h '.npmrc'))))
    $ok = $ok -and (AssertMatch 'npm ignore-extension extra' '(?m)^ignore-extension=true$' ([System.IO.File]::ReadAllText((Join-Path $h '.npmrc'))))
    $ok = $ok -and (AssertMatch 'pnpm trust-policy extra' '(?m)^trust-policy=no-downgrade$' ([System.IO.File]::ReadAllText($pnpmrcPath)))
    $ok = $ok -and (AssertMatch 'pnpm block-exotic-subdeps extra' '(?m)^block-exotic-subdeps=true$' ([System.IO.File]::ReadAllText($pnpmrcPath)))
    $ok = $ok -and (AssertMatch 'pnpm strict-dep-builds extra' '(?m)^strict-dep-builds=true$' ([System.IO.File]::ReadAllText($pnpmrcPath)))
    $ok = $ok -and (AssertMatch 'pnpm verify-deps-before-run extra' '(?m)^verify-deps-before-run=error$' ([System.IO.File]::ReadAllText($pnpmrcPath)))
    $ok = $ok -and (AssertMatch 'pnpm minimum-release-age-strict extra' '(?m)^minimum-release-age-strict=true$' ([System.IO.File]::ReadAllText($pnpmrcPath)))
    $ok = $ok -and (AssertMatch 'pnpm dangerously-allow-all-builds extra' '(?m)^dangerously-allow-all-builds=false$' ([System.IO.File]::ReadAllText($pnpmrcPath)))
    $ok = $ok -and (AssertMatch 'pnpm trust-lockfile extra' '(?m)^trust-lockfile=false$' ([System.IO.File]::ReadAllText($pnpmrcPath)))
    $ok = $ok -and (AssertMatch 'pnpm minimum-release-age-ignore-missing-time extra' '(?m)^minimum-release-age-ignore-missing-time=false$' ([System.IO.File]::ReadAllText($pnpmrcPath)))
    $ok = $ok -and (AssertMatch 'pnpm yaml cooldown' '(?m)^minimumReleaseAge: 1440$' ([System.IO.File]::ReadAllText($pnmyamlPath)))
    $ok = $ok -and (AssertMatch 'pnpm yaml trustPolicy' '(?m)^trustPolicy: no-downgrade$' ([System.IO.File]::ReadAllText($pnmyamlPath)))
    $ok = $ok -and (AssertMatch 'pnpm yaml blockExoticSubdeps' '(?m)^blockExoticSubdeps: true$' ([System.IO.File]::ReadAllText($pnmyamlPath)))
    $ok = $ok -and (AssertMatch 'pnpm yaml strictDepBuilds' '(?m)^strictDepBuilds: true$' ([System.IO.File]::ReadAllText($pnmyamlPath)))
    $ok = $ok -and (AssertMatch 'pnpm yaml verifyDepsBeforeRun' '(?m)^verifyDepsBeforeRun: error$' ([System.IO.File]::ReadAllText($pnmyamlPath)))
    $ok = $ok -and (AssertMatch 'pnpm yaml minimumReleaseAgeStrict' '(?m)^minimumReleaseAgeStrict: true$' ([System.IO.File]::ReadAllText($pnmyamlPath)))
    $ok = $ok -and (AssertMatch 'pnpm yaml dangerouslyAllowAllBuilds' '(?m)^dangerouslyAllowAllBuilds: false$' ([System.IO.File]::ReadAllText($pnmyamlPath)))
    $ok = $ok -and (AssertMatch 'pnpm yaml trustLockfile' '(?m)^trustLockfile: false$' ([System.IO.File]::ReadAllText($pnmyamlPath)))
    $ok = $ok -and (AssertMatch 'pnpm yaml minimumReleaseAgeIgnoreMissingTime' '(?m)^minimumReleaseAgeIgnoreMissingTime: false$' ([System.IO.File]::ReadAllText($pnmyamlPath)))
    $ok = $ok -and (AssertMatch 'yarn enableHardenedMode extra' '(?m)^enableHardenedMode: true$' ([System.IO.File]::ReadAllText((Join-Path $h '.yarnrc.yml'))))
    $ok = $ok -and (AssertMatch 'yarn enableScripts extra' '(?m)^enableScripts: false$' ([System.IO.File]::ReadAllText((Join-Path $h '.yarnrc.yml'))))
    $ok = $ok -and (AssertMatch 'bundler key' '(?m)^BUNDLE_COOLDOWN: "1"$' ([System.IO.File]::ReadAllText((PathJoin $h '.bundle' 'config'))))
    $composer = [System.IO.File]::ReadAllText((PathJoin $h '.config' 'composer' 'config.json'))
    $ok = $ok -and (AssertMatch 'composer cooldown' '"period": "1 days"' $composer)
    $ok = $ok -and (AssertMatch 'composer allow-plugins' '"allow-plugins": false' $composer)
    $ok = $ok -and (AssertMatch 'composer secure-http' '"secure-http": true' $composer)
    $ok = $ok -and (AssertMatch 'composer disable-tls' '"disable-tls": false' $composer)
    $ok = $ok -and (AssertMatch 'composer abandoned' '"abandoned": "fail"' $composer)
    return $ok
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'check passes after enable across all tools' {
  $h = NewHome
  try {
    [void](InvokePmsec $h $null @())
    $r = InvokePmsec $h $null @('--check')
    if ($r.Code -ne 0) { $script:LastFail = "exit $($r.Code)`n$($r.Out)" }
    return $r.Code -eq 0
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'check fails when bundle missing' {
  $h = NewHome
  try {
    $r = InvokePmsec $h $null @('--check')
    if ($r.Code -ne 1) { $script:LastFail = "expected exit 1, got $($r.Code)`n$($r.Out)"; return $false }
    foreach ($t in 'npm','pnpm','yarn','bun','cargo','mise','uv','bundler','aube','composer') {
      if (-not (AssertMatch "MISSING $t" "MISSING $t" $r.Out)) { return $false }
    }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'disable preserves unrelated keys per file' {
  $h = NewHome
  try {
    [System.IO.File]::WriteAllText((Join-Path $h '.npmrc'), "registry=https://r/`nmin-release-age=3`n")
    [void](New-Item -ItemType Directory -Force -Path (PathJoin $h '.config' 'pnpm'))
    [System.IO.File]::WriteAllText((PathJoin $h '.config' 'pnpm' 'rc'), "minimum-release-age=4320`nstore-dir=/tmp/pstore`n")
    [System.IO.File]::WriteAllText((PathJoin $h '.config' 'pnpm' 'config.yaml'), "minimumReleaseAge: 4320`nstoreDir: /tmp/pstore`n")
    [void](New-Item -ItemType Directory -Force -Path (PathJoin $h '.config' 'uv'))
    [System.IO.File]::WriteAllText((PathJoin $h '.config' 'uv' 'uv.toml'), "exclude-newer = ""3 days""`nlink-mode = ""copy""`n")
    [System.IO.File]::WriteAllText((Join-Path $h '.bunfig.toml'), "[install]`nminimumReleaseAge = 259200`nregistry = ""https://x/""`n")
    [System.IO.File]::WriteAllText((Join-Path $h '.yarnrc.yml'), "npmMinimalAgeGate: ""3d""`nnpmRegistryServer: ""https://r/""`n")
    [void](InvokePmsec $h $null @('--disable'))
    $ok = $true
    $ok = $ok -and (AssertFileEq '.npmrc'    "registry=https://r/`n"                                  (Join-Path $h '.npmrc'))
    $ok = $ok -and (AssertFileEq 'pnpm rc'   "store-dir=/tmp/pstore`n"                                (PathJoin $h '.config' 'pnpm' 'rc'))
    $ok = $ok -and (AssertFileEq 'pnpm config.yaml' "storeDir: /tmp/pstore`n"                         (PathJoin $h '.config' 'pnpm' 'config.yaml'))
    $ok = $ok -and (AssertFileEq 'uv.toml'   "link-mode = ""copy""`n"                                 (PathJoin $h '.config' 'uv' 'uv.toml'))
    $ok = $ok -and (AssertFileEq '.bunfig'   "[install]`nregistry = ""https://x/""`n"                 (Join-Path $h '.bunfig.toml'))
    $ok = $ok -and (AssertFileEq '.yarnrc'   "npmRegistryServer: ""https://r/""`n"                    (Join-Path $h '.yarnrc.yml'))
    return $ok
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'enable upgrades values that are weaker than the request' {
  $h = NewHome
  try {
    [System.IO.File]::WriteAllText((Join-Path $h '.npmrc'), "min-release-age=3`nregistry=https://r/`n")
    [void](InvokePmsec $h $null @('--tool','npm','--days','7'))
    return (AssertFileEq '.npmrc' "min-release-age=7`nregistry=https://r/`naudit-level=high`nallow-git=none`nallow-remote=none`nallow-file=root`nallow-directory=root`nstrict-allow-scripts=true`ndangerously-allow-all-scripts=false`nallow-scripts-pin=true`nignore-extension=true`n" (Join-Path $h '.npmrc'))
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'enable preserves stricter existing cooldowns' {
  $h = NewHome
  try {
    [System.IO.File]::WriteAllText((Join-Path $h '.npmrc'), "min-release-age=99`nregistry=https://r/`n")
    $r = InvokePmsec $h $null @('--tool','npm')
    if ($r.Out -notmatch '(?m)^keep\s+npm\s+\[[^\]]+\]\s+\(kept existing 99d \S+ \d+d\)\s*$') { $script:LastFail = "expected fully-formatted keep line, got: $($r.Out)"; return $false }
    return (AssertFileEq '.npmrc' "min-release-age=99`nregistry=https://r/`naudit-level=high`nallow-git=none`nallow-remote=none`nallow-file=root`nallow-directory=root`nstrict-allow-scripts=true`ndangerously-allow-all-scripts=false`nallow-scripts-pin=true`nignore-extension=true`n" (Join-Path $h '.npmrc'))
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'enable --force overwrites stricter existing values' {
  $h = NewHome
  try {
    [System.IO.File]::WriteAllText((Join-Path $h '.npmrc'), "min-release-age=99`n")
    [void](InvokePmsec $h $null @('--tool','npm','--days','1','--force'))
    $body = [System.IO.File]::ReadAllText((Join-Path $h '.npmrc'))
    if ($body -notmatch '(?m)^min-release-age=1$') { $script:LastFail = "expected min-release-age=1, got: $body"; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'enable --days upgrades when request exceeds existing' {
  $h = NewHome
  try {
    [System.IO.File]::WriteAllText((Join-Path $h '.npmrc'), "min-release-age=3`n")
    [void](InvokePmsec $h $null @('--tool','npm','--days','14'))
    $body = [System.IO.File]::ReadAllText((Join-Path $h '.npmrc'))
    if ($body -notmatch '(?m)^min-release-age=14$') { $script:LastFail = "expected min-release-age=14, got: $body"; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T '--tool restricts which tools get written' {
  $h = NewHome
  try {
    [void](InvokePmsec $h $null @('--tool','npm,bun'))
    if (-not (Test-Path -LiteralPath (Join-Path $h '.npmrc')))      { $script:LastFail = '.npmrc not written'; return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $h '.bunfig.toml'))){ $script:LastFail = '.bunfig.toml not written'; return $false }
    if (Test-Path -LiteralPath (PathJoin $h '.config' 'uv' 'uv.toml')) { $script:LastFail = 'uv.toml unexpectedly written'; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'Windows uv path uses APPDATA' {
  $h = NewHome
  try {
    $appdata = PathJoin $h 'AppData' 'Roaming'
    [void](InvokePmsec $h @{ APPDATA = $appdata; PMSEC_FAKE_SCOPES = "windows|$h|win32" } @('--tool','uv'))
    return (AssertMatch 'uv key' '(?m)^exclude-newer = "1 days"$' ([System.IO.File]::ReadAllText((PathJoin $appdata 'uv' 'uv.toml'))))
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'Windows mise path uses LOCALAPPDATA' {
  $h = NewHome
  try {
    $local = PathJoin $h 'AppData' 'Local'
    [void](InvokePmsec $h @{ LOCALAPPDATA = $local; PMSEC_FAKE_SCOPES = "windows|$h|win32" } @('--tool','mise'))
    return (AssertMatch 'mise key' '(?m)^minimum_release_age = "1d"$' ([System.IO.File]::ReadAllText((PathJoin $local 'mise' 'config.toml'))))
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'Windows mise new mode writes config.pmsec.toml under .config' {
  $h = NewHome
  try {
    $local = PathJoin $h 'AppData' 'Local'
    [void](InvokePmsec $h @{ LOCALAPPDATA = $local; PMSEC_FAKE_SCOPES = "windows|$h|win32"; PMSEC_MISE_VERSION = '2026.11.0' } @('--tool','mise'))
    $ok = Test-Path -LiteralPath (PathJoin $h '.config' 'mise' 'config.pmsec.toml')
    $ok = $ok -and (Test-Path -LiteralPath (PathJoin $h '.config' 'mise' 'miserc.local.toml'))
    $ok = $ok -and -not (Test-Path -LiteralPath (PathJoin $local 'mise' 'config.toml'))
    if (-not $ok) { $script:LastFail = 'new-mode mise files not under .config' }
    return $ok
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'Windows mise new mode reverse-migrates when the version drops' {
  $h = NewHome
  try {
    $local = PathJoin $h 'AppData' 'Local'
    $scope = "windows|$h|win32"
    [void](InvokePmsec $h @{ LOCALAPPDATA = $local; PMSEC_FAKE_SCOPES = $scope; PMSEC_MISE_VERSION = '2026.11.0' } @('--tool','mise'))
    $r = InvokePmsec $h @{ LOCALAPPDATA = $local; PMSEC_FAKE_SCOPES = $scope; PMSEC_MISE_VERSION = '2026.10.25' } @('--tool','mise','--check','--json')
    if ($r.Code -eq 0) { $script:LastFail = 'legacy check must fail while both generations exist'; return $false }
    $r = InvokePmsec $h @{ LOCALAPPDATA = $local; PMSEC_FAKE_SCOPES = $scope; PMSEC_MISE_VERSION = '2026.10.25' } @('--tool','mise')
    if ($r.Code -ne 0) { $script:LastFail = "reverse migration exit $($r.Code)"; return $false }
    $ok = Test-Path -LiteralPath (PathJoin $local 'mise' 'config.toml')
    $ok = $ok -and -not (Test-Path -LiteralPath (PathJoin $h '.config' 'mise' 'config.pmsec.toml'))
    if (-not $ok) { $script:LastFail = 'reverse migration left the new generation behind' }
    return $ok
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

$onWindows = $PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows

# A junction on Windows, a symlink elsewhere: both reach config.pmsec.toml by
# a spelling that differs from MISE_GLOBAL_CONFIG_FILE.
T 'mise reverse migration keeps a MISE_GLOBAL_CONFIG_FILE alias reached through a linked MISE_CONFIG_DIR' {
  $h = NewHome
  try {
    $real = PathJoin $h 'real'
    $link = PathJoin $h 'link'
    [void](New-Item -ItemType Directory -Path $real -Force)
    [void](New-Item -ItemType $(if ($onWindows) { 'Junction' } else { 'SymbolicLink' }) -Path $link -Value $real)
    [System.IO.File]::WriteAllText((PathJoin $real 'config.pmsec.toml'), "[settings]`nminimum_release_age = `"3d`"`n")
    [System.IO.File]::WriteAllText((PathJoin $real 'miserc.local.toml'), "env = [`"pmsec`"]`n")
    $vars = @{ PMSEC_MISE_VERSION = '2026.10.25'; MISE_CONFIG_DIR = $link; MISE_GLOBAL_CONFIG_FILE = (PathJoin $real 'config.pmsec.toml') }
    if ($onWindows) { $vars.PMSEC_FAKE_SCOPES = "windows|$h|win32"; $vars.LOCALAPPDATA = (PathJoin $h 'AppData' 'Local') }
    $r = InvokePmsec $h $vars @('--tool','mise','--days','1')
    if ($r.Code -ne 0) { $script:LastFail = "enable exit $($r.Code)"; return $false }
    $p = PathJoin $real 'config.pmsec.toml'
    if (-not (Test-Path -LiteralPath $p)) { $script:LastFail = 'aliased destination deleted'; return $false }
    if (-not (AssertMatch 'aliased destination kept' '(?m)^minimum_release_age = "3d"$' ([System.IO.File]::ReadAllText($p)))) { return $false }
    if (Test-Path -LiteralPath (PathJoin $real 'miserc.local.toml')) { $script:LastFail = 'selector survived reverse migration'; return $false }
    $r = InvokePmsec $h $vars @('--tool','mise','--check')
    if ($r.Code -ne 0) { $script:LastFail = "check after migration exit $($r.Code)"; return $false }
    return $true
  } finally {
    if (Test-Path -LiteralPath (PathJoin $h 'link')) { (Get-Item -LiteralPath (PathJoin $h 'link') -Force).Delete() }
    Remove-Item -Recurse -Force -LiteralPath $h
  }
}

T 'mise legacy enable converges when config.toml is hard-linked to config.pmsec.toml' {
  $h = NewHome
  try {
    $d = PathJoin $h '.config' 'mise'
    [void](New-Item -ItemType Directory -Path $d -Force)
    [System.IO.File]::WriteAllText((PathJoin $d 'config.pmsec.toml'), "[settings]`nminimum_release_age = `"3d`"`n")
    [void](New-Item -ItemType HardLink -Path (PathJoin $d 'config.toml') -Value (PathJoin $d 'config.pmsec.toml'))
    $vars = @{ PMSEC_MISE_VERSION = '2026.10.25'; MISE_GLOBAL_CONFIG_FILE = (PathJoin $d 'config.toml') }
    if ($onWindows) { $vars.PMSEC_FAKE_SCOPES = "windows|$h|win32"; $vars.LOCALAPPDATA = (PathJoin $h 'AppData' 'Local') }
    $r = InvokePmsec $h $vars @('--tool','mise','--days','1')
    if ($r.Code -ne 0) { $script:LastFail = "enable exit $($r.Code)"; return $false }
    if (-not (AssertMatch 'legacy keeps stricter value' '(?m)^minimum_release_age = "3d"$' ([System.IO.File]::ReadAllText((PathJoin $d 'config.toml'))))) { return $false }
    $r = InvokePmsec $h $vars @('--tool','mise','--check')
    if ($r.Code -ne 0) { $script:LastFail = "check after enable exit $($r.Code)"; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

if (-not $onWindows -and (& id -u) -ne '0') {
  T 'mise legacy --force enable leaves config.toml alone when the miserc is unreadable' {
    $h = NewHome
    $rc = PathJoin $h '.config' 'mise' 'miserc.local.toml'
    try {
      [void](New-Item -ItemType Directory -Path (PathJoin $h '.config' 'mise') -Force)
      [System.IO.File]::WriteAllText($rc, "env = [`"pmsec`"]`n")
      & chmod 000 $rc
      $r = InvokePmsec $h @{ PMSEC_MISE_VERSION = '2026.10.25' } @('--tool','mise','--force')
      if ($r.Code -eq 0) { $script:LastFail = 'enable succeeded with an unreadable miserc'; return $false }
      if (Test-Path -LiteralPath (PathJoin $h '.config' 'mise' 'config.toml')) { $script:LastFail = 'config.toml written before the miserc read failed'; return $false }
      return $true
    } finally { & chmod 600 $rc; Remove-Item -Recurse -Force -LiteralPath $h }
  }
} else {
  Write-Host 'SKIP  mise unreadable miserc (POSIX non-root only)'
}

# Needs a case-insensitive filesystem: the default temp dir on Windows, or
# PMSEC_TEST_CASEFOLD_DIR (e.g. a vfat mount) elsewhere.
$casefoldRoot = if ($env:PMSEC_TEST_CASEFOLD_DIR) { $env:PMSEC_TEST_CASEFOLD_DIR } else { [System.IO.Path]::GetTempPath() }
$casefold = $false
try {
  $probeDir = PathJoin $casefoldRoot ('pmsec-case-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  [void](New-Item -ItemType Directory -Path $probeDir -Force)
  [System.IO.File]::WriteAllText((PathJoin $probeDir 'probe'), '')
  $casefold = Test-Path -LiteralPath (PathJoin $probeDir 'PROBE')
  Remove-Item -Recurse -Force -LiteralPath $probeDir
} catch { $casefold = $false }

if ($casefold) {
  T 'mise reverse migration keeps a case-variant MISE_GLOBAL_CONFIG_FILE alias' {
    $h = PathJoin $casefoldRoot ('pmsec-ps-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    [void](New-Item -ItemType Directory -Path $h -Force)
    try {
      $d = PathJoin $h '.config' 'mise'
      [void](New-Item -ItemType Directory -Path $d -Force)
      [System.IO.File]::WriteAllText((PathJoin $d 'config.pmsec.toml'), "[settings]`nminimum_release_age = `"3d`"`n")
      [System.IO.File]::WriteAllText((PathJoin $d 'miserc.local.toml'), "env = [`"pmsec`"]`n")
      $vars = @{ PMSEC_MISE_VERSION = '2026.10.25'; MISE_GLOBAL_CONFIG_FILE = (PathJoin $d 'Config.Pmsec.toml') }
      if ($onWindows) { $vars.PMSEC_FAKE_SCOPES = "windows|$h|win32"; $vars.LOCALAPPDATA = (PathJoin $h 'AppData' 'Local') }
      [void](InvokePmsec $h $vars @('--tool','mise','--days','1'))
      $p = PathJoin $d 'config.pmsec.toml'
      if (-not (Test-Path -LiteralPath $p)) { $script:LastFail = 'aliased destination deleted'; return $false }
      $ok = AssertMatch 'aliased destination kept' '(?m)^minimum_release_age = "3d"$' ([System.IO.File]::ReadAllText($p))
      if ($ok -and (Test-Path -LiteralPath (PathJoin $d 'miserc.local.toml'))) { $script:LastFail = 'selector survived reverse migration'; $ok = $false }
      if ($ok) {
        $r = InvokePmsec $h $vars @('--tool','mise','--check')
        if ($r.Code -ne 0) { $script:LastFail = "check after migration exit $($r.Code)"; $ok = $false }
      }
      return $ok
    } finally { Remove-Item -Recurse -Force -LiteralPath $h }
  }
} else {
  Write-Host 'SKIP  mise case-variant alias (needs a case-insensitive filesystem)'
}

T 'mise cleanup fails closed on a cyclic MISE_GLOBAL_CONFIG_FILE link' {
  $h = NewHome
  try {
    $cycle = PathJoin $h 'cycle'
    [void](New-Item -ItemType Directory -Path $cycle -Force)
    $again = PathJoin $cycle 'again'
    $dir = PathJoin $cycle 'dir'
    # again aliases the cycle root; dir's relative target expands through it,
    # so the resolved spelling grows on every hop instead of repeating.
    try {
      [void](New-Item -ItemType SymbolicLink -Path $again -Target $cycle)
      [void](New-Item -ItemType SymbolicLink -Path $dir -Target (PathJoin 'again' 'dir'))
    } catch {
      Write-Host 'SKIP  mise cyclic-link cleanup (symlink creation blocked)'
      return $true
    }
    $d = PathJoin $h '.config' 'mise'
    [void](New-Item -ItemType Directory -Path $d -Force)
    $pmsecPath = PathJoin $d 'config.pmsec.toml'
    $selectorPath = PathJoin $d 'miserc.local.toml'
    [System.IO.File]::WriteAllText($pmsecPath, "[settings]`nminimum_release_age = `"3d`"`n")
    [System.IO.File]::WriteAllText($selectorPath, "env = [`"pmsec`"]`n")
    $vars = @{
      PMSEC_MISE_VERSION = '2026.10.25'
      MISE_GLOBAL_CONFIG_FILE = (PathJoin $dir 'config.toml')
    }
    if ($onWindows) {
      $vars.PMSEC_FAKE_SCOPES = "windows|$h|win32"
      $vars.LOCALAPPDATA = (PathJoin $h 'AppData' 'Local')
    }
    $r = InvokePmsec $h $vars @('--disable','--tool','mise')
    if ($r.Code -eq 0) { $script:LastFail = "cleanup reported success through a cyclic link`n$($r.Out)"; return $false }
    if (-not (Test-Path -LiteralPath $pmsecPath)) { $script:LastFail = 'cyclic link allowed destructive cleanup'; return $false }
    if (-not (Test-Path -LiteralPath $selectorPath)) { $script:LastFail = 'cyclic link allowed selector cleanup'; return $false }
    return $true
  } finally {
    # Drop the expanding links before the recursive delete so cleanup cannot
    # walk through them.
    foreach ($link in @($dir, $again)) {
      if (Test-Path -LiteralPath $link) { Remove-Item -Force -LiteralPath $link -ErrorAction Ignore }
    }
    Remove-Item -Recurse -Force -LiteralPath $h
  }
}

T 'Windows mise legacy migration follows MISE_CONFIG_DIR' {
  $h = NewHome
  try {
    $custom = PathJoin $h 'mise-custom'
    $scope = "windows|$h|win32"
    [void](InvokePmsec $h @{ MISE_CONFIG_DIR = $custom; PMSEC_FAKE_SCOPES = $scope; PMSEC_MISE_VERSION = '2026.11.0' } @('--tool','mise'))
    if (-not (Test-Path -LiteralPath (PathJoin $custom 'config.pmsec.toml'))) { $script:LastFail = 'pmsec layer not under MISE_CONFIG_DIR'; return $false }
    # A downgrade must migrate into the config dir mise actually reads.
    [void](InvokePmsec $h @{ MISE_CONFIG_DIR = $custom; PMSEC_FAKE_SCOPES = $scope; PMSEC_MISE_VERSION = '2026.10.25' } @('--tool','mise'))
    if (-not (Test-Path -LiteralPath (PathJoin $custom 'config.toml'))) { $script:LastFail = 'legacy write missed MISE_CONFIG_DIR'; return $false }
    $ok = AssertMatch 'legacy cooldown in custom dir' '(?m)^minimum_release_age = "1d"$' ([System.IO.File]::ReadAllText((PathJoin $custom 'config.toml')))
    $ok = $ok -and -not (Test-Path -LiteralPath (PathJoin $custom 'config.pmsec.toml'))
    $ok = $ok -and -not (Test-Path -LiteralPath (PathJoin $h '.config' 'mise' 'config.toml'))
    if (-not $ok) { $script:LastFail = 'downgrade migration wrote the wrong legacy path' }
    return $ok
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'Windows scope ignores XDG_CONFIG_HOME for uv' {
  $h = NewHome
  try {
    $xdg = PathJoin $h 'xdg'
    $appdata = PathJoin $h 'AppData' 'Roaming'
    [void](InvokePmsec $h @{ XDG_CONFIG_HOME = $xdg; APPDATA = $appdata; PMSEC_FAKE_SCOPES = "windows|$h|win32" } @('--tool','uv'))
    if (Test-Path -LiteralPath (PathJoin $xdg 'uv' 'uv.toml')) { $script:LastFail = 'uv leaked into XDG_CONFIG_HOME on win32 scope'; return $false }
    return (Test-Path -LiteralPath (PathJoin $appdata 'uv' 'uv.toml'))
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'WSL scope resolves mise from the distro env, not the Windows env' {
  # The POSIX-rooted override below is spelled with the host path convention,
  # so the end-to-end assertion only holds on non-Windows hosts; the resolver
  # probe test covers the same rules on every host. `$onWindows` also covers
  # Windows PowerShell 5.1, where `$IsWindows` does not exist.
  if ($onWindows) { return $true }
  $h = NewHome
  try {
    $wslHome = PathJoin $h 'wsl-home'
    $posixDir = PathJoin $h 'posix-mise'
    $scope = "ubuntu|$wslHome|linux"
    # Windows-rooted overrides cannot name a path inside the distro.
    [void](InvokePmsec $h @{ MISE_CONFIG_DIR = 'C:\win-mise'; MISE_GLOBAL_CONFIG_FILE = 'C:\win-mise\config.toml'; PMSEC_FAKE_SCOPES = $scope; PMSEC_MISE_VERSION = '2026.11.0' } @('--tool','mise'))
    $ok = Test-Path -LiteralPath (PathJoin $wslHome '.config' 'mise' 'config.pmsec.toml')
    if (-not $ok) { $script:LastFail = 'WSL scope followed Windows-rooted mise overrides'; return $false }
    # A POSIX-rooted override can name a path inside the distro and is honored.
    [void](InvokePmsec $h @{ MISE_CONFIG_DIR = $posixDir; PMSEC_FAKE_SCOPES = $scope; PMSEC_MISE_VERSION = '2026.11.0' } @('--tool','mise'))
    $ok = Test-Path -LiteralPath (PathJoin $posixDir 'config.pmsec.toml')
    if (-not $ok) { $script:LastFail = 'WSL scope ignored a POSIX-rooted MISE_CONFIG_DIR' }
    return $ok
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T '--json emits parseable JSON for check' {
  $h = NewHome
  try {
    $r = InvokePmsec $h $null @('--check','--json')
    $data = $null
    try { $data = $r.Out | ConvertFrom-Json } catch { $script:LastFail = "json parse failed: $_`n$($r.Out)"; return $false }
    if ($data.ok -ne $false) { $script:LastFail = "expected ok=false, got $($data.ok)"; return $false }
    if ($data.bundleDays -ne 1) { $script:LastFail = "expected bundleDays=1, got $($data.bundleDays)"; return $false }
    if ($data.rows.Count -ne 10) { $script:LastFail = "expected 10 rows, got $($data.rows.Count)"; return $false }
    $names = ($data.rows | ForEach-Object { $_.tool }) -join ','
    if ($names -ne 'npm,pnpm,yarn,bun,cargo,mise,uv,bundler,aube,composer') { $script:LastFail = "row order: $names"; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'mise JSON escapes a control character in an unsafe environment name' {
  $h = NewHome
  try {
    [void](New-Item -ItemType Directory -Force -Path (PathJoin $h '.config' 'mise'))
    [System.IO.File]::WriteAllText((PathJoin $h '.config' 'mise' 'miserc.local.toml'), 'env = ["a\u0007x"]' + "`n")
    $r = InvokePmsec $h @{ PMSEC_MISE_VERSION = '2026.11.0' } @('--tool','mise','--json')
    if ($r.Code -eq 0) { $script:LastFail = "unsafe mise environment accepted`n$($r.Out)"; return $false }
    $data = $null
    try { $data = $r.Out | ConvertFrom-Json } catch { $script:LastFail = "json parse failed: $_`n$($r.Out)"; return $false }
    $row = @($data.results)[0]
    if ($r.Out.IndexOf('a\u0007x') -lt 0 -or [string]::IsNullOrEmpty($row.error) -or $row.ok -ne $false) { $script:LastFail = "unsafe environment did not produce a structured escaped error`n$($r.Out)"; return $false }
    if (Test-Path -LiteralPath (PathJoin $h '.config' 'mise' 'config.pmsec.toml')) { $script:LastFail = 'pmsec layer written before the unsafe environment failed'; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'bun enable inserts key inside existing [install] section' {
  $h = NewHome
  try {
    [System.IO.File]::WriteAllText((Join-Path $h '.bunfig.toml'), "[install]`nregistry = ""https://x/""`n")
    [void](InvokePmsec $h $null @('--tool','bun'))
    return (AssertFileEq '.bunfig' "[install]`nignoreScripts = true`nminimumReleaseAge = 86400`nregistry = ""https://x/""`n" (Join-Path $h '.bunfig.toml'))
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'bun enable creates [install] section if missing' {
  $h = NewHome
  try {
    [System.IO.File]::WriteAllText((Join-Path $h '.bunfig.toml'), "telemetry = false`n")
    [void](InvokePmsec $h $null @('--tool','bun'))
    return (AssertFileEq '.bunfig' "telemetry = false`n`n[install]`nignoreScripts = true`nminimumReleaseAge = 86400`n" (Join-Path $h '.bunfig.toml'))
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'yarn check parses npmMinimalAgeGate days correctly' {
  $h = NewHome
  try {
    [System.IO.File]::WriteAllText((Join-Path $h '.yarnrc.yml'), "npmMinimalAgeGate: ""14d""`nenableHardenedMode: true`nenableScripts: false`napprovedGitRepositories: []`n")
    $r = InvokePmsec $h $null @('--check','--json','--tool','yarn')
    $data = $r.Out | ConvertFrom-Json
    if ($data.ok -ne $true) { $script:LastFail = "expected ok=true"; return $false }
    if ($data.rows[0].days -ne 14) { $script:LastFail = "expected 14 days, got $($data.rows[0].days)"; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'bundler enable writes quoted days and preserves unrelated keys' {
  $h = NewHome
  try {
    [void](New-Item -ItemType Directory -Force -Path (PathJoin $h '.bundle'))
    [System.IO.File]::WriteAllText((PathJoin $h '.bundle' 'config'), "---`nBUNDLE_PATH: ""vendor/bundle""`n")
    [void](InvokePmsec $h $null @('--tool','bundler','--days','7'))
    $text = [System.IO.File]::ReadAllText((PathJoin $h '.bundle' 'config'))
    $ok = (AssertMatch 'bundler cooldown' '(?m)^BUNDLE_COOLDOWN: "7"$' $text)
    $ok = $ok -and (AssertMatch 'bundler unrelated key' '(?m)^BUNDLE_PATH: "vendor/bundle"$' $text)
    return $ok
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'bundler check parses BUNDLE_COOLDOWN days' {
  $h = NewHome
  try {
    [void](New-Item -ItemType Directory -Force -Path (PathJoin $h '.bundle'))
    [System.IO.File]::WriteAllText((PathJoin $h '.bundle' 'config'), "---`nBUNDLE_COOLDOWN: ""14""`n")
    $r = InvokePmsec $h $null @('--check','--json','--tool','bundler')
    $data = $r.Out | ConvertFrom-Json
    if ($data.ok -ne $true) { $script:LastFail = "expected ok=true"; return $false }
    if ($data.rows[0].days -ne 14) { $script:LastFail = "expected 14 days, got $($data.rows[0].days)"; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'pnpm check normalizes minutes to days' {
  $h = NewHome
  try {
    [void](New-Item -ItemType Directory -Force -Path (PathJoin $h '.config' 'pnpm'))
    [System.IO.File]::WriteAllText((PathJoin $h '.config' 'pnpm' 'rc'), "minimum-release-age=20160`n")
    $r = InvokePmsec $h @{ PMSEC_PNPM_VERSION = '10.26.0' } @('--check','--json','--tool','pnpm')
    $data = $r.Out | ConvertFrom-Json
    if ($data.rows[0].days -ne 14) { $script:LastFail = "expected 14, got $($data.rows[0].days)"; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T '.bak is created once and never overwritten' {
  $h = NewHome
  try {
    [System.IO.File]::WriteAllText((Join-Path $h '.npmrc'), "registry=https://original/`n")
    [void](InvokePmsec $h $null @('--tool','npm'))
    [void](InvokePmsec $h $null @('--disable','--tool','npm'))
    [void](InvokePmsec $h $null @('--tool','npm'))
    return (AssertFileEq '.npmrc.bak' "registry=https://original/`n" (Join-Path $h '.npmrc.bak'))
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'rejects positional arg with exit 2' {
  $h = NewHome
  try {
    $r = InvokePmsec $h $null @('enable')
    if ($r.Code -ne 2) { $script:LastFail = "expected exit 2, got $($r.Code)`nstderr: $($r.Err)"; return $false }
    return ($r.Err -match 'unexpected argument: enable')
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T '--check and --disable are mutually exclusive' {
  $h = NewHome
  try {
    $r = InvokePmsec $h $null @('--check','--disable')
    if ($r.Code -ne 2) { $script:LastFail = "expected exit 2, got $($r.Code)`nstderr: $($r.Err)"; return $false }
    return ($r.Err -match 'mutually exclusive')
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'hardening extras roundtrip (check / enable / disable)' {
  $h = NewHome
  try {
    $pnpmrc = PathJoin $h '.config' 'pnpm' 'rc'
    [void](New-Item -ItemType Directory -Force -Path (PathJoin $h '.config' 'pnpm'))
    [System.IO.File]::WriteAllText($pnpmrc, "minimum-release-age=20160`n")
    $r = InvokePmsec $h $null @('--check','--json','--tool','pnpm')
    if ($r.Code -ne 1) { $script:LastFail = "extras-missing exit $($r.Code)"; return $false }
    $data = $r.Out | ConvertFrom-Json
    if ($data.ok -ne $false) { $script:LastFail = "extras-missing ok != false"; return $false }
    if ($data.rows[0].extras.Count -ne 8) { $script:LastFail = "expected 8 extras, got $($data.rows[0].extras.Count)"; return $false }
    [void](InvokePmsec $h $null @('--tool','pnpm'))
    $body = [System.IO.File]::ReadAllText($pnpmrc)
    if ($body -notmatch '(?m)^trust-policy=no-downgrade$') { $script:LastFail = "trust-policy not written: $body"; return $false }
    if ($body -notmatch '(?m)^block-exotic-subdeps=true$') { $script:LastFail = "block-exotic-subdeps not written: $body"; return $false }
    if ($body -notmatch '(?m)^strict-dep-builds=true$') { $script:LastFail = "strict-dep-builds not written: $body"; return $false }
    if ($body -notmatch '(?m)^verify-deps-before-run=error$') { $script:LastFail = "verify-deps-before-run not written: $body"; return $false }
    if ($body -notmatch '(?m)^minimum-release-age-strict=true$') { $script:LastFail = "minimum-release-age-strict not written: $body"; return $false }
    $r2 = InvokePmsec $h $null @('--check','--json','--tool','pnpm')
    if ($r2.Code -ne 0) { $script:LastFail = "after-enable exit $($r2.Code)"; return $false }
    if (($r2.Out | ConvertFrom-Json).ok -ne $true) { $script:LastFail = "after-enable ok != true"; return $false }
    [void](InvokePmsec $h $null @('--disable','--tool','pnpm'))
    $after = [System.IO.File]::ReadAllText($pnpmrc)
    if ($after -match 'trust-policy') { $script:LastFail = "trust-policy not removed: $after"; return $false }
    if ($after -match 'block-exotic-subdeps') { $script:LastFail = "block-exotic-subdeps not removed: $after"; return $false }
    if ($after -match 'strict-dep-builds') { $script:LastFail = "strict-dep-builds not removed: $after"; return $false }
    if ($after -match 'verify-deps-before-run') { $script:LastFail = "verify-deps-before-run not removed: $after"; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T '--days N overrides bundle cooldown for enable and check' {
  $h = NewHome
  try {
    $r = InvokePmsec $h $null @('--days','7')
    if ($r.Code -ne 0) { $script:LastFail = "enable --days 7 exit $($r.Code)"; return $false }
    $npm = [System.IO.File]::ReadAllText((Join-Path $h '.npmrc'))
    if ($npm -notmatch '(?m)^min-release-age=7$') { $script:LastFail = "min-release-age not 7: $npm"; return $false }
    $pnpm = [System.IO.File]::ReadAllText((PathJoin $h '.config' 'pnpm' 'rc'))
    if ($pnpm -notmatch '(?m)^minimum-release-age=10080$') { $script:LastFail = "minimum-release-age not 10080: $pnpm"; return $false }
    $pnmyaml = [System.IO.File]::ReadAllText((PathJoin $h '.config' 'pnpm' 'config.yaml'))
    if ($pnmyaml -notmatch '(?m)^minimumReleaseAge: 10080$') { $script:LastFail = "minimumReleaseAge not 10080: $pnmyaml"; return $false }
    $uv = [System.IO.File]::ReadAllText((Join-Path $h '.config/uv/uv.toml'))
    if ($uv -notmatch 'exclude-newer = "7 days"') { $script:LastFail = "uv not 7 days: $uv"; return $false }
    $bun = [System.IO.File]::ReadAllText((Join-Path $h '.bunfig.toml'))
    if ($bun -notmatch 'minimumReleaseAge = 604800') { $script:LastFail = "bun not 604800: $bun"; return $false }
    $aube = [System.IO.File]::ReadAllText((PathJoin $h '.config' 'aube' 'config.toml'))
    if ($aube -notmatch 'minimumReleaseAge = 10080') { $script:LastFail = "aube not 10080: $aube"; return $false }

    $r2 = InvokePmsec $h $null @('--check','--json','--days','7')
    if ($r2.Code -ne 0) { $script:LastFail = "check --days 7 exit $($r2.Code)"; return $false }
    if (($r2.Out | ConvertFrom-Json).bundleDays -ne 7) { $script:LastFail = "bundleDays != 7"; return $false }

    $r3 = InvokePmsec $h $null @('--check')
    if ($r3.Code -ne 0) { $script:LastFail = "default check exit $($r3.Code)"; return $false }

    $r4 = InvokePmsec $h $null @('--check','--days','30')
    if ($r4.Code -ne 1) { $script:LastFail = "stricter check should fail, got $($r4.Code)"; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T '--days rejects non-positive integers with exit 2' {
  $h = NewHome
  try {
    foreach ($bad in @('0','-1','abc','')) {
      $r = InvokePmsec $h $null @('--days',$bad)
      if ($r.Code -ne 2) { $script:LastFail = "--days '$bad' expected exit 2 got $($r.Code)"; return $false }
    }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T '--version prints PmsecVersion' {
  $h = NewHome
  try {
    $expected = (Select-String -Path $Pmsec -Pattern "PmsecVersion = '([^']+)'" | Select-Object -First 1).Matches[0].Groups[1].Value
    foreach ($flag in @('--version', '-V')) {
      $r = InvokePmsec $h $null @($flag)
      if ($r.Code -ne 0) { $script:LastFail = "$flag exit $($r.Code)`n$($r.Out)"; return $false }
      if ($r.Out.Trim() -ne "pmsec $expected") { $script:LastFail = "$flag out '$($r.Out.Trim())' != 'pmsec $expected'"; return $false }
    }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'pnpm 11 reads config.yaml and default-enforces missing blockExoticSubdeps' {
  $h = NewHome
  try {
    $pnpmConfigDir = PathJoin $h 'AppData' 'Local' 'pnpm' 'config'
    [void](New-Item -ItemType Directory -Force -Path $pnpmConfigDir)
    [System.IO.File]::WriteAllText((Join-Path $pnpmConfigDir 'config.yaml'), "minimumReleaseAge: 4320`n")
    # An explicit version override lets the YAML path run on the fake Linux
    # scope used by the test harness too.
    $r = InvokePmsec $h @{ PMSEC_FAKE_SCOPES = "windows|$h|win32"; PMSEC_PNPM_VERSION = '11.0.0' } @('--check','--json','--tool','pnpm')
    if ($r.Code -ne 1) { $script:LastFail = "expected exit 1 (trustPolicy still missing) got $($r.Code)`n$($r.Out)"; return $false }
    $data = $r.Out | ConvertFrom-Json
    if ($data.rows[0].key -ne 'minimumReleaseAge') { $script:LastFail = "expected yaml key`n$($r.Out)"; return $false }
    if ($data.rows[0].path -notmatch 'config\.yaml$') { $script:LastFail = "expected config.yaml path`n$($r.Out)"; return $false }
    $beSub = $data.rows[0].extras | Where-Object { $_.key -eq 'blockExoticSubdeps' }
    $trust = $data.rows[0].extras | Where-Object { $_.key -eq 'trustPolicy' }
    if (-not $beSub.ok) { $script:LastFail = "blockExoticSubdeps ok must be true`n$($r.Out)"; return $false }
    if (-not $beSub.defaultEnforced) { $script:LastFail = "blockExoticSubdeps defaultEnforced must be true`n$($r.Out)"; return $false }
    if ($null -ne $beSub.configured) { $script:LastFail = "blockExoticSubdeps configured must be null`n$($r.Out)"; return $false }
    if ($trust.ok) { $script:LastFail = "trustPolicy ok must be false`n$($r.Out)"; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'pnpm 11 ignores legacy rc values' {
  $h = NewHome
  try {
    $pnpmrcDir = PathJoin $h 'AppData' 'Local' 'pnpm' 'config'
    [void](New-Item -ItemType Directory -Force -Path $pnpmrcDir)
    [System.IO.File]::WriteAllText((Join-Path $pnpmrcDir 'rc'), "minimum-release-age=10080`ntrust-policy=no-downgrade`n")
    $r = InvokePmsec $h @{ PMSEC_FAKE_SCOPES = "windows|$h|win32"; PMSEC_PNPM_VERSION = '11.28.5' } @('--check','--json','--tool','pnpm')
    if ($r.Code -ne 1) { $script:LastFail = "legacy rc-only check should fail, got $($r.Code)`n$($r.Out)"; return $false }
    $data = $r.Out | ConvertFrom-Json
    if ($null -ne $data.rows[0].configured) { $script:LastFail = "legacy rc value should be ignored`n$($r.Out)"; return $false }
    if ($data.rows[0].path -notmatch 'config\.yaml$') { $script:LastFail = "expected config.yaml path`n$($r.Out)"; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'pnpm <11 still flags missing block-exotic-subdeps' {
  $h = NewHome
  try {
    $pnpmrcDir = PathJoin $h 'AppData' 'Local' 'pnpm' 'config'
    [void](New-Item -ItemType Directory -Force -Path $pnpmrcDir)
    [System.IO.File]::WriteAllText((Join-Path $pnpmrcDir 'rc'), "minimum-release-age=4320`n")
    $r = InvokePmsec $h @{ PMSEC_FAKE_SCOPES = "windows|$h|win32"; PMSEC_PNPM_VERSION = '10.26.0' } @('--check','--json','--tool','pnpm')
    if ($r.Out -match '"defaultEnforced"') { $script:LastFail = "pnpm 10 must not emit defaultEnforced`n$($r.Out)"; return $false }
    $data = $r.Out | ConvertFrom-Json
    $beSub = $data.rows[0].extras | Where-Object { $_.key -eq 'block-exotic-subdeps' }
    if ($beSub.ok) { $script:LastFail = "pnpm 10 should report ok=false`n$($r.Out)"; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

# ---------- WSL / multi-scope ----------

T 'multi-scope enable writes both host and WSL configs' {
  $h1 = NewHome
  $h2 = NewHome
  try {
    $appdata = PathJoin $h1 'AppData' 'Roaming'
    $local   = PathJoin $h1 'AppData' 'Local'
    $scopes  = "windows|$h1|win32;wsl-Ubuntu|$h2|linux"
    $r = InvokePmsec $h1 @{ PMSEC_FAKE_SCOPES = $scopes; APPDATA = $appdata; LOCALAPPDATA = $local } @()
    if ($r.Code -ne 0) { $script:LastFail = "enable exit $($r.Code)`n$($r.Out)"; return $false }
    if ($r.Out -notmatch '\[windows\]')     { $script:LastFail = "missing [windows] header`n$($r.Out)"; return $false }
    if ($r.Out -notmatch '\[wsl-Ubuntu\]')  { $script:LastFail = "missing [wsl-Ubuntu] header`n$($r.Out)"; return $false }
    $ok = $true
    $ok = $ok -and (Test-Path -LiteralPath (Join-Path $h1 '.npmrc'))
    $ok = $ok -and (Test-Path -LiteralPath (PathJoin $appdata 'uv' 'uv.toml'))
    $ok = $ok -and (Test-Path -LiteralPath (PathJoin $local 'mise' 'config.toml'))
    $ok = $ok -and (Test-Path -LiteralPath (Join-Path $h2 '.npmrc'))
    $ok = $ok -and (Test-Path -LiteralPath (PathJoin $h2 '.config' 'uv' 'uv.toml'))
    $ok = $ok -and (Test-Path -LiteralPath (PathJoin $h2 '.config' 'mise' 'config.toml'))
    $ok = $ok -and (Test-Path -LiteralPath (PathJoin $h2 '.config' 'aube' 'config.toml'))
    if (-not $ok) { $script:LastFail = "files missing across scopes`n$($r.Out)" }
    return $ok
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $h1
    Remove-Item -Recurse -Force -LiteralPath $h2
  }
}

T '--no-wsl skips linux scopes when fakes are present' {
  $h1 = NewHome
  $h2 = NewHome
  try {
    $appdata = PathJoin $h1 'AppData' 'Roaming'
    $scopes  = "windows|$h1|win32;wsl-Ubuntu|$h2|linux"
    $r = InvokePmsec $h1 @{ PMSEC_FAKE_SCOPES = $scopes; APPDATA = $appdata } @('--no-wsl','--tool','npm')
    if ($r.Code -ne 0) { $script:LastFail = "exit $($r.Code)`n$($r.Out)"; return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $h1 '.npmrc'))) { $script:LastFail = 'host .npmrc not written'; return $false }
    if (Test-Path -LiteralPath (Join-Path $h2 '.npmrc'))         { $script:LastFail = 'wsl .npmrc unexpectedly written'; return $false }
    return $true
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $h1
    Remove-Item -Recurse -Force -LiteralPath $h2
  }
}

T 'PMSEC_NO_WSL=1 env var skips linux scopes' {
  $h1 = NewHome
  $h2 = NewHome
  try {
    $scopes  = "windows|$h1|win32;wsl-Ubuntu|$h2|linux"
    $r = InvokePmsec $h1 @{ PMSEC_FAKE_SCOPES = $scopes; PMSEC_NO_WSL = '1' } @('--tool','npm')
    if ($r.Code -ne 0) { $script:LastFail = "exit $($r.Code)`n$($r.Out)"; return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $h1 '.npmrc'))) { $script:LastFail = 'host .npmrc not written'; return $false }
    if (Test-Path -LiteralPath (Join-Path $h2 '.npmrc'))         { $script:LastFail = 'wsl .npmrc unexpectedly written'; return $false }
    return $true
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $h1
    Remove-Item -Recurse -Force -LiteralPath $h2
  }
}

T 'check JSON includes scope on every row across scopes' {
  $h1 = NewHome
  $h2 = NewHome
  try {
    $scopes = "windows|$h1|win32;wsl-Ubuntu|$h2|linux"
    $r = InvokePmsec $h1 @{ PMSEC_FAKE_SCOPES = $scopes } @('--check','--json','--tool','npm')
    $data = $r.Out | ConvertFrom-Json
    if ($data.rows.Count -ne 2) { $script:LastFail = "expected 2 rows, got $($data.rows.Count)`n$($r.Out)"; return $false }
    $labels = ($data.rows | ForEach-Object { $_.scope }) -join ','
    if ($labels -ne 'windows,wsl-Ubuntu') { $script:LastFail = "scope order: $labels"; return $false }
    return $true
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $h1
    Remove-Item -Recurse -Force -LiteralPath $h2
  }
}

T 'multi-scope disable removes from both scopes' {
  $h1 = NewHome
  $h2 = NewHome
  try {
    [System.IO.File]::WriteAllText((Join-Path $h1 '.npmrc'), "min-release-age=3`naudit-level=high`nregistry=https://r/`n")
    [System.IO.File]::WriteAllText((Join-Path $h2 '.npmrc'), "min-release-age=3`naudit-level=high`nregistry=https://r2/`n")
    $scopes = "windows|$h1|win32;wsl-Ubuntu|$h2|linux"
    $r = InvokePmsec $h1 @{ PMSEC_FAKE_SCOPES = $scopes } @('--disable','--tool','npm')
    if ($r.Code -ne 0) { $script:LastFail = "disable exit $($r.Code)`n$($r.Out)"; return $false }
    $ok = $true
    $ok = $ok -and (AssertFileEq 'h1 .npmrc' "registry=https://r/`n"  (Join-Path $h1 '.npmrc'))
    $ok = $ok -and (AssertFileEq 'h2 .npmrc' "registry=https://r2/`n" (Join-Path $h2 '.npmrc'))
    return $ok
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $h1
    Remove-Item -Recurse -Force -LiteralPath $h2
  }
}

T 'single-scope output has no scope header (back-compat)' {
  $h = NewHome
  try {
    $r = InvokePmsec $h $null @('--tool','npm')
    if ($r.Out -match '(?m)^\[') { $script:LastFail = "unexpected scope header in single-scope output`n$($r.Out)"; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

# `pmsec --doctor --json` is the read-only diagnostic — it must report a
# stable shape so any orchestrator (Intune Detection rule, SCCM CI, scheduled
# task, RMM agent, …) can consume it via JSON exit-code parsing.
T 'doctor --json reports per-tool writability on a fresh home' {
  $h = NewHome
  try {
    $r = InvokePmsec $h $null @('--doctor','--json')
    if ($r.Code -ne 0) { $script:LastFail = "exit code $($r.Code)`n$($r.Out)`n$($r.Err)"; return $false }
    $data = $r.Out | ConvertFrom-Json
    if ($data.doctor -ne $true) { $script:LastFail = 'doctor flag missing'; return $false }
    if ($data.ok -ne $true) { $script:LastFail = "ok=false on fresh home: $($r.Out)"; return $false }
    if ($data.platform -ne 'win32') { $script:LastFail = "platform=$($data.platform)"; return $false }
    $tools = @($data.tools | ForEach-Object { $_.tool })
    foreach ($t in @('npm','pnpm','yarn','bun','cargo','mise','aube','uv','bundler','composer')) {
      if ($tools -notcontains $t) { $script:LastFail = "tool $t missing from doctor output"; return $false }
    }
    foreach ($row in $data.tools) {
      foreach ($field in @('path','parent','exists','writable','parentExists','parentWritable','owner')) {
        if (-not ($row.PSObject.Properties.Name -contains $field)) {
          $script:LastFail = "tool $($row.tool) missing field $field"
          return $false
        }
      }
      if ($row.parentWritable -ne $true) {
        $script:LastFail = "tool $($row.tool) parentWritable=false on fresh home"
        return $false
      }
    }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

# WriteAtomic must surface a labeled error when refusing to follow a
# reparse point — that prefix is what makes orchestrator logs actionable.
T 'write_atomic refuses to follow a reparse point with a labeled error' {
  $h = NewHome
  try {
    # Simulate a reparse point by creating a directory junction at the .npmrc
    # path. New-Item -ItemType Junction works on Windows; on macOS pwsh we
    # fall back to a symlink which carries the same ReparsePoint attribute
    # check from the runtime point of view.
    $target = Join-Path $h 'real.target'
    [void](New-Item -ItemType Directory -Path $target -Force)
    $linkPath = Join-Path $h '.npmrc'
    try {
      [void](New-Item -ItemType SymbolicLink -Path $linkPath -Target $target -Force)
    } catch {
      # Some runtimes block symlink creation without admin — skip rather
      # than fail the suite; the labeled-error guarantee is asserted by
      # the bash and node suites too.
      Write-Host "SKIP  write_atomic reparse refusal (symlink creation blocked)"
      return $true
    }
    $r = InvokePmsec $h $null @('--tool','npm')
    if ($r.Out -notmatch 'refusing to write through symlink' -and $r.Err -notmatch 'refusing to write through symlink') {
      $script:LastFail = "expected reparse-point refusal in output:`n$($r.Out)`n--err--`n$($r.Err)"
      return $false
    }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

# A link planted at the .bak path must be refused too; Copy-Item would
# otherwise write the (token-bearing) backup wherever the link points.
T 'write_atomic refuses a reparse point planted at the .bak path' {
  $h = NewHome
  try {
    $cfg = Join-Path $h '.npmrc'
    [System.IO.File]::WriteAllText($cfg, "registry=https://original/`n")
    $target = Join-Path $h 'real.target'
    [void](New-Item -ItemType Directory -Path $target -Force)
    try {
      [void](New-Item -ItemType SymbolicLink -Path "$cfg.bak" -Target $target -Force)
    } catch {
      Write-Host "SKIP  write_atomic .bak reparse refusal (symlink creation blocked)"
      return $true
    }
    $r = InvokePmsec $h $null @('--tool','npm')
    if ($r.Code -eq 0) { $script:LastFail = "expected non-zero exit"; return $false }
    if ($r.Out -notmatch 'refusing to write backup through symlink' -and $r.Err -notmatch 'refusing to write backup through symlink') {
      $script:LastFail = "expected .bak reparse-point refusal in output:`n$($r.Out)`n--err--`n$($r.Err)"
      return $false
    }
    return (AssertFileEq 'config untouched' "registry=https://original/`n" $cfg)
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'cargo writes global-min-publish-age tracking --days' {
  $h = NewHome
  try {
    $cfgPath = Join-Path (Join-Path $h '.cargo') 'config.toml'
    [void](InvokePmsec $h $null @('--tool','cargo','--days','7'))
    $cfg = [System.IO.File]::ReadAllText($cfgPath)
    $ok = (AssertMatch 'registry publish age' '(?m)^global-min-publish-age = "7 days"$' $cfg)
    if ($cfg -match 'minimum-release-age') { $script:LastFail = "legacy install key still written: $cfg"; return $false }
    if (-not $ok) { return $false }
    $r = InvokePmsec $h $null @('--check','--tool','cargo','--days','7','--json')
    if ($r.Code -ne 0) { $script:LastFail = "check exit $($r.Code): $($r.Out)"; return $false }
    $row = ($r.Out | ConvertFrom-Json).rows[0]
    if ($row.key -ne 'global-min-publish-age' -or $row.configured -ne '"7 days"' -or $row.days -ne 7 -or $row.extras.Count -ne 0) {
      $script:LastFail = "unexpected row: $($r.Out)"; return $false
    }
    [System.IO.File]::WriteAllText($cfgPath, "[registry]`nglobal-min-publish-age = `"1 days`"`n")
    $r = InvokePmsec $h $null @('--check','--tool','cargo','--days','7')
    if ($r.Code -ne 1) { $script:LastFail = "weaker publish age should fail check: $($r.Code)"; return $false }
    [System.IO.File]::WriteAllText($cfgPath, "[registry]`nglobal-min-publish-age = `"2 weeks`"`n")
    $r = InvokePmsec $h $null @('--check','--tool','cargo','--days','7')
    if ($r.Code -ne 0) { $script:LastFail = "stricter publish age should pass check: $($r.Code)"; return $false }
    [System.IO.File]::WriteAllText($cfgPath, "[install]`nminimum-release-age = `"7d`"`n[registry]`nglobal-min-publish-age = `"1 days`"`n")
    [void](InvokePmsec $h $null @('--disable','--tool','cargo'))
    return (AssertFileEq 'disable removes both' "[install]`n[registry]`n" $cfgPath)
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'composer writes JSON config and check/disable roundtrip' {
  $h = NewHome
  try {
    $r = InvokePmsec $h $null @('--tool','composer','--days','7')
    if ($r.Code -ne 0) { $script:LastFail = "enable exit $($r.Code)`n$($r.Out)`n$($r.Err)"; return $false }
    $cfgPath = PathJoin $h '.config' 'composer' 'config.json'
    $cfg = [System.IO.File]::ReadAllText($cfgPath)
    $ok = (AssertMatch 'composer cooldown' '"period": "7 days"' $cfg)
    $ok = $ok -and (AssertMatch 'composer allow-plugins' '"allow-plugins": false' $cfg)
    $ok = $ok -and (AssertMatch 'composer secure-http' '"secure-http": true' $cfg)
    $ok = $ok -and (AssertMatch 'composer disable-tls' '"disable-tls": false' $cfg)
    $ok = $ok -and (AssertMatch 'composer abandoned' '"abandoned": "fail"' $cfg)
    if (-not $ok) { return $false }
    $r = InvokePmsec $h $null @('--check','--json','--tool','composer','--days','7')
    if ($r.Code -ne 0) { $script:LastFail = "check exit $($r.Code)`n$($r.Out)"; return $false }
    if (($r.Out | ConvertFrom-Json).rows[0].days -ne 7) { $script:LastFail = 'composer days != 7'; return $false }
    [void](InvokePmsec $h $null @('--disable','--tool','composer'))
    $r = InvokePmsec $h $null @('--check','--tool','composer')
    if ($r.Out -notmatch 'MISSING composer') { $script:LastFail = "composer not missing after disable`n$($r.Out)"; return $false }
    return $true
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'composer preserves unrelated JSON keys and honors COMPOSER_HOME' {
  $h = NewHome
  try {
    $ch = PathJoin $h 'composer-home'
    [void](New-Item -ItemType Directory -Force -Path $ch)
    $cfgPath = Join-Path $ch 'config.json'
    [System.IO.File]::WriteAllText($cfgPath, "{`n  `"config`": {`n    `"preferred-install`": `"dist`",`n    `"audit`": {`n      `"ignore`": [`"vendor/pkg`"]`n    }`n  },`n  `"repositories`": {`n    `"packagist`": false`n  }`n}`n")
    $r = InvokePmsec $h @{ COMPOSER_HOME = $ch } @('--tool','composer')
    if ($r.Code -ne 0) { $script:LastFail = "enable exit $($r.Code)`n$($r.Err)"; return $false }
    $text = [System.IO.File]::ReadAllText($cfgPath)
    $ok = (AssertMatch 'preferred-install preserved' '"preferred-install": "dist"' $text)
    $ok = $ok -and (AssertMatch 'audit ignore preserved' '"ignore": \["vendor/pkg"\]' $text)
    $ok = $ok -and (AssertMatch 'repositories preserved' '"packagist": false' $text)
    if (-not $ok) { return $false }
    [void](InvokePmsec $h @{ COMPOSER_HOME = $ch } @('--disable','--tool','composer'))
    $text = [System.IO.File]::ReadAllText($cfgPath)
    if ($text -match '"period"') { $script:LastFail = 'composer cooldown not removed'; return $false }
    return (AssertMatch 'preferred-install kept after disable' '"preferred-install": "dist"' $text)
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'real WSL scope reads only forwarded POSIX mise env and maps it to the UNC home' {
  # A `\\wsl$\<distro>` home cannot be opened on a non-Windows test host, so
  # load the resolver functions from pmsec.ps1 and drive them directly.
  $tokens = $null; $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Pmsec, [ref]$tokens, [ref]$parseErrors)
  $names = @('Get-PmsecPlatform','Get-PmsecHome','Get-MiseWslRoot','Get-MiseScopeEnv','ConvertFrom-MiseScopePath','ConvertTo-MiseScopePath','Get-MiseDir','Get-MisePath','Get-MiseSystemMiserc')
  $defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $names -contains $n.Name }, $false) | ForEach-Object { $_.Extent.Text }
  $probe = [scriptblock]::Create(($defs -join "`n") + @'

function PathJoin {
  $parts = @(([string]$args[0]).TrimEnd('\', '/')) + @($args | Select-Object -Skip 1 | ForEach-Object { ([string]$_).Trim('\', '/') })
  ($parts -join '\') -replace '/', '\'
}
$script:Scope = @{ Platform = 'linux'; Home = '\\wsl$\Ubuntu\home\alice' }
@{
  Dir = Get-MiseDir; Path = Get-MisePath; System = Get-MiseSystemMiserc
  MiseEnv = Get-MiseScopeEnv 'MISE_ENV'
  # The raw translation of MISE_CONFIG_DIR: PathJoin re-joins a stripped
  # leading slash, so only this field catches a non-absolute POSIX result.
  FromScope = if ($env:MISE_CONFIG_DIR) { ConvertFrom-MiseScopePath $env:MISE_CONFIG_DIR } else { $null }
}
'@)
  $keys = @('MISE_CONFIG_DIR','MISE_GLOBAL_CONFIG_FILE','MISE_SYSTEM_CONFIG_DIR','MISE_ENV','XDG_CONFIG_HOME','WSLENV')
  $saved = @{}
  foreach ($k in $keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $null) }
  try {
    # Runs the probe and compares every named field; a mismatch fails fast.
    function Probe([string]$Label, [hashtable]$Expected) {
      $r = & $probe
      foreach ($k in $Expected.Keys) {
        if ($r[$k] -cne $Expected[$k]) {
          $script:LastFail = "${Label}: $k = $($r[$k]), expected $($Expected[$k])"
          return $false
        }
      }
      return $true
    }
    $env:MISE_CONFIG_DIR = '/home/alice/mise'
    $env:MISE_SYSTEM_CONFIG_DIR = '/opt/mise'
    $env:MISE_ENV = 'pmsec'
    if (-not (Probe 'unforwarded' @{
      Dir = '\\wsl$\Ubuntu\home\alice\.config\mise'
      System = '\\wsl$\Ubuntu\etc\mise\miserc.toml'
      MiseEnv = $null
    })) { return $false }
    $env:WSLENV = 'MISE_ENV/w:MISE_CONFIG_DIR/pw'
    if (-not (Probe 'wsl-to-win32-only' @{
      Dir = '\\wsl$\Ubuntu\home\alice\.config\mise'
      MiseEnv = $null
    })) { return $false }
    $env:WSLENV = 'FOO:MISE_CONFIG_DIR/up:MISE_SYSTEM_CONFIG_DIR/u:MISE_ENV'
    if (-not (Probe 'forwarded-posix' @{
      Dir = '\\wsl$\Ubuntu\home\alice\mise'
      Path = '\\wsl$\Ubuntu\home\alice\mise\config.toml'
      System = '\\wsl$\Ubuntu\opt\mise\miserc.toml'
      MiseEnv = 'pmsec'
    })) { return $false }
    # /p: a drive-letter value reaches the distro translated to /mnt/<drive>,
    # so pmsec must resolve the same path the distro's mise will read.
    $env:WSLENV = 'MISE_CONFIG_DIR/p'
    $env:MISE_CONFIG_DIR = 'C:\Users\alice\mise'
    if (-not (Probe 'p-drive' @{ Dir = '\\wsl$\Ubuntu\mnt\c\Users\alice\mise'; FromScope = '/mnt/c/Users/alice/mise' })) { return $false }
    $env:MISE_CONFIG_DIR = 'c:\Users\alice\mise'
    if (-not (Probe 'p-lowercase-drive' @{ Dir = '\\wsl$\Ubuntu\mnt\c\Users\alice\mise' })) { return $false }
    $env:MISE_CONFIG_DIR = 'C:/Users/alice/mise'
    if (-not (Probe 'p-forward-slash-drive' @{ Dir = '\\wsl$\Ubuntu\mnt\c\Users\alice\mise' })) { return $false }
    # A POSIX value under /p is already what the distro sees: pass verbatim.
    $env:MISE_CONFIG_DIR = '/home/alice/mise'
    if (-not (Probe 'p-posix-verbatim' @{ Dir = '\\wsl$\Ubuntu\home\alice\mise' })) { return $false }
    # A value inside this distro's UNC root maps back to its POSIX path —
    # and stays absolute, or Get-MiseDir would build a relative POSIX path.
    $env:MISE_CONFIG_DIR = '\\wsl$\Ubuntu\home\alice\mise'
    if (-not (Probe 'p-same-distro-unc' @{ Dir = '\\wsl$\Ubuntu\home\alice\mise'; FromScope = '/home/alice/mise' })) { return $false }
    # Another distro's UNC root is not this distro's view: leave it alone and
    # let the non-POSIX value stay ignored.
    $env:MISE_CONFIG_DIR = '\\wsl$\Debian\home\bob'
    if (-not (Probe 'p-foreign-distro-unc' @{ Dir = '\\wsl$\Ubuntu\home\alice\.config\mise'; FromScope = '\\wsl$\Debian\home\bob' })) { return $false }
    # Flag order and combinations must not change the translation, and every
    # mise override takes the same route.
    $env:MISE_CONFIG_DIR = 'C:\Users\alice\mise'
    $env:MISE_GLOBAL_CONFIG_FILE = 'C:\Users\alice\mise\config.toml'
    $env:MISE_SYSTEM_CONFIG_DIR = 'C:\ProgramData\mise'
    $env:WSLENV = 'MISE_GLOBAL_CONFIG_FILE/up:MISE_SYSTEM_CONFIG_DIR/pu:MISE_CONFIG_DIR/p'
    if (-not (Probe 'p-flag-combos' @{
      Dir = '\\wsl$\Ubuntu\mnt\c\Users\alice\mise'
      Path = '\\wsl$\Ubuntu\mnt\c\Users\alice\mise\config.toml'
      System = '\\wsl$\Ubuntu\mnt\c\ProgramData\mise\miserc.toml'
    })) { return $false }
    # /w stays WSL -> Win32 only, so none of these reach the distro.
    $env:WSLENV = 'MISE_CONFIG_DIR/w:MISE_GLOBAL_CONFIG_FILE/w:MISE_SYSTEM_CONFIG_DIR/w:MISE_ENV/w'
    if (-not (Probe 'w-invisible' @{
      Dir = '\\wsl$\Ubuntu\home\alice\.config\mise'
      Path = '\\wsl$\Ubuntu\home\alice\.config\mise\config.toml'
      System = '\\wsl$\Ubuntu\etc\mise\miserc.toml'
      MiseEnv = $null
    })) { return $false }
    return $true
  } finally {
    foreach ($k in $keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
  }
}

T 'doctor blocks mise on an unwritable legacy config only when cleanup must rewrite it' {
  $h = NewHome
  $legacyDir = PathJoin $h 'AppData' 'Local' 'mise'
  try {
    if ($IsWindows) { return $true }
    New-Item -ItemType Directory -Force -Path $legacyDir | Out-Null
    $legacy = PathJoin $legacyDir 'config.toml'
    $extra = @{ LOCALAPPDATA = (PathJoin $h 'AppData' 'Local'); PMSEC_FAKE_SCOPES = "windows|$h|win32"; PMSEC_MISE_VERSION = '2026.11.0' }
    [System.IO.File]::WriteAllText($legacy, "[settings]`nexperimental = true`n")
    chmod 555 $legacyDir
    $d = (InvokePmsec $h $extra @('--doctor','--json','--tool','mise')).Out | ConvertFrom-Json
    if (-not $d.ok -or @($d.tools[0].blockedExtraPaths).Count -ne 0) { $script:LastFail = 'unmanaged legacy config blocked doctor'; return $false }
    chmod 755 $legacyDir
    [System.IO.File]::WriteAllText($legacy, "[settings]`nminimum_release_age = `"7d`"`n")
    chmod 555 $legacyDir
    $r = InvokePmsec $h $extra @('--doctor','--json','--tool','mise')
    $d = $r.Out | ConvertFrom-Json
    $t = $d.tools[0]
    if ($d.ok -or @($t.blockedExtraPaths).Count -ne 1 -or -not $t.parentWritable) { $script:LastFail = "doctor ignored unwritable managed legacy config`n$($r.Out)"; return $false }
    return $true
  } finally { if (-not $IsWindows -and (Test-Path -LiteralPath $legacyDir)) { chmod 755 $legacyDir }; Remove-Item -Recurse -Force -LiteralPath $h }
}

# ---------- summary ----------

Write-Host ""
Write-Host "$($script:Pass) passed, $($script:Fail) failed"
if ($script:Fail -gt 0) { exit 1 }
exit 0
