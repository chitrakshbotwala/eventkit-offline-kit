<#
  EventKit offline installer for Windows (run install-windows.cmd, or this file directly).

  Installs, from the files next to this script and without internet:
    EventKit, Git, the Flutter SDK, Temurin JDK 17, the Android SDK (command-line tools,
    platform-tools, platform, build-tools), Google Chrome, VS Code and its Dart/Flutter
    extensions, and the workshop's starter project.

  Anything already installed that meets the event's requirements is left alone. Tools go
  where the EventKit app puts them (C:\dev\toolchain, or %USERPROFILE%\dev\toolchain), so
  the app finds and reuses them when you open it. No administrator rights are needed.

  Options:
    -Root <folder>   Toolchain folder (no spaces or special characters)
    -SkipApp         Don't install the EventKit app
    -Only <list>     Only these steps, e.g. -Only flutter,android
    -NoEnv           Don't save PATH, JAVA_HOME and ANDROID_HOME to your user environment
#>
param(
  [string]$Root,
  [switch]$SkipApp,
  [string[]]$Only,
  [switch]$NoEnv
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2

# Through install-windows.cmd (powershell -File), "-Only a,b" arrives as one string.
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })

$Kit = $PSScriptRoot
$Payload = Join-Path $Kit 'payload'

# Android SDK license hashes, as `sdkmanager --licenses` writes them when you accept.
$AndroidLicenseHashes = @(
  '24333f8a63b6825ea9c5514f83c2829b004d1fee',
  'd56f5187479451eabf01fb78af6dfcb131a6481e',
  '8933bad161af4178b1185d1a37fbf41ea5269c55'
)

# ------------------------------------------------------------------------------------------
# Output

function Say([string]$msg) { Write-Host $msg }
function Step([string]$msg) { Write-Host ''; Write-Host "== $msg" -ForegroundColor Cyan }
function Ok([string]$msg) { Write-Host "   ok    $msg" -ForegroundColor Green }
function Info([string]$msg) { Write-Host "   ..    $msg" }
function Warn([string]$msg) { Write-Host "   warn  $msg" -ForegroundColor Yellow }

$Results = New-Object System.Collections.ArrayList
function Result([string]$name, [string]$status, [string]$detail) {
  [void]$Results.Add([pscustomobject]@{ Step = $name; Status = $status; Detail = $detail })
}

# ------------------------------------------------------------------------------------------
# Kit index

if (-not (Test-Path (Join-Path $Payload 'targets'))) {
  throw "No payload folder next to this script ($Payload). Build the kit first: node offline-kit/build-kit.mjs"
}

$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$Target = if ($arch -eq 'ARM64') { 'windows-arm64' } else { 'windows-x64' }
$tsv = Join-Path $Payload "targets\$Target.tsv"
if (-not (Test-Path $tsv) -and $Target -eq 'windows-arm64') {
  # x64 tools run under emulation on Windows on Arm.
  $Target = 'windows-x64'
  $tsv = Join-Path $Payload "targets\$Target.tsv"
}
if (-not (Test-Path $tsv)) { throw "This kit has no files for $Target." }

$Rows = @()
$Meta = @{}
foreach ($line in [IO.File]::ReadAllLines($tsv)) {
  if (-not $line) { continue }
  $f = $line.Split("`t")
  $r = [pscustomobject]@{ Kind = $f[0]; File = $f[1]; Sha256 = $f[2]; Arg = $(if ($f.Count -gt 3) { $f[3] } else { '' }) }
  if ($r.Kind -eq 'meta') { $Meta[$r.File] = $r.Arg } else { $Rows += $r }
}

function RowsOf([string]$pattern) { @($Rows | Where-Object { $_.Kind -like $pattern }) }
function RowOf([string]$pattern) { RowsOf $pattern | Select-Object -First 1 }
function Wanted([string]$name) { -not $Only -or ($Only -contains $name) }

$Verified = @{}
function KitFile($row) {
  $path = Join-Path $Payload ($row.File -replace '/', '\')
  if (-not (Test-Path $path)) { throw "Missing from the kit: $($row.File)" }
  if (-not $Verified[$path]) {
    Info "checking $(Split-Path $path -Leaf)"
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($actual -ne $row.Sha256) { throw "$($row.File) is corrupt (SHA-256 mismatch). Copy the kit again." }
    $Verified[$path] = $true
  }
  return $path
}

# ------------------------------------------------------------------------------------------
# Helpers

function Run([string]$file, [string[]]$arguments, [int]$timeoutSec = 600) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
  $quoted = @($arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })
  if ($ext -eq '.bat' -or $ext -eq '.cmd') {
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = '/d /s /c "' + (@('"' + $file + '"') + $quoted -join ' ') + '"'
  } else {
    $psi.FileName = $file
    $psi.Arguments = $quoted -join ' '
  }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $psi.CreateNoWindow = $true
  foreach ($k in @($script:EnvVars.Keys)) { $psi.EnvironmentVariables[$k] = $script:EnvVars[$k] }
  $psi.EnvironmentVariables['Path'] = $env:Path
  $p = [Diagnostics.Process]::Start($psi)
  $p.StandardInput.Close()
  $out = $p.StandardOutput.ReadToEndAsync()
  $err = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($timeoutSec * 1000)) {
    try { $p.Kill() } catch { }
    throw "$(Split-Path $file -Leaf) timed out"
  }
  $p.WaitForExit()
  return [pscustomobject]@{ Code = $p.ExitCode; Out = $out.Result; Err = $err.Result }
}

function TryRun([string]$file, [string[]]$arguments, [int]$timeoutSec = 300) {
  try { return Run $file $arguments $timeoutSec } catch { return $null }
}

function RunInstaller([string]$file, [string]$argLine, [int]$timeoutSec = 1200) {
  $p = Start-Process -FilePath $file -ArgumentList $argLine -PassThru -WindowStyle Hidden
  if (-not $p.WaitForExit($timeoutSec * 1000)) { throw "$(Split-Path $file -Leaf) did not finish" }
  return $p.ExitCode
}

function PathProblem([string]$p) {
  if ($p -match '\s') { return 'contains spaces' }
  if ($p -match '[^\x00-\x7F]') { return 'contains non-ASCII characters' }
  if ($p -notmatch '^[A-Za-z0-9._\-/\\:~+@#$=,\[\]{}]+$') { return 'contains special characters' }
  return $null
}

function Writable([string]$dir) {
  try {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $probe = Join-Path $dir ".eventkit-write-test-$PID"
    Set-Content -LiteralPath $probe -Value 'ok'
    Remove-Item -LiteralPath $probe -Force
    return $true
  } catch { return $false }
}

function FirstExisting([string[]]$paths) {
  foreach ($p in $paths) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
  return $null
}

function OnPath([string]$name) {
  $c = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source } else { return $null }
}

function Extract([string]$archive, [string]$dest) {
  if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
  if (Test-Path $tar) {
    # bsdtar (built into Windows 10+) is many times faster than Expand-Archive on big zips.
    $r = Run $tar @('-xf', $archive, '-C', $dest) 3600
    if ($r.Code -eq 0) { return }
    Warn "tar could not extract $(Split-Path $archive -Leaf), using Expand-Archive"
    Remove-Item -LiteralPath $dest -Recurse -Force
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
  }
  Expand-Archive -LiteralPath $archive -DestinationPath $dest -Force
}

function SingleChild([string]$dir) {
  $kids = @(Get-ChildItem -LiteralPath $dir -Directory)
  if ($kids.Count -ne 1) { throw "Unexpected archive layout in $dir" }
  return $kids[0].FullName
}

function ReplaceDir([string]$from, [string]$to) {
  if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Recurse -Force }
  New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent) | Out-Null
  Move-Item -LiteralPath $from -Destination $to
}

function VersionAtLeast([string]$have, [string]$min) {
  try { return [version]($have -replace '[^\d.].*$', '') -ge [version]$min } catch { return $false }
}

# Environment changes: applied to this session now, persisted to the user environment at the end.
$script:EnvVars = @{}
$script:EnvPath = New-Object System.Collections.ArrayList
function AddPath([string]$dir) {
  if ($script:EnvPath -notcontains $dir) { [void]$script:EnvPath.Add($dir) }
  if (-not (($env:Path -split ';') -contains $dir)) { $env:Path = "$dir;$env:Path" }
}
function SetVar([string]$name, [string]$value) {
  $script:EnvVars[$name] = $value
  Set-Item -Path "Env:$name" -Value $value
}

function PersistEnv {
  # Same approach as the app: edit HKCU\Environment directly, keep PATH as REG_EXPAND_SZ.
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  $parts = @($raw -split ';' | Where-Object { $_ -ne '' })
  $existing = @($parts | ForEach-Object { $_.TrimEnd('\').ToLowerInvariant() })
  $add = @($script:EnvPath | Where-Object { $existing -notcontains $_.TrimEnd('\').ToLowerInvariant() })
  $final = (@($add) + $parts) -join ';'
  if ($final -ne $raw) { $key.SetValue('Path', $final, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
  foreach ($k in $script:EnvVars.Keys) {
    $key.SetValue($k, [string]$script:EnvVars[$k], [Microsoft.Win32.RegistryValueKind]::String)
  }
  $key.Close()
  # Setting a variable through .NET broadcasts WM_SETTINGCHANGE so new windows see the change.
  [Environment]::SetEnvironmentVariable('EVENTKIT_ENV_TOUCH', '1', 'User')
  [Environment]::SetEnvironmentVariable('EVENTKIT_ENV_TOUCH', $null, 'User')
}

# ------------------------------------------------------------------------------------------
# Install root (same candidates as the app)

if (-not $Root) {
  $drive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
  foreach ($c in @("$drive\dev\toolchain", (Join-Path $env:USERPROFILE 'dev\toolchain'))) {
    if (-not (PathProblem $c) -and (Writable $c)) { $Root = $c; break }
  }
  if (-not $Root) { throw 'No usable toolchain folder. Pass one with -Root C:\some\folder (no spaces).' }
} else {
  $problem = PathProblem $Root
  if ($problem) { throw "Toolchain folder $Root $problem." }
  if (-not (Writable $Root)) { throw "Toolchain folder $Root is not writable." }
}
$Staging = Join-Path $Root '.staging'
$Dirs = @{
  Flutter = Join-Path $Root 'flutter'
  Jdk = Join-Path $Root 'jdk-17'
  AndroidSdk = Join-Path $Root 'android-sdk'
  Projects = Join-Path (Split-Path $Root -Parent) 'projects'
}

Say "EventKit offline installer ($Target)"
if ($Meta['event']) { Say "Event: $($Meta['event'])" }
Say "Toolchain folder: $Root"
$free = (Get-PSDrive -Name ($Root.Substring(0, 1))).Free
if ($free -lt 15GB) { Warn ("only {0:N1} GB free on {1}; setup needs about 15 GB" -f ($free / 1GB), $Root.Substring(0, 2)) }

# ------------------------------------------------------------------------------------------
# EventKit app

function Install-App {
  $exe = FirstExisting @(
    (Join-Path $env:LOCALAPPDATA 'Programs\eventkit\EventKit.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\EventKit\EventKit.exe')
  )
  if ($exe) { Ok "EventKit already installed ($exe)"; return 'present' }
  $row = RowOf 'app-exe'
  if (-not $row) { throw 'The kit has no EventKit installer for Windows' }
  $file = KitFile $row
  Info "installing EventKit $($Meta['appVersion'])"
  # electron-builder one-click NSIS: /S installs silently for the current user.
  $code = RunInstaller $file '/S'
  if ($code -ne 0) { throw "EventKit installer exited with $code" }
  Ok 'EventKit installed'
  return 'installed'
}

# ------------------------------------------------------------------------------------------
# Git

function Find-Git {
  FirstExisting @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'),
    (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
    $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe' }),
    (OnPath 'git')
  )
}

function Git-Version([string]$git) {
  $r = TryRun $git @('--version') 60
  if ($r -and $r.Code -eq 0 -and $r.Out -match 'git version (\d+\.\d+\.\d+)') { return $Matches[1] }
  return $null
}

function Install-Git {
  $min = $Meta['gitMinVersion']
  $git = Find-Git
  if ($git) {
    $v = Git-Version $git
    if ($v -and (-not $min -or (VersionAtLeast $v $min))) {
      AddPath (Split-Path $git -Parent)
      Ok "Git $v ($git)"
      return 'present'
    }
    Info "Git $v is older than $min, updating"
  }
  $row = RowOf 'git-exe'
  if (-not $row) { throw 'The kit has no Git installer' }
  $file = KitFile $row
  Info 'running the Git installer (current user, silent)'
  $code = RunInstaller $file $row.Arg
  if ($code -ne 0) { throw "Git installer exited with $code" }
  $git = Find-Git
  if (-not $git) { throw 'Git installer finished but git.exe was not found' }
  AddPath (Split-Path $git -Parent)
  Ok "Git $(Git-Version $git) installed"
  return 'installed'
}

# ------------------------------------------------------------------------------------------
# Flutter

function Flutter-Info([string]$bin) {
  $r = TryRun $bin @('--version', '--machine') 600
  if (-not $r -or $r.Code -ne 0) { return $null }
  $s = $r.Out.IndexOf('{'); $e = $r.Out.LastIndexOf('}')
  if ($s -lt 0 -or $e -le $s) { return $null }
  try { return $r.Out.Substring($s, $e - $s + 1) | ConvertFrom-Json } catch { return $null }
}

function Flutter-Bin { Join-Path $Dirs.Flutter 'bin\flutter.bat' }

function Install-Flutter {
  $want = $Meta['flutterVersion']
  $pinned = $Meta['flutterPinned'] -eq 'true'
  $candidates = @(
    $(if ($env:FLUTTER_ROOT) { Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat' }),
    (OnPath 'flutter.bat'),
    (Flutter-Bin)
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
  foreach ($bin in $candidates) {
    Info "checking Flutter at $bin"
    $info = Flutter-Info $bin
    if (-not $info) { continue }
    $sdk = if ($info.PSObject.Properties['flutterRoot'] -and $info.flutterRoot) { $info.flutterRoot } else { Split-Path (Split-Path $bin -Parent) -Parent }
    $skip = PathProblem $sdk
    if (-not $skip -and $info.channel -ne 'stable') { $skip = "channel $($info.channel)" }
    if (-not $skip -and $pinned -and $info.frameworkVersion -ne $want) { $skip = "version $($info.frameworkVersion), event requires $want" }
    if ($skip) { Info "not using Flutter at ${sdk}: $skip"; continue }
    $Dirs.Flutter = $sdk
    AddPath (Join-Path $sdk 'bin')
    Ok "Flutter $($info.frameworkVersion) ($sdk)"
    return 'present'
  }
  $row = RowOf 'flutter-*'
  $file = KitFile $row
  Info "extracting Flutter $want (a few minutes)"
  $stage = Join-Path $Staging 'flutter'
  Extract $file $stage
  $extracted = if (Test-Path (Join-Path $stage 'flutter\bin')) { Join-Path $stage 'flutter' } else { SingleChild $stage }
  $Dirs.Flutter = Join-Path $Root 'flutter'
  ReplaceDir $extracted $Dirs.Flutter
  AddPath (Join-Path $Dirs.Flutter 'bin')
  $git = Find-Git
  if ($git) { [void](TryRun $git @('config', '--global', '--add', 'safe.directory', ($Dirs.Flutter -replace '\\', '/'))) }
  Info 'first run of flutter (builds the tool, no download)'
  [void](TryRun (Flutter-Bin) @('config', '--no-analytics') 900)
  [void](TryRun (Flutter-Bin) @('--disable-analytics') 300)
  $info = Flutter-Info (Flutter-Bin)
  if (-not $info) { throw 'Flutter was extracted but `flutter --version` failed' }
  Ok "Flutter $($info.frameworkVersion) installed"
  return 'installed'
}

# ------------------------------------------------------------------------------------------
# Java

function Java-Major([string]$javaExe) {
  $r = TryRun $javaExe @('-version') 120
  if (-not $r) { return 0 }
  if (("$($r.Err)$($r.Out)") -match 'version "(\d+)(\.(\d+))?') {
    $major = [int]$Matches[1]
    if ($major -eq 1 -and $Matches[3]) { $major = [int]$Matches[3] }
    return $major
  }
  return 0
}

function Install-Java {
  $min = [int]$Meta['javaMajor']
  $onPath = OnPath 'java'
  $homes = @(
    $env:JAVA_HOME,
    (Join-Path $env:ProgramFiles 'Android\Android Studio\jbr'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Android Studio\jbr'),
    $(if ($onPath) { Split-Path (Split-Path $onPath -Parent) -Parent }),
    $Dirs.Jdk
  ) | Where-Object { $_ } | Select-Object -Unique
  foreach ($h in $homes) {
    $exe = Join-Path $h 'bin\java.exe'
    if (-not (Test-Path -LiteralPath $exe)) { continue }
    $major = Java-Major $exe
    if ($major -ge $min -and $major -le 21) {
      $Dirs.Jdk = $h
      SetVar 'JAVA_HOME' $h
      AddPath (Join-Path $h 'bin')
      Ok "Java $major ($h)"
      return 'present'
    }
    if ($major) { Info "not using Java $major at $h" }
  }
  $file = KitFile (RowOf 'java-*')
  Info 'extracting Temurin JDK'
  $stage = Join-Path $Staging 'jdk'
  Extract $file $stage
  $Dirs.Jdk = Join-Path $Root 'jdk-17'
  ReplaceDir (SingleChild $stage) $Dirs.Jdk
  SetVar 'JAVA_HOME' $Dirs.Jdk
  AddPath (Join-Path $Dirs.Jdk 'bin')
  Ok "Java $(Java-Major (Join-Path $Dirs.Jdk 'bin\java.exe')) installed"
  return 'installed'
}

# ------------------------------------------------------------------------------------------
# Android SDK

function Find-AndroidSdk {
  foreach ($sdk in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android\Sdk'))) {
    if (-not $sdk) { continue }
    $looks = @('platform-tools', 'platforms', 'build-tools', 'cmdline-tools') | Where-Object { Test-Path (Join-Path $sdk $_) }
    if (-not $looks) { continue }
    $problem = PathProblem $sdk
    if ($problem) { Info "not using Android SDK at ${sdk}: $problem"; continue }
    return $sdk
  }
  return $null
}

function Install-Android {
  $sdk = Find-AndroidSdk
  if (-not $sdk) { $sdk = Join-Path $Root 'android-sdk' }
  $Dirs.AndroidSdk = $sdk
  New-Item -ItemType Directory -Force -Path $sdk | Out-Null
  $changed = $false

  $sdkmanager = Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
  if (-not (Test-Path $sdkmanager)) {
    Info 'extracting Android command-line tools'
    $stage = Join-Path $Staging 'cmdline-tools'
    Extract (KitFile (RowOf 'android-cmdline-tools')) $stage
    if (-not (Test-Path (Join-Path $stage 'cmdline-tools\bin'))) { throw 'cmdline-tools archive layout unexpected' }
    ReplaceDir (Join-Path $stage 'cmdline-tools') (Join-Path $sdk 'cmdline-tools\latest')
    $changed = $true
  }

  foreach ($row in (RowsOf 'android-package')) {
    $dest = Join-Path $sdk ($row.Arg -replace ';', '\')
    if (Test-Path -LiteralPath $dest) { continue }
    Info "installing $($row.Arg)"
    $stage = Join-Path $Staging 'android-package'
    Extract (KitFile $row) $stage
    # Archives hold one folder whose name doesn't matter (e.g. android-16 for build-tools 36).
    ReplaceDir (SingleChild $stage) $dest
    $changed = $true
  }

  $licenses = Join-Path $sdk 'licenses'
  New-Item -ItemType Directory -Force -Path $licenses | Out-Null
  $licenseFile = Join-Path $licenses 'android-sdk-license'
  $have = if (Test-Path $licenseFile) { @(Get-Content -LiteralPath $licenseFile | ForEach-Object { $_.Trim() }) } else { @() }
  $missing = @($AndroidLicenseHashes | Where-Object { $have -notcontains $_ })
  if ($missing.Count) {
    # Writing the hash is what accepting the Android SDK License in sdkmanager does.
    Add-Content -LiteralPath $licenseFile -Value ("`n" + ($missing -join "`n")) -NoNewline
  }

  SetVar 'ANDROID_HOME' $sdk
  SetVar 'ANDROID_SDK_ROOT' $sdk
  AddPath (Join-Path $sdk 'platform-tools')
  AddPath (Join-Path $sdk 'cmdline-tools\latest\bin')

  $flutter = Flutter-Bin
  if (Test-Path -LiteralPath $flutter) {
    [void](TryRun $flutter @('config', "--android-sdk=$sdk") 300)
    if ($env:JAVA_HOME) { [void](TryRun $flutter @('config', "--jdk-dir=$env:JAVA_HOME") 300) }
  }
  if ($changed) { Ok "Android SDK installed ($sdk)"; return 'installed' }
  Ok "Android SDK ($sdk)"
  return 'present'
}

# ------------------------------------------------------------------------------------------
# Chrome

function Find-Chrome {
  $rel = 'Google\Chrome\Application\chrome.exe'
  FirstExisting @(
    (Join-Path $env:LOCALAPPDATA $rel),
    (Join-Path $env:ProgramFiles $rel),
    $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} $rel })
  )
}

function Install-Chrome {
  $chrome = Find-Chrome
  if ($chrome) { Ok "Google Chrome ($chrome)"; return 'present' }
  $row = RowOf 'chrome-exe'
  if (-not $row) { throw 'The kit has no Chrome installer for Windows' }
  $file = KitFile $row
  Info 'installing Google Chrome (current user)'
  [void](RunInstaller $file $row.Arg 900)
  for ($i = 0; $i -lt 60 -and -not (Find-Chrome); $i++) { Start-Sleep -Seconds 3 }
  if (-not (Find-Chrome)) { throw 'Chrome installer finished but chrome.exe was not found' }
  Ok 'Google Chrome installed'
  return 'installed'
}

# ------------------------------------------------------------------------------------------
# VS Code + extensions

function Find-Code {
  FirstExisting @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
    (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd')
  )
}

function Install-VSCode {
  $status = 'present'
  $cli = Find-Code
  if (-not $cli) {
    $row = RowOf 'vscode-exe'
    if (-not $row) { throw 'The kit has no VS Code installer for Windows' }
    $file = KitFile $row
    Info 'installing VS Code (current user, silent)'
    $code = RunInstaller $file $row.Arg 900
    if ($code -ne 0) { throw "VS Code installer exited with $code" }
    $cli = Find-Code
    if (-not $cli) { throw 'VS Code was installed but code.cmd was not found' }
    $status = 'installed'
  }
  AddPath (Split-Path $cli -Parent)
  $list = TryRun $cli @('--list-extensions') 120
  $have = if ($list) { @($list.Out -split "`r?`n" | ForEach-Object { $_.Trim().ToLowerInvariant() }) } else { @() }
  foreach ($row in (RowsOf 'vscode-extension')) {
    if ($have -contains $row.Arg.ToLowerInvariant()) { continue }
    Info "installing extension $($row.Arg)"
    $r = Run $cli @('--install-extension', (KitFile $row), '--force') 600
    if ($r.Code -ne 0) { throw "Installing $($row.Arg) failed: $($r.Err.Trim())" }
    $status = 'installed'
  }
  Ok 'VS Code with the Dart and Flutter extensions'
  return $status
}

# ------------------------------------------------------------------------------------------
# Starter project (the app runs `flutter pub get` and the Gradle warm-up on it later)

function Install-Starter {
  $row = RowOf 'starter-project'
  if (-not $row) { return 'skipped' }
  $dir = Join-Path $Dirs.Projects $row.Arg
  $marker = Join-Path $dir '.eventkit-starter'
  if ((Test-Path (Join-Path $dir 'pubspec.yaml')) -and (Test-Path $marker) -and ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $Meta['starterSha256'])) {
    Ok "starter project ($dir)"
    return 'present'
  }
  if (Test-Path -LiteralPath $dir) {
    # Never delete attendee work: keep the previous copy next to the new one.
    $backup = "$dir-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $dir -Destination $backup
    Info "kept previous project at $backup"
  }
  $stage = Join-Path $Staging 'starter'
  Extract (KitFile $row) $stage
  $src = if (Test-Path (Join-Path $stage 'pubspec.yaml')) { $stage } else {
    $p = Get-ChildItem -LiteralPath $stage -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'pubspec.yaml') } | Select-Object -First 1
    if (-not $p) { throw 'The starter project zip has no pubspec.yaml' }
    $p.FullName
  }
  ReplaceDir $src $dir
  [IO.File]::WriteAllText($marker, $Meta['starterSha256'])
  Ok "starter project ($dir)"
  return 'installed'
}

# ------------------------------------------------------------------------------------------

$steps = @(
  @{ Name = 'app'; Title = 'EventKit app'; Run = { Install-App } },
  @{ Name = 'git'; Title = 'Git'; Run = { Install-Git } },
  @{ Name = 'flutter'; Title = 'Flutter SDK'; Run = { Install-Flutter } },
  @{ Name = 'java'; Title = 'Java (JDK 17)'; Run = { Install-Java } },
  @{ Name = 'android'; Title = 'Android SDK'; Run = { Install-Android } },
  @{ Name = 'chrome'; Title = 'Google Chrome'; Run = { Install-Chrome } },
  @{ Name = 'vscode'; Title = 'VS Code'; Run = { Install-VSCode } },
  @{ Name = 'starter'; Title = 'Starter project'; Run = { Install-Starter } }
)

foreach ($s in $steps) {
  if (-not (Wanted $s.Name)) { continue }
  if ($s.Name -eq 'app' -and $SkipApp) { continue }
  Step $s.Title
  try {
    $status = & $s.Run
    Result $s.Title $status ''
  } catch {
    Warn $_.Exception.Message
    Result $s.Title 'FAILED' $_.Exception.Message
  }
}

# The JDK may have been picked after Flutter was configured.
if ((Test-Path -LiteralPath (Flutter-Bin)) -and $env:JAVA_HOME) {
  [void](TryRun (Flutter-Bin) @('config', "--jdk-dir=$env:JAVA_HOME") 300)
}

if (-not $NoEnv -and ($script:EnvPath.Count -or $script:EnvVars.Count)) {
  try { PersistEnv } catch { Warn "Could not save PATH and variables: $($_.Exception.Message)" }
}
if (Test-Path -LiteralPath $Staging) { Remove-Item -LiteralPath $Staging -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host '== Summary' -ForegroundColor Cyan
$Results | Format-Table -AutoSize | Out-String | Write-Host
$failed = @($Results | Where-Object { $_.Status -eq 'FAILED' })
if ($failed.Count) {
  Write-Host 'Some steps failed. Fix the problem above and run the installer again, or let the EventKit app' -ForegroundColor Yellow
  Write-Host 'finish them when you are online.' -ForegroundColor Yellow
  exit 1
}
Write-Host 'All done. Open EventKit and sign in with Google (needs internet once). Setup will find' -ForegroundColor Green
Write-Host 'these tools and only fetch what is left (Dart packages and the Gradle warm-up).' -ForegroundColor Green
Write-Host 'Open a new terminal window to use flutter from the command line.'
