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

function InvokePmsec([string]$HomeDir, [hashtable]$Extra, [string[]]$Argv, [string]$ScriptPath = '') {
  $envKeys = @(
    'NPM_CONFIG_USERCONFIG','UV_CONFIG_FILE','BUN_CONFIG_FILE',
    'PMSEC_PNPM_CONFIG_FILE','PMSEC_PNPM_CONFIG_YAML',
    'YARN_RC_FILENAME','CARGO_HOME','MISE_GLOBAL_CONFIG_FILE',
    'MISE_CONFIG_DIR','MISE_ENV','MISE_SYSTEM_CONFIG_DIR',
    'AUBE_CONFIG_FILE','COMPOSER_HOME',
    'BUNDLE_USER_CONFIG','BUNDLE_USER_HOME',
    'APPDATA','LOCALAPPDATA','XDG_CONFIG_HOME',
    'PMSEC_HOME','HOME','USERPROFILE','PMSEC_FAKE_SCOPES','PMSEC_NO_WSL',
    'PMSEC_FAKE_SCOPE_DATA',
    'PMSEC_NPM_VERSION','PMSEC_PNPM_VERSION','PMSEC_YARN_VERSION',
    'PMSEC_BUN_VERSION','PMSEC_CARGO_VERSION','PMSEC_MISE_VERSION','PMSEC_UV_VERSION',
    'PMSEC_AUBE_VERSION',
    'PMSEC_BUNDLER_VERSION','PMSEC_COMPOSER_VERSION'
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
  $target = if ($ScriptPath) { $ScriptPath } else { $Pmsec }
  try {
    $stdout = (& $PwshExe -NoProfile -File $target @Argv 2>$errFile | Out-String)
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

function AssertEq([string]$Label, [string]$Expected, [string]$Actual) {
  if ($Expected -ceq $Actual) { return $true }
  $script:LastFail = "$Label`n  expected: $Expected`n  actual:   $Actual"
  return $false
}

# Replaces a temp home with <HOME> and normalizes newlines so two runs in
# different sandboxes can be compared byte for byte.
function NormalizeHome([string]$Text, [string]$HomeDir) {
  if ($null -eq $Text) { return '' }
  $normalized = ($Text -replace [regex]::Escape($HomeDir), '<HOME>') -replace "`r`n", "`n"
  return $normalized
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

# ---------- production functions, loaded in-process ----------
# The mise-layering seams are pure (path family, mode gate, WSL path mapping,
# probe parsing), so they are unit tested directly. pmsec.ps1's dot-source guard
# keeps `. $Pmsec` from parsing argv, writing files, or exiting; every
# end-to-end assertion below still drives the real CLI as a child process.
. $Pmsec

# Fake-scope record ("one WSL distro stand-in", or a simulated Windows host)
# built through the production constructor so it carries the same fields.
function NewTestScope([string]$Label, [string]$ScopeHome, [string]$Platform) {
  return (New-ScopeRecord $Label $ScopeHome $Platform $true)
}

# Synthetic real-WSL scope: not fake, with a distro name and \\wsl$\<distro> root.
function NewWslTestScope([string]$Label, [string]$Distro) {
  $s = New-ScopeRecord $Label ('\\wsl$\' + $Distro + '\home\user') 'linux' $false
  $s.Distro = $Distro
  $s.WslRoot = '\\wsl$\' + $Distro
  return $s
}

# Baseline env for in-process seam tests: every mise variable cleared, the mise
# version pinned away from the host, and no fake scopes unless the case sets them.
function NewMiseEnvScrub {
  return @{
    'MISE_GLOBAL_CONFIG_FILE' = $null; 'MISE_CONFIG_DIR' = $null; 'XDG_CONFIG_HOME' = $null
    'MISE_SYSTEM_CONFIG_DIR' = $null; 'MISE_ENV' = $null
    'PMSEC_MISE_VERSION' = 'none'; 'PMSEC_FAKE_SCOPES' = $null; 'PMSEC_FAKE_SCOPE_DATA' = $null
  }
}

function InvokeWithEnv([hashtable]$Values, [scriptblock]$Body) {
  $saved = @{}
  foreach ($k in @($Values.Keys)) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
    [Environment]::SetEnvironmentVariable($k, $Values[$k], 'Process')
  }
  try { return (& $Body) } finally {
    foreach ($k in @($Values.Keys)) {
      [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process')
    }
  }
}

# PMSEC_FAKE_SCOPE_DATA payload for one scope label.
function NewFakeScopeData([string]$Label, [string]$Version, [hashtable]$ScopeEnv) {
  $entry = @{}
  if (-not [string]::IsNullOrEmpty($Version)) { $entry['Version'] = $Version }
  if ($null -ne $ScopeEnv) { $entry['Env'] = $ScopeEnv }
  $map = @{}
  $map[$Label] = $entry
  return ($map | ConvertTo-Json -Compress -Depth 6)
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

# ---------- mise layering: dot-source guard ----------

T 'dot-sourcing pmsec.ps1 defines functions without running the CLI' {
  $h = NewHome
  $harness = Join-Path $h 'harness.ps1'
  $errFile = [System.IO.Path]::GetTempFileName()
  $savedScopes = [Environment]::GetEnvironmentVariable('PMSEC_FAKE_SCOPES', 'Process')
  $savedVersion = [Environment]::GetEnvironmentVariable('PMSEC_MISE_VERSION', 'Process')
  try {
    $template = @'
. __PMSEC__
Write-Output ('fn=' + [bool](Get-Command Get-MiseScopeContext -ErrorAction Ignore))
Write-Output ('legacy=' + [bool](Get-Command Get-MisePathForScope -ErrorAction Ignore))
Write-Output ('ver=' + $script:PmsecVersion)
'@
    $quoted = "'" + $Pmsec.Replace("'", "''") + "'"
    [System.IO.File]::WriteAllText($harness, $template.Replace('__PMSEC__', $quoted))
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      # A scope pointing inside the sandbox: if the entry block ran, it would
      # write configs into $h before this harness could print anything.
      [Environment]::SetEnvironmentVariable('PMSEC_FAKE_SCOPES', "test|$h|linux", 'Process')
      [Environment]::SetEnvironmentVariable('PMSEC_MISE_VERSION', 'none', 'Process')
      $out = (& $PwshExe -NoProfile -File $harness 2>$errFile | Out-String)
      $code = $LASTEXITCODE
      $err = [System.IO.File]::ReadAllText($errFile)
    } finally {
      $ErrorActionPreference = $oldEAP
      [Environment]::SetEnvironmentVariable('PMSEC_FAKE_SCOPES', $savedScopes, 'Process')
      [Environment]::SetEnvironmentVariable('PMSEC_MISE_VERSION', $savedVersion, 'Process')
    }
    if ($code -ne 0) { $script:LastFail = "harness exit $code`n$out`n$err"; return $false }
    if ($err.Trim() -ne '') { $script:LastFail = "sourcing wrote stderr:`n$err"; return $false }
    $expected = "fn=True`nlegacy=True`nver=2026.11.8`n"
    if (-not (AssertEq 'sourcing output' $expected (NormalizeHome ([string]$out) $h))) { return $false }
    $left = @(Get-ChildItem -LiteralPath $h -Force)
    if ($left.Count -ne 1) {
      $names = ($left | ForEach-Object { $_.Name }) -join ','
      $script:LastFail = "sourcing executed the CLI: extra files in the sandbox home ($names)"
      return $false
    }
    return $true
  } finally {
    Remove-Item -Force -LiteralPath $errFile -ErrorAction Ignore
    Remove-Item -Recurse -Force -LiteralPath $h
  }
}

T 'the dot-source guard leaves -File invocations byte-identical' {
  $h1 = NewHome
  $h2 = NewHome
  try {
    $source = [System.IO.File]::ReadAllText($Pmsec)
    $guard = "if (`$MyInvocation.InvocationName -ne '.') {"
    if (-not $source.Contains($guard)) { $script:LastFail = 'entry guard not found in pmsec.ps1'; return $false }
    # Same file with the guard made unconditional == the pre-guard script.
    $unguarded = Join-Path $h2 'pmsec-unguarded.ps1'
    [System.IO.File]::WriteAllText($unguarded, $source.Replace($guard, 'if ($true) {'))
    $runs = @(
      @('--version'),
      @('--tool','mise','--days','7'),
      @('--check','--json','--tool','mise'),
      @('--disable','--tool','mise')
    )
    foreach ($argv in $runs) {
      $a = InvokePmsec $h1 $null $argv
      $b = InvokePmsec $h2 $null $argv -ScriptPath $unguarded
      $label = ($argv -join ' ')
      if ($a.Code -ne $b.Code) { $script:LastFail = "exit code differs for '$label': $($a.Code) vs $($b.Code)"; return $false }
      if (-not (AssertEq "stdout: $label" (NormalizeHome ([string]$a.Out) $h1) (NormalizeHome ([string]$b.Out) $h2))) { return $false }
      if (-not (AssertEq "stderr: $label" (NormalizeHome ([string]$a.Err) $h1) (NormalizeHome ([string]$b.Err) $h2))) { return $false }
    }
    $f1 = PathJoin $h1 '.config' 'mise' 'config.toml'
    $f2 = PathJoin $h2 '.config' 'mise' 'config.toml'
    if (-not (Test-Path -LiteralPath $f1) -or -not (Test-Path -LiteralPath $f2)) {
      $script:LastFail = 'guarded and unguarded runs did not write the same mise config'
      return $false
    }
    return (AssertEq 'mise config bytes' ([System.IO.File]::ReadAllText($f1)) ([System.IO.File]::ReadAllText($f2)))
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $h1
    Remove-Item -Recurse -Force -LiteralPath $h2
  }
}

# ---------- mise layering: legacy paths ----------

T 'win32 legacy mise path keeps LOCALAPPDATA and the MISE_GLOBAL_CONFIG_FILE override' {
  $h = NewHome
  try {
    $local = PathJoin $h 'localappdata'
    $winScope = "windows|$h|win32"
    $r = InvokePmsec $h @{ LOCALAPPDATA = $local; PMSEC_FAKE_SCOPES = $winScope } @('--tool','mise')
    if ($r.Code -ne 0) { $script:LastFail = "enable exit $($r.Code)`n$($r.Err)"; return $false }
    if (-not (Test-Path -LiteralPath (PathJoin $local 'mise' 'config.toml'))) {
      $script:LastFail = "win32 mise config not under LOCALAPPDATA`n$($r.Out)"
      return $false
    }
    $pinned = PathJoin $h 'pinned' 'mise.toml'
    $r = InvokePmsec $h @{ LOCALAPPDATA = $local; MISE_GLOBAL_CONFIG_FILE = $pinned; PMSEC_FAKE_SCOPES = $winScope } @('--tool','mise','--days','2')
    if ($r.Code -ne 0) { $script:LastFail = "pinned enable exit $($r.Code)`n$($r.Err)"; return $false }
    if (-not (Test-Path -LiteralPath $pinned)) { $script:LastFail = "pinned mise config missing: $pinned`n$($r.Out)"; return $false }
    return (AssertMatch 'pinned cooldown' '(?m)^minimum_release_age = "2d"$' ([System.IO.File]::ReadAllText($pinned)))
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'fake linux scope honors a scoped MISE_GLOBAL_CONFIG_FILE for the legacy path' {
  $h = NewHome
  try {
    $pinned = PathJoin $h 'custom' 'mise.toml'
    $r = InvokePmsec $h @{ MISE_GLOBAL_CONFIG_FILE = $pinned } @('--tool','mise')
    if ($r.Code -ne 0) { $script:LastFail = "enable exit $($r.Code)`n$($r.Err)"; return $false }
    if (-not (Test-Path -LiteralPath $pinned)) { $script:LastFail = "scoped override ignored, expected $pinned`n$($r.Out)"; return $false }
    if (Test-Path -LiteralPath (PathJoin $h '.config' 'mise' 'config.toml')) {
      $script:LastFail = 'enable also wrote the default path for an overridden scope'
      return $false
    }
    $c = InvokePmsec $h @{ MISE_GLOBAL_CONFIG_FILE = $pinned } @('--check','--json','--tool','mise')
    $row = ($c.Out | ConvertFrom-Json).rows[0]
    if (-not (AssertEq 'check path' $pinned ([string]$row.path))) { return $false }
    return (AssertEq 'check days' '1' ([string]$row.days))
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'fake linux scope honors a scoped XDG_CONFIG_HOME for the legacy path' {
  $h = NewHome
  try {
    $xdg = PathJoin $h 'xdg'
    $r = InvokePmsec $h @{ XDG_CONFIG_HOME = $xdg } @('--tool','mise')
    if ($r.Code -ne 0) { $script:LastFail = "enable exit $($r.Code)`n$($r.Err)"; return $false }
    if (-not (Test-Path -LiteralPath (PathJoin $xdg 'mise' 'config.toml'))) {
      $script:LastFail = "XDG override ignored`n$($r.Out)"
      return $false
    }
    if (Test-Path -LiteralPath (PathJoin $h '.config' 'mise' 'config.toml')) {
      $script:LastFail = 'enable also wrote ~/.config/mise for an XDG scope'
      return $false
    }
    return (AssertEq 'enable line' ('enable  mise [' + (PathJoin $xdg 'mise' 'config.toml') + ']') ([string]$r.Out).Trim())
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

T 'empty scoped MISE_GLOBAL_CONFIG_FILE and XDG_CONFIG_HOME mean unset' {
  $h = NewHome
  try {
    $r = InvokePmsec $h @{ MISE_GLOBAL_CONFIG_FILE = ''; XDG_CONFIG_HOME = '' } @('--tool','mise')
    if ($r.Code -ne 0) { $script:LastFail = "enable exit $($r.Code)`n$($r.Err)"; return $false }
    $default = PathJoin $h '.config' 'mise' 'config.toml'
    if (-not (Test-Path -LiteralPath $default)) { $script:LastFail = "expected the default path $default`n$($r.Out)"; return $false }
    return (AssertEq 'enable line' ('enable  mise [' + $default + ']') ([string]$r.Out).Trim())
  } finally { Remove-Item -Recurse -Force -LiteralPath $h }
}

# ---------- mise layering: new path family ----------

T 'new path family: MISE_CONFIG_DIR beats XDG beats ~/.config/mise on every platform' {
  $linux = NewTestScope 'linux' '/home/user' 'linux'
  $ok = $true

  $p = Resolve-MiseNewPaths $linux @{ MISE_CONFIG_DIR = '/mise'; XDG_CONFIG_HOME = '/xdg' } ''
  $ok = $ok -and (AssertEq 'config-dir wins' '/mise' $p['MiseDir'])
  $ok = $ok -and (AssertEq 'config-dir base' '/mise/config.toml' $p['BaseConfig'])
  $ok = $ok -and (AssertEq 'config-dir pmsec' '/mise/config.pmsec.toml' $p['PmsecConfig'])
  $ok = $ok -and (AssertEq 'config-dir local miserc' '/mise/miserc.local.toml' $p['LocalMiserc'])
  $ok = $ok -and (AssertEq 'config-dir shared miserc' '/mise/miserc.toml' $p['SharedMiserc'])
  $ok = $ok -and (AssertEq 'config-dir no error' '' $p['Error'])
  if (-not $ok) { return $false }

  $p = Resolve-MiseNewPaths $linux @{ XDG_CONFIG_HOME = '/xdg' } ''
  $ok = (AssertEq 'xdg mise dir' '/xdg/mise' $p['MiseDir'])
  $ok = $ok -and (AssertEq 'xdg pmsec config' '/xdg/mise/config.pmsec.toml' $p['PmsecConfig'])
  $ok = $ok -and (AssertEq 'xdg shared miserc' '/xdg/mise/miserc.toml' $p['SharedMiserc'])
  if (-not $ok) { return $false }

  $p = Resolve-MiseNewPaths $linux @{ MISE_CONFIG_DIR = ''; XDG_CONFIG_HOME = '' } ''
  $ok = AssertEq 'empty overrides fall through' '/home/user/.config/mise' $p['MiseDir']
  if (-not $ok) { return $false }

  # win32: the new directory is ~/.config/mise, never %LOCALAPPDATA%.
  $win = NewTestScope 'windows' 'C:\Users\user' 'win32'
  $p = Resolve-MiseNewPaths $win @{ LOCALAPPDATA = 'C:\Users\user\AppData\Local' } 'D:\'
  $ok = (AssertEq 'win32 mise dir' 'C:\Users\user\.config\mise' $p['MiseDir'])
  $ok = $ok -and (AssertEq 'win32 base config' 'C:\Users\user\.config\mise\config.toml' $p['BaseConfig'])
  $ok = $ok -and (AssertEq 'win32 local miserc' 'C:\Users\user\.config\mise\miserc.local.toml' $p['LocalMiserc'])
  if ($p['MiseDir'] -match 'AppData') { $script:LastFail = 'LOCALAPPDATA leaked into the new mise dir'; return $false }
  if (-not $ok) { return $false }

  $p = Resolve-MiseNewPaths $win @{ MISE_CONFIG_DIR = 'C:\mise'; XDG_CONFIG_HOME = 'C:\xdg' } 'D:\'
  $ok = (AssertEq 'win32 config dir wins' 'C:\mise' $p['MiseDir'])
  $ok = $ok -and (AssertEq 'win32 config dir pmsec' 'C:\mise\config.pmsec.toml' $p['PmsecConfig'])
  return $ok
}

T 'new path family: system miserc override, defaults and the injected drive root' {
  $linux = NewTestScope 'linux' '/home/user' 'linux'
  $win = NewTestScope 'windows' 'C:\Users\user' 'win32'
  $ok = $true

  $p = Resolve-MiseNewPaths $linux @{ MISE_SYSTEM_CONFIG_DIR = '/opt/mise' } ''
  $ok = $ok -and (AssertEq 'linux system override' '/opt/mise/miserc.toml' $p['SystemMiserc'])
  $p = Resolve-MiseNewPaths $linux @{ MISE_SYSTEM_CONFIG_DIR = '' } ''
  $ok = $ok -and (AssertEq 'empty system dir falls through' '/etc/mise/miserc.toml' $p['SystemMiserc'])
  if (-not $ok) { return $false }

  $p = Resolve-MiseNewPaths $win @{} 'D:\'
  $ok = AssertEq 'win32 drive root' 'D:\etc\mise\miserc.toml' $p['SystemMiserc']
  $p = Resolve-MiseNewPaths $win @{} 'C:\'
  $ok = $ok -and (AssertEq 'win32 other drive root' 'C:\etc\mise\miserc.toml' $p['SystemMiserc'])
  $p = Resolve-MiseNewPaths $win @{} ''
  $ok = $ok -and (AssertEq 'win32 drive-less root' '\etc\mise\miserc.toml' $p['SystemMiserc'])
  $p = Resolve-MiseNewPaths $win @{ MISE_SYSTEM_CONFIG_DIR = 'C:\ProgramData\mise' } 'D:\'
  $ok = $ok -and (AssertEq 'win32 system override beats drive root' 'C:\ProgramData\mise\miserc.toml' $p['SystemMiserc'])
  # The system location never derives from the user profile or SystemDrive.
  $p = Resolve-MiseNewPaths $win @{ USERPROFILE = 'C:\Users\user'; SystemDrive = 'E:' } 'D:\'
  $ok = $ok -and (AssertEq 'win32 system ignores profile/SystemDrive' 'D:\etc\mise\miserc.toml' $p['SystemMiserc'])
  return $ok
}

T 'new path family: real WSL scopes map every path through \\wsl$\<distro>' {
  $wsl = NewWslTestScope 'wsl-Ubuntu' 'Ubuntu'
  $ok = $true

  $p = Resolve-MiseNewPaths $wsl @{} ''
  $ok = $ok -and (AssertEq 'wsl mise dir' '\\wsl$\Ubuntu\home\user\.config\mise' $p['MiseDir'])
  $ok = $ok -and (AssertEq 'wsl base config' '\\wsl$\Ubuntu\home\user\.config\mise\config.toml' $p['BaseConfig'])
  $ok = $ok -and (AssertEq 'wsl pmsec config' '\\wsl$\Ubuntu\home\user\.config\mise\config.pmsec.toml' $p['PmsecConfig'])
  $ok = $ok -and (AssertEq 'wsl local miserc' '\\wsl$\Ubuntu\home\user\.config\mise\miserc.local.toml' $p['LocalMiserc'])
  $ok = $ok -and (AssertEq 'wsl shared miserc' '\\wsl$\Ubuntu\home\user\.config\mise\miserc.toml' $p['SharedMiserc'])
  $ok = $ok -and (AssertEq 'wsl system miserc' '\\wsl$\Ubuntu\etc\mise\miserc.toml' $p['SystemMiserc'])
  $ok = $ok -and (AssertEq 'wsl no error' '' $p['Error'])
  if (-not $ok) { return $false }

  $p = Resolve-MiseNewPaths $wsl @{ MISE_CONFIG_DIR = '/opt/mise'; MISE_SYSTEM_CONFIG_DIR = '/opt/sys' } ''
  $ok = (AssertEq 'wsl config dir override' '\\wsl$\Ubuntu\opt\mise' $p['MiseDir'])
  $ok = $ok -and (AssertEq 'wsl system override' '\\wsl$\Ubuntu\opt\sys\miserc.toml' $p['SystemMiserc'])
  if (-not $ok) { return $false }

  $p = Resolve-MiseNewPaths $wsl @{ XDG_CONFIG_HOME = '/xdg' } ''
  return (AssertEq 'wsl xdg' '\\wsl$\Ubuntu\xdg\mise' $p['MiseDir'])
}

T 'WSL legacy path resolves from the distro environment as UNC' {
  $cached = @{ Values = @{ MISE_GLOBAL_CONFIG_FILE = '/custom/mise.toml' }; Error = $null }
  $wsl = NewWslTestScope 'wsl-Ubuntu' 'Ubuntu'
  $wsl['Environment'] = $cached
  $ctx = Get-MiseScopeContext $wsl
  $ok = AssertEq 'wsl legacy override' '\\wsl$\Ubuntu\custom\mise.toml' $ctx['Paths']['LegacyConfig']
  # A pinned legacy file rules out the layered layout, exactly like on Windows.
  $ok = $ok -and (AssertEq 'wsl override forces legacy mode' 'False' ([string]$ctx['SupportsNewMode']))
  if (-not $ok) { return $false }

  $wsl = NewWslTestScope 'wsl-Ubuntu' 'Ubuntu'
  $wsl['Environment'] = @{ Values = @{ XDG_CONFIG_HOME = '/xdg' }; Error = $null }
  $ctx = Get-MiseScopeContext $wsl
  return (AssertEq 'wsl legacy xdg' '\\wsl$\Ubuntu\xdg\mise\config.toml' $ctx['Paths']['LegacyConfig'])
}

T 'Convert-WslPosixPath rejects anything that is not a plain absolute POSIX path' {
  $wsl = NewWslTestScope 'wsl-Ubuntu' 'Ubuntu'
  $fake = NewTestScope 'test' '/home/user' 'linux'
  $nul = [string][char]0
  $ok = AssertEq 'accepts a config dir' '\\wsl$\Ubuntu\home\user\.config\mise' (Convert-WslPosixPath $wsl '/home/user/.config/mise')
  $ok = $ok -and (AssertEq 'accepts the distro root' '\\wsl$\Ubuntu' (Convert-WslPosixPath $wsl '/'))
  $ok = $ok -and (AssertEq 'collapses duplicate slashes' '\\wsl$\Ubuntu\a\b' (Convert-WslPosixPath $wsl '/a//b'))
  if (-not $ok) { return $false }

  # Built as variables: `+` next to a comma-separated list would coerce the
  # rest of the array into one string (PowerShell gives ',' higher precedence).
  $newlinePath = '/a/' + "`n" + 'b'
  $nulPath = '/a/' + $nul + 'b'
  $rejected = @(
    'relative/path',
    'rel.txt',
    'C:\Users\user',
    'C:/Users/user',
    '\\server\share',
    '//server/share',
    '/a/../b',
    '/a/./b',
    '/../etc/passwd',
    $newlinePath,
    $nulPath,
    'back\slash',
    ''
  )
  foreach ($raw in $rejected) {
    $label = $raw -replace '[\x00-\x1F]', '<ctl>'
    $mapped = Convert-WslPosixPath $wsl $raw
    if ($null -ne $mapped) {
      $script:LastFail = "accepted an unsafe WSL path ($label) as $mapped"
      return $false
    }
  }
  # Fake scopes never get UNC translation: their paths stay host paths.
  if ($null -ne (Convert-WslPosixPath $fake '/home/user/.config/mise')) {
    $script:LastFail = 'fake scopes must not be translated to UNC paths'
    return $false
  }
  # A root that is not \\wsl$\<distro> is unusable.
  $bad = NewWslTestScope 'wsl-bad' 'Ubuntu'
  $bad.WslRoot = '\\wsl$\Bad\deep'
  return (AssertEq 'malformed wsl root rejected' '' (Convert-WslPosixPath $bad '/etc/mise'))
}

T 'unusable scoped paths fail safe instead of throwing' {
  # An override that cannot be addressed on this host.
  $wsl = NewWslTestScope 'wsl-Ubuntu' 'Ubuntu'
  $wsl['Environment'] = @{ Values = @{ MISE_CONFIG_DIR = 'relative/dir' }; Error = $null }
  $ctx = Get-MiseScopeContext $wsl
  if ([string]::IsNullOrEmpty($ctx['Error'])) { $script:LastFail = 'expected an error for an unusable MISE_CONFIG_DIR'; return $false }
  $ok = AssertEq 'falls back to the default dir' '\\wsl$\Ubuntu\home\user\.config\mise' $ctx['Paths']['MiseDir']
  $ok = $ok -and (AssertEq 'unusable path stays legacy' 'False' ([string]$ctx['SupportsNewMode']))
  if (-not $ok) { return $false }

  # A failed distro probe (no such distro on this host) degrades to legacy too.
  $probe = NewWslTestScope 'wsl-PmsecNoSuchDistro' 'PmsecNoSuchDistro'
  $ctx = Get-MiseScopeContext $probe
  if ([string]::IsNullOrEmpty($ctx['Error'])) { $script:LastFail = 'expected an error for a failed WSL probe'; return $false }
  $ok = AssertEq 'failed probe stays legacy' 'False' ([string]$ctx['SupportsNewMode'])
  $ok = $ok -and (AssertEq 'failed probe keeps an empty environment' '0' ([string]$ctx['Environment'].Count))
  return $ok
}

# ---------- mise layering: mode gate ----------

T 'mode matrix: only mise >= 2026.11.0 without MISE_GLOBAL_CONFIG_FILE enables the new mode' {
  $matrix = @(
    @{ Version = '2026.11.0';  Override = 'absent'; Expect = $true  },
    @{ Version = '2026.11.0';  Override = '';       Expect = $true  },
    @{ Version = '2026.11.0';  Override = 'pinned'; Expect = $false },
    @{ Version = '2026.12.0';  Override = 'absent'; Expect = $true  },
    @{ Version = '2026.10.25'; Override = 'absent'; Expect = $false },
    @{ Version = '2026.10.25'; Override = '';       Expect = $false },
    @{ Version = '2026.4.21';  Override = 'absent'; Expect = $false },
    @{ Version = 'none';       Override = 'absent'; Expect = $false },
    @{ Version = '2026.11';    Override = 'absent'; Expect = $false },
    @{ Version = 'garbage';    Override = 'absent'; Expect = $false }
  )
  foreach ($case in $matrix) {
    $scopeEnv = $null
    if ($case.Override -ne 'absent') {
      $value = ''
      if ($case.Override -eq 'pinned') { $value = '/pinned/mise.toml' }
      $scopeEnv = @{ 'MISE_GLOBAL_CONFIG_FILE' = $value }
    }
    $envMap = NewMiseEnvScrub
    $envMap['PMSEC_FAKE_SCOPES'] = 'mode|/home/user|linux'
    $envMap['PMSEC_FAKE_SCOPE_DATA'] = (NewFakeScopeData 'mode' $case.Version $scopeEnv)
    $got = InvokeWithEnv $envMap {
      $scopes = Get-PmsecScopes $true
      (Get-MiseScopeContext ($scopes[0]))['SupportsNewMode']
    }
    if ([bool]$got -ne [bool]$case.Expect) {
      $script:LastFail = ("version=$($case.Version) override=$($case.Override): expected $($case.Expect), got $got")
      return $false
    }
  }
  return $true
}

T 'the WSL environment probe parser fails safe on corrupted output' {
  $b = [string][char]1 + 'B'
  $e = [string][char]1 + 'E'
  $sep = [string][char]2
  # Field order is MISE_GLOBAL_CONFIG_FILE, MISE_CONFIG_DIR, XDG_CONFIG_HOME,
  # MISE_SYSTEM_CONFIG_DIR, MISE_ENV; printenv prints nothing for unset vars.
  $good = $b + $sep + "/custom/mise.toml`n" + $sep + "`n" + $sep + "/xdg`n" + $sep + "`n" + $sep + "work`n" + $e
  $values = ConvertFrom-WslEnvProbe $good
  if ($null -eq $values) { $script:LastFail = 'rejected a well-formed probe'; return $false }
  $ok = AssertEq 'global config' '/custom/mise.toml' $values['MISE_GLOBAL_CONFIG_FILE']
  $ok = $ok -and (AssertEq 'xdg' '/xdg' $values['XDG_CONFIG_HOME'])
  $ok = $ok -and (AssertEq 'mise env' 'work' $values['MISE_ENV'])
  $ok = $ok -and (AssertEq 'unset field stays out' '' ([string]$values['MISE_CONFIG_DIR']))
  if (-not $ok) { return $false }

  $newlineInsideValue = $b + $sep + "/a`nb`n" + $sep + "`n" + $sep + "`n" + $sep + "`n" + $sep + "`n" + $e
  $noSentinels = "/custom/mise.toml`n" + $sep + "`n" + $sep + "`n" + $sep + "`n" + $sep + "`n"
  $tooFewFields = $b + $sep + "only-one-field`n" + $e
  $corrupted = @($newlineInsideValue, $noSentinels, $tooFewFields, '')
  foreach ($text in $corrupted) {
    if ($null -ne (ConvertFrom-WslEnvProbe $text)) {
      $script:LastFail = 'accepted a corrupted WSL environment probe'
      return $false
    }
  }
  return $true
}

T 'malformed PMSEC_FAKE_SCOPE_DATA is ignored instead of throwing' {
  $broken = @(
    '{"mode": {"Env": {"MISE_CONFIG_DIR": "x"}',                  # truncated JSON
    '{"mode": {"Env": {"MISE_CONFIG_DIR": 42, "MISE_ENV": 0}}}',  # non-string values
    '{"mode": {"Version": 2026}}',                                # non-string version
    'not json at all'
  )
  foreach ($payload in $broken) {
    $envMap = NewMiseEnvScrub
    $envMap['PMSEC_FAKE_SCOPES'] = 'mode|/home/user|linux'
    $envMap['PMSEC_FAKE_SCOPE_DATA'] = $payload
    $facts = InvokeWithEnv $envMap {
      $scopes = Get-PmsecScopes $true
      $ctx = Get-MiseScopeContext ($scopes[0])
      @{
        Supports = [string]$ctx['SupportsNewMode']
        EnvKeys = (($ctx['Environment'].Keys | Sort-Object) -join ',')
        Dir = $ctx['Paths']['MiseDir']
        Error = [string]$ctx['Error']
      }
    }
    if (-not (AssertEq "stays legacy ($payload)" 'False' $facts['Supports'])) { return $false }
    if (-not (AssertEq "no injected env ($payload)" '' $facts['EnvKeys'])) { return $false }
    if (-not (AssertEq "default mise dir ($payload)" '/home/user/.config/mise' $facts['Dir'])) { return $false }
    if (-not (AssertEq "no probe error ($payload)" '' $facts['Error'])) { return $false }
  }
  return $true
}

T 'mixed scopes keep version and environment per scope, with no leakage' {
  $h = NewHome
  try {
    $local = PathJoin $h 'localappdata'
    $data = @{}
    $data['windows'] = @{ Version = '2026.11.0' }
    $data['wsl-Ubuntu'] = @{ Version = '2026.10.25' }
    $data['wsl-Debian'] = @{ Version = '2026.11.0'; Env = @{ MISE_GLOBAL_CONFIG_FILE = '/custom/debian.toml'; MISE_ENV = 'work' } }
    $scopes = "windows|$h|win32;wsl-Ubuntu|\\wsl`$\Ubuntu\home\u|linux;wsl-Debian|\\wsl`$\Debian\home\u|linux;wsl-Unknown|\\wsl`$\Unknown\home\u|linux"
    $envMap = NewMiseEnvScrub
    $envMap['LOCALAPPDATA'] = $local
    $envMap['PMSEC_FAKE_SCOPES'] = $scopes
    $envMap['PMSEC_FAKE_SCOPE_DATA'] = ($data | ConvertTo-Json -Compress -Depth 6)
    $facts = InvokeWithEnv $envMap {
      $result = @{}
      foreach ($scope in (Get-PmsecScopes $true)) {
        $ctx = Get-MiseScopeContext $scope
        $again = Get-MiseScopeContext $scope
        $raw = ''
        if ($null -ne $ctx['Version']) { $raw = [string]$ctx['Version']['Raw'] }
        $global = ''
        $globalValue = $ctx['Environment']['MISE_GLOBAL_CONFIG_FILE']
        if ($null -ne $globalValue) { $global = [string]$globalValue }
        $miseEnv = ''
        $miseEnvValue = $ctx['Environment']['MISE_ENV']
        if ($null -ne $miseEnvValue) { $miseEnv = [string]$miseEnvValue }
        $result[$scope.Label] = @{
          Supports = [string]$ctx['SupportsNewMode']
          Version = $raw
          Global = $global
          MiseEnv = $miseEnv
          Cached = [string][object]::ReferenceEquals($ctx, $again)
        }
      }
      $result
    }
    $ok = AssertEq 'windows uses the new mode' 'True' $facts['windows']['Supports']
    $ok = $ok -and (AssertEq 'windows sees no global override' '' $facts['windows']['Global'])
    $ok = $ok -and (AssertEq 'windows version' '2026.11.0' $facts['windows']['Version'])
    $ok = $ok -and (AssertEq 'ubuntu stays legacy' 'False' $facts['wsl-Ubuntu']['Supports'])
    $ok = $ok -and (AssertEq 'ubuntu version' '2026.10.25' $facts['wsl-Ubuntu']['Version'])
    $ok = $ok -and (AssertEq 'ubuntu sees no global override' '' $facts['wsl-Ubuntu']['Global'])
    $ok = $ok -and (AssertEq 'debian override keeps legacy' 'False' $facts['wsl-Debian']['Supports'])
    $ok = $ok -and (AssertEq 'debian version' '2026.11.0' $facts['wsl-Debian']['Version'])
    $ok = $ok -and (AssertEq 'debian global override' '/custom/debian.toml' $facts['wsl-Debian']['Global'])
    $ok = $ok -and (AssertEq 'debian MISE_ENV' 'work' $facts['wsl-Debian']['MiseEnv'])
    $ok = $ok -and (AssertEq 'debian env did not leak to ubuntu' '' $facts['wsl-Ubuntu']['MiseEnv'])
    $ok = $ok -and (AssertEq 'debian env did not leak to windows' '' $facts['windows']['MiseEnv'])
    $ok = $ok -and (AssertEq 'unknown version stays legacy' 'False' $facts['wsl-Unknown']['Supports'])
    $ok = $ok -and (AssertEq 'unknown version is unknown' '' $facts['wsl-Unknown']['Version'])
    $ok = $ok -and (AssertEq 'windows context cached' 'True' $facts['windows']['Cached'])
    $ok = $ok -and (AssertEq 'debian context cached' 'True' $facts['wsl-Debian']['Cached'])
    return $ok
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $h
  }
}

# ---------- mise layering: narrow miserc env helper ----------
# Pure text helpers, so everything is asserted in process: the accepted subset,
# the decoded names, the exact replaced range, and every frozen rejection
# reason. Nothing here touches the filesystem.

$script:NL = [string][char]10
$script:DQ = [string][char]34
$script:SQ = [string][char]39

# Joins lines with LF and adds the final newline, so a multi-line case reads
# like the miserc file it models.
function MisercText([string[]]$Lines) {
  return (($Lines -join $script:NL) + $script:NL)
}

function DqName([string]$Name) { return ($script:DQ + $Name + $script:DQ) }
function SqName([string]$Name) { return ($script:SQ + $Name + $script:SQ) }
function MisercArray([string[]]$Tokens) { return ('env = [' + ($Tokens -join ', ') + ']') }

function ReadMiserc([string]$Text) { return (Read-MisercEnv -Text $Text -Path 'miserc.local.toml') }
function WriteMiserc([string]$Text, [string[]]$Inherited) {
  return (Update-MisercEnvText -Text $Text -Inherited $Inherited -Path 'miserc.local.toml')
}
function FormatMisercNames($Result) { return ((@($Result['Env'])) -join '|') }

function AssertMisercUndefined([string]$Label, [string]$Text) {
  $r = ReadMiserc $Text
  $ok = AssertEq ($Label + ': ok') 'True' ([string]$r['Ok'])
  $ok = $ok -and (AssertEq ($Label + ': defined') 'False' ([string]$r['Defined']))
  $ok = $ok -and (AssertEq ($Label + ': names') '' (FormatMisercNames $r))
  $ok = $ok -and (AssertEq ($Label + ': start') '-1' ([string]$r['Start']))
  $ok = $ok -and (AssertEq ($Label + ': reason') '' ([string]$r['Reason']))
  return ($ok -and (AssertEq ($Label + ': end') '-1' ([string]$r['End'])))
}

function AssertMisercNames([string]$Label, [string]$Text, [string]$Expected) {
  $r = ReadMiserc $Text
  $ok = AssertEq ($Label + ': ok') 'True' ([string]$r['Ok'])
  $ok = $ok -and (AssertEq ($Label + ': defined') 'True' ([string]$r['Defined']))
  $ok = $ok -and (AssertEq ($Label + ': reason') '' ([string]$r['Reason']))
  return ($ok -and (AssertEq ($Label + ': names') $Expected (FormatMisercNames $r)))
}

function AssertMisercReject([hashtable]$Case) {
  $r = ReadMiserc $Case['T']
  $ok = AssertEq ($Case['N'] + ': ok') 'False' ([string]$r['Ok'])
  $ok = $ok -and (AssertEq ($Case['N'] + ': reason') $Case['R'] ([string]$r['Reason']))
  $ok = $ok -and (AssertEq ($Case['N'] + ': defined') 'False' ([string]$r['Defined']))
  $ok = $ok -and (AssertEq ($Case['N'] + ': names') '' (FormatMisercNames $r))
  $ok = $ok -and (AssertEq ($Case['N'] + ': start') '-1' ([string]$r['Start']))
  return ($ok -and (AssertEq ($Case['N'] + ': end') '-1' ([string]$r['End'])))
}

function AssertMisercRejects($Cases) {
  $ok = $true
  foreach ($case in $Cases) { $ok = $ok -and (AssertMisercReject $case) }
  return $ok
}

function AssertMisercWrite([string]$Label, [string]$Text, [string[]]$Inherited, [string]$Expected) {
  $r = WriteMiserc $Text $Inherited
  $ok = AssertEq ($Label + ': ok') 'True' ([string]$r['Ok'])
  $ok = $ok -and (AssertEq ($Label + ': reason') '' ([string]$r['Reason']))
  return ($ok -and (AssertEq ($Label + ': text') $Expected ([string]$r['Text'])))
}

function AssertMisercWriteReject([string]$Label, [string]$Text, [string[]]$Inherited, [string]$Reason) {
  $r = WriteMiserc $Text $Inherited
  $ok = AssertEq ($Label + ': ok') 'False' ([string]$r['Ok'])
  $ok = $ok -and (AssertEq ($Label + ': reason') $Reason ([string]$r['Reason']))
  $ok = $ok -and (AssertEq ($Label + ': text') '' ([string]$r['Text']))
  if ($null -ne $r['Text']) { $script:LastFail = ($Label + ': the error result still carries text'); return $false }
  return $ok
}

T 'miserc read: no top-level env assignment reads as not defined' {
  $cases = @(
    @{ N = 'empty file'; T = '' },
    @{ N = 'unrelated keys'; T = (MisercText @('minimum_release_age = "1d"', 'experimental = true')) },
    @{ N = 'envelope lookalikes'; T = (MisercText @('envelope = true', 'envoy = 1')) },
    @{ N = 'env table only'; T = (MisercText @('[env]', 'a = 1')) },
    @{ N = 'dotted env only'; T = (MisercText @('env.foo = 1')) },
    @{ N = 'env inside a table'; T = (MisercText @('[tools]', (MisercArray @((DqName 'a'))))) },
    @{ N = 'commented out'; T = (MisercText @('# env = ["a"]', '#env = ["b"]')) }
  )
  $ok = $true
  foreach ($case in $cases) { $ok = $ok -and (AssertMisercUndefined $case['N'] $case['T']) }
  return $ok
}

T 'miserc read: inline and empty arrays decode to names' {
  $ok = AssertMisercNames 'empty array' (MisercText @('env = []')) ''
  $ok = $ok -and (AssertMisercNames 'comments only' (MisercText @('env = [ # nothing here', ']')) '')
  $ok = $ok -and (AssertMisercNames 'one inline' ((MisercArray @((DqName 'work')))) 'work')
  $ok = $ok -and (AssertMisercNames 'three inline' ((MisercArray @((DqName 'a'), (SqName 'b'), (DqName 'c')))) 'a|b|c')
  $ok = $ok -and (AssertMisercNames 'no spaces' 'env=["a","b"]' 'a|b')
  $ok = $ok -and (AssertMisercNames 'padded brackets' 'env = [   "a"   ,   "b"   ]' 'a|b')
  return $ok
}

T 'miserc read: a multiline array keeps offsets that slice back to the assignment' {
  $text = MisercText @(
    '# leading comment',
    '  env = [',
    '    ' + (DqName 'a') + ', # first',
    '    ' + (SqName 'b') + ',',
    '  ]  # trailing',
    '',
    '[tools]',
    'x = 1'
  )
  $r = ReadMiserc $text
  $ok = AssertEq 'ok' 'True' ([string]$r['Ok'])
  $ok = $ok -and (AssertEq 'defined' 'True' ([string]$r['Defined']))
  $ok = $ok -and (AssertEq 'names' 'a|b' (FormatMisercNames $r))
  $start = [int]$r['Start']
  $end = [int]$r['End']
  $expectedSlice = (@('env = [', '    ' + (DqName 'a') + ', # first', '    ' + (SqName 'b') + ',', '  ]') -join $script:NL)
  $ok = $ok -and (AssertEq 'slice' $expectedSlice $text.Substring($start, $end - $start))
  $expectedTail = ('  # trailing' + $script:NL + $script:NL + '[tools]' + $script:NL + 'x = 1' + $script:NL)
  return ($ok -and (AssertEq 'tail after end' $expectedTail $text.Substring($end)))
}

T 'miserc read: literal strings keep backslashes and quoted punctuation stays opaque' {
  $ok = AssertMisercNames 'literal backslash' ('env = [' + (SqName 'say\hi') + ']') 'say\hi'
  $ok = $ok -and (AssertMisercNames 'punctuation' ('env = [' + (DqName 'a#b, [c] = d') + ']') 'a#b, [c] = d')
  $ok = $ok -and (AssertMisercNames 'duplicates kept in order' ((MisercArray @((DqName 'a'), (SqName 'a'), (DqName 'a')))) 'a|a|a')
  return ($ok -and (AssertMisercNames 'trailing comma' ('env = [' + (DqName 'a') + ', ' + (DqName 'b') + ',]') 'a|b'))
}

T 'miserc read: env-like text inside comments, strings, and tables is unrelated' {
  $ok = AssertMisercUndefined 'single-line string value' (MisercText @('note = "env = x"'))
  $ok = $ok -and (AssertMisercUndefined 'brackets in a string value' (MisercText @('note = "[env]"')))
  $ok = $ok -and (AssertMisercUndefined 'multiline string body' (MisercText @('note = """', (MisercArray @((DqName 'inner'))), '"""')))
  $ok = $ok -and (AssertMisercUndefined 'literal multiline string body' (MisercText @("note = '''", (MisercArray @((SqName 'inner'))), "'''")))
  $ok = $ok -and (AssertMisercUndefined 'env after a table' (MisercText @('[tools]', (MisercArray @((DqName 'late'))), 'x = 1')))
  return $ok
}

T 'miserc read: a table header after a multiline string still ends the root region' {
  $text = MisercText @(
    'note = """',
    '[env]',
    '"""',
    '',
    'x = 1'
  )
  $ok = AssertMisercUndefined 'header inside the string is not a header' $text
  $withEnv = MisercText @(
    'note = """',
    '[env]',
    '"""',
    '',
    (MisercArray @((DqName 'real')))
  )
  return ($ok -and (AssertMisercNames 'env after the string is a real assignment' $withEnv 'real'))
}

T 'miserc read: quoted keys, duplicates, and shape errors fail closed' {
  $ok = AssertMisercRejects @(
    @{ N = 'double-quoted env key'; T = ((DqName 'env') + ' = [' + (DqName 'a') + ']'); R = 'quoted env key is unsupported' },
    @{ N = 'single-quoted env key'; T = ((SqName 'env') + ' = [' + (DqName 'a') + ']'); R = 'quoted env key is unsupported' },
    @{ N = 'duplicate assignment'; T = (MisercText @((MisercArray @((DqName 'a'))), (MisercArray @((DqName 'b'))))); R = 'duplicate top-level env assignment' },
    @{ N = 'duplicate after comments'; T = (MisercText @('# one', (MisercArray @((DqName 'a'))), '', '# two', (MisercArray @((DqName 'b'))))); R = 'duplicate top-level env assignment' },
    @{ N = 'string scalar'; T = ('env = ' + (DqName 'a')); R = 'env must be an array' },
    @{ N = 'literal scalar'; T = ('env = ' + (SqName 'a')); R = 'env must be an array' },
    @{ N = 'number scalar'; T = 'env = 3'; R = 'env must be an array' },
    @{ N = 'bool scalar'; T = 'env = true'; R = 'env must be an array' },
    @{ N = 'bare element'; T = 'env = [a]'; R = 'env array elements must be single-line quoted strings' },
    @{ N = 'nested array element'; T = ('env = [[' + (DqName 'a') + ']]'); R = 'env array elements must be single-line quoted strings' },
    @{ N = 'inline table element'; T = ('env = [{ a = ' + (DqName 'b') + ' }]'); R = 'env array elements must be single-line quoted strings' },
    @{ N = 'missing equals'; T = ('env [' + (DqName 'a') + ']'); R = 'malformed env assignment' },
    @{ N = 'bare key at end of file'; T = 'env'; R = 'malformed env assignment' },
    @{ N = 'missing value'; T = 'env ='; R = 'unterminated env assignment' },
    @{ N = 'comment instead of value'; T = 'env = # nothing'; R = 'unterminated env assignment' }
  )
  return $ok
}

T 'miserc read: out-of-subset strings fail closed with their own reason' {
  return (AssertMisercRejects @(
    @{ N = 'escape in a basic string'; T = ('env = [' + (DqName 'a\nb') + ']'); R = 'escape sequences are unsupported' },
    @{ N = 'triple-quoted element'; T = ('env = [' + ($script:DQ + $script:DQ + $script:DQ) + 'a' + ($script:DQ + $script:DQ + $script:DQ) + ']'); R = 'multiline strings are unsupported' },
    @{ N = 'literal triple-quoted element'; T = ("env = ['''a''']"); R = 'multiline strings are unsupported' },
    @{ N = 'escape in a scalar'; T = ('env = ' + (DqName 'a\q')); R = 'escape sequences are unsupported' },
    @{ N = 'unterminated basic string'; T = 'env = ["a'; R = 'unterminated env assignment' },
    @{ N = 'unterminated literal string'; T = "env = ['a"; R = 'unterminated env assignment' },
    @{ N = 'unterminated array'; T = ('env = [' + (DqName 'a')); R = 'unterminated env assignment' },
    @{ N = 'unterminated array after comma'; T = ('env = [' + (DqName 'a') + ','); R = 'unterminated env assignment' },
    @{ N = 'unterminated multiline string in the file'; T = (MisercText @('note = """', 'still open')); R = 'unterminated string in file' }
  ))
}

T 'miserc read: separators and trailing content fail closed' {
  return (AssertMisercRejects @(
    @{ N = 'missing comma'; T = ('env = [' + (DqName 'a') + ' ' + (DqName 'b') + ']'); R = 'malformed env array separator' },
    @{ N = 'missing comma across lines'; T = (MisercText @('env = [', '  ' + (DqName 'a'), '  ' + (DqName 'b'), ']')); R = 'malformed env array separator' },
    @{ N = 'doubled comma'; T = ('env = [' + (DqName 'a') + ',, ' + (DqName 'b') + ']'); R = 'malformed env array separator' },
    @{ N = 'leading comma'; T = ('env = [,' + (DqName 'a') + ']'); R = 'malformed env array separator' },
    @{ N = 'junk after the array'; T = ((MisercArray @((DqName 'a'))) + ' x'); R = 'unexpected content after env array' },
    @{ N = 'comma after the array'; T = ((MisercArray @((DqName 'a'))) + ','); R = 'unexpected content after env array' }
  ))
}

T 'miserc write: empty input yields the canonical line' {
  return (AssertMisercWrite 'empty' '' @() ((MisercArray @((DqName 'pmsec'))) + $script:NL))
}

T 'miserc write: pmsec is dropped from inherited and appended exactly once' {
  $text = MisercText @('env = []')
  $ok = AssertMisercWrite 'order kept' $text @('a','pmsec','b','pmsec') ('env = [' + (DqName 'a') + ', ' + (DqName 'b') + ', ' + (DqName 'pmsec') + ']' + $script:NL)
  $ok = $ok -and (AssertMisercWrite 'pmsec first' $text @('pmsec','work') ('env = [' + (DqName 'work') + ', ' + (DqName 'pmsec') + ']' + $script:NL))
  $ok = $ok -and (AssertMisercWrite 'only pmsec' $text @('pmsec','pmsec') ('env = [' + (DqName 'pmsec') + ']' + $script:NL))
  return $ok
}

T 'miserc write: an existing multiline assignment collapses to one line in place' {
  $text = MisercText @(
    'minimum_release_age = "1d"',
    'env = [',
    '  ' + (DqName 'a') + ', # first',
    '  ' + (SqName 'b') + ',',
    ']',
    'z = 9'
  )
  $expected = MisercText @('minimum_release_age = "1d"', ('env = [' + (SqName 'b') + ', ' + (DqName 'c') + ', ' + (DqName 'pmsec') + ']'), 'z = 9')
  return (AssertMisercWrite 'collapse' $text @('b','c') $expected)
}

T 'miserc write: local quoting is reused, leftmost token first' {
  $ok = AssertMisercWrite 'single-quoted local token' (MisercText @('env = [' + (SqName 'work') + ']')) @('work') ('env = [' + (SqName 'work') + ', ' + (DqName 'pmsec') + ']' + $script:NL)
  $ok = $ok -and (AssertMisercWrite 'leftmost duplicate wins' (MisercText @((MisercArray @((DqName 'work'), (SqName 'work'))))) @('work') ((MisercArray @((DqName 'work'), (DqName 'pmsec'))) + $script:NL))
  return $ok
}

T 'miserc write: inherited names are serialized canonically' {
  $ok = AssertMisercWrite 'plain name' '' @('work') ('env = [' + (DqName 'work') + ', ' + (DqName 'pmsec') + ']' + $script:NL)
  $ok = $ok -and (AssertMisercWrite 'double quote forces literals' '' @('a"b') ('env = [' + (SqName 'a"b') + ', ' + (DqName 'pmsec') + ']' + $script:NL))
  $ok = $ok -and (AssertMisercWrite 'backslash forces literals' '' @('a\b') ('env = [' + (SqName 'a\b') + ', ' + (DqName 'pmsec') + ']' + $script:NL))
  $ok = $ok -and (AssertMisercWriteReject 'both quote kinds' '' @('a"b''c') 'env name cannot be represented without escapes')
  $ok = $ok -and (AssertMisercWriteReject 'control character' '' @('a' + [char]9 + 'b') 'env name cannot be represented without escapes')
  return $ok
}

T 'miserc write: bytes outside the assignment are preserved' {
  $bom = [string][char]0xFEFF
  $crlf = [string][char]13 + $script:NL
  $bomText = $bom + (MisercText @('env = [' + (DqName 'a') + ']'))
  $bomExpected = $bom + (MisercText @((MisercArray @((DqName 'a'), (DqName 'pmsec')))))
  $ok = AssertMisercWrite 'BOM' $bomText @('a') $bomExpected
  $crlfText = 'env = [' + $crlf + '  ' + (DqName 'a') + ',' + $crlf + ']' + $crlf + 'x = 1' + $crlf
  $crlfExpected = (MisercArray @((DqName 'a'), (DqName 'pmsec'))) + $crlf + 'x = 1' + $crlf
  $ok = $ok -and (AssertMisercWrite 'CRLF' $crlfText @('a') $crlfExpected)
  $noEolText = 'x = 1' + $script:NL + 'env = [' + (DqName 'a') + ']'
  $noEolExpected = 'x = 1' + $script:NL + 'env = [' + (DqName 'a') + ', ' + (DqName 'pmsec') + ']'
  $ok = $ok -and (AssertMisercWrite 'no final newline' $noEolText @('a') $noEolExpected)
  $commentText = MisercText @('  env = [' + (DqName 'a') + '] # keep me', 'z = 1')
  $commentExpected = MisercText @('  ' + (MisercArray @((DqName 'a'), (DqName 'pmsec'))) + ' # keep me', 'z = 1')
  return ($ok -and (AssertMisercWrite 'indentation and trailing comment' $commentText @('a') $commentExpected))
}

T 'miserc write: an absent assignment is inserted before the first table' {
  $text = MisercText @('minimum_release_age = "1d"', '', '[tools]', 'x = 1')
  $expected = MisercText @('minimum_release_age = "1d"', '', (MisercArray @((DqName 'pmsec'))), '[tools]', 'x = 1')
  $ok = AssertMisercWrite 'before the table' $text @() $expected
  $ok = $ok -and (AssertMisercWrite 'file without a trailing newline' 'a = 1' @() ('a = 1' + $script:NL + (MisercArray @((DqName 'pmsec'))) + $script:NL))
  $ok = $ok -and (AssertMisercWrite 'leading table' (MisercText @('[tools]', 'x = 1')) @() (MisercText @((MisercArray @((DqName 'pmsec'))), '[tools]', 'x = 1')))
  $tableText = MisercText @('[a]', '[b]')
  $tableExpected = MisercText @((MisercArray @((DqName 'work'), (DqName 'pmsec'))), '[a]', '[b]')
  $ok = $ok -and (AssertMisercWrite 'tables without root content' $tableText @('work') $tableExpected)
  return $ok
}

T 'miserc write: competing env tables and dotted keys are refused' {
  $ok = AssertMisercWriteReject 'env table' (MisercText @('[env]', 'a = 1')) @('a') 'env table conflicts with the env array'
  $ok = $ok -and (AssertMisercWriteReject 'array-of-tables header' (MisercText @('[[env]]', 'a = 1')) @('a') 'env table conflicts with the env array')
  $ok = $ok -and (AssertMisercWriteReject 'padded header' (MisercText @('[ env ]', 'a = 1')) @('a') 'env table conflicts with the env array')
  $ok = $ok -and (AssertMisercWriteReject 'double-quoted header' (MisercText @('["env"]', 'a = 1')) @('a') 'env table conflicts with the env array')
  $ok = $ok -and (AssertMisercWriteReject 'single-quoted header' (MisercText @("['env']", 'a = 1')) @('a') 'env table conflicts with the env array')
  $ok = $ok -and (AssertMisercWriteReject 'indented header' (MisercText @('  [env]', 'a = 1')) @('a') 'env table conflicts with the env array')
  $ok = $ok -and (AssertMisercWriteReject 'dotted key' (MisercText @('env.foo = 1')) @('a') 'env table conflicts with the env array')
  $ok = $ok -and (AssertMisercWriteReject 'dotted key in a table' (MisercText @('[tools]', 'env.foo = 1')) @('a') 'env table conflicts with the env array')
  return $ok
}

T 'miserc write: writing the same inherited list twice is byte-identical' {
  $text = MisercText @('env = [', '  ' + (DqName 'a'), ']', '[tools]', 'x = 1')
  $first = WriteMiserc $text @('a','b')
  $second = WriteMiserc ([string]$first['Text']) @('a','b')
  $ok = AssertEq 'first ok' 'True' ([string]$first['Ok'])
  return ($ok -and (AssertEq 'second write is identical' ([string]$first['Text']) ([string]$second['Text'])))
}

T 'miserc error text keeps the frozen envelope' {
  $ok = AssertEq 'shape' ('invalid env in miserc.local.toml: env must be an array') (Get-MisercErrorText -Path 'miserc.local.toml' -Reason 'env must be an array')
  return ($ok -and (AssertEq 'windows path' ('invalid env in C:\Users\me\.config\mise\miserc.local.toml: malformed env array separator') (Get-MisercErrorText -Path 'C:\Users\me\.config\mise\miserc.local.toml' -Reason 'malformed env array separator')))
}

# ---------- mise layering: CLI smoke ----------

T 'legacy CLI smoke: enable and check on the default fake scope are unchanged' {
  $h = NewHome
  try {
    $misePath = PathJoin $h '.config' 'mise' 'config.toml'
    $r = InvokePmsec $h $null @('--tool','mise')
    if ($r.Code -ne 0) { $script:LastFail = "enable exit $($r.Code)`n$($r.Err)"; return $false }
    if (-not (AssertEq 'enable line' ('enable  mise [' + $misePath + ']') ([string]$r.Out).Trim())) { return $false }
    $c = InvokePmsec $h $null @('--check','--json','--tool','mise')
    if ($c.Code -ne 0) { $script:LastFail = "check exit $($c.Code)`n$($c.Out)"; return $false }
    $row = ($c.Out | ConvertFrom-Json).rows[0]
    if ((AssertEq 'check path' $misePath ([string]$row.path)) -eq $false) { return $false }
    if ((AssertEq 'check key' 'minimum_release_age' ([string]$row.key)) -eq $false) { return $false }
    if ((AssertEq 'check days' '1' ([string]$row.days)) -eq $false) { return $false }
    $t = InvokePmsec $h $null @('--check','--tool','mise')
    if ($t.Code -ne 0) { $script:LastFail = "human check exit $($t.Code)`n$($t.Out)"; return $false }
    return (AssertMatch 'human check line' 'OK\s+mise +minimum_release_age = "1d"\s+\[' ([string]$t.Out))
  } finally {
    Remove-Item -Recurse -Force -LiteralPath $h
  }
}

# ---------- summary ----------

Write-Host ""
Write-Host "$($script:Pass) passed, $($script:Fail) failed"
if ($script:Fail -gt 0) { exit 1 }
exit 0
