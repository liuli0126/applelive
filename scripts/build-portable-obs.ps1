<#+
.SYNOPSIS
  Build a single extracted OBS folder with AppleLive already embedded.

.DESCRIPTION
  The input is an OBS portable/custom root supplied by the operator. The
  builder copies that root into a staging directory, places the current
  AppleLive package under data/obs-plugins/AppleLive, enables OBS portable
  mode, registers the dock/script in the staged config, and writes a one-click
  launcher. It never modifies the input OBS installation.

  This mirrors the useful part of the reference distribution: the customer
  receives one folder containing OBS, the media server, the USB sender, and
  the phone dylib. Third-party Apple/VB-Cable driver installers are not copied
  from another vendor's package; they must be supplied and licensed separately.
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$ObsRoot,
  [string]$Output = "",
  [switch]$KeepStage
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$pluginRoot = Join-Path $projectRoot 'obs-plugin'

function Find-ObsLauncher([string]$root) {
  $bin = Join-Path $root 'bin\64bit'
  if (-not (Test-Path -LiteralPath $bin)) { return $null }
  $standard = Join-Path $bin 'obs64.exe'
  if (Test-Path -LiteralPath $standard) { return (Get-Item -LiteralPath $standard).FullName }
  $normal = Get-ChildItem -LiteralPath $bin -Filter '*.exe' -File -ErrorAction SilentlyContinue |
    Where-Object {
      $_.VersionInfo.ProductName -eq 'OBS Studio' -or
      $_.VersionInfo.FileDescription -eq 'OBS Studio'
    } | Select-Object -First 1
  if ($normal) { return $normal.FullName }
  $renamed = Get-ChildItem -LiteralPath $bin -File -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -match '^(obs|AuxCam).*\.exe$' -and
      $_.Name -notmatch '(?i)(test|browser|ffmpeg|nvenc|qsv)'
    } | Select-Object -First 1
  if ($renamed) { return $renamed.FullName }
  return $null
}

function Copy-Tree([string]$from, [string]$to) {
  New-Item -ItemType Directory -Path $to -Force | Out-Null
  & robocopy.exe $from $to /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /XJ /NFL /NDL /NJH /NJS | Out-Null
  if ($LASTEXITCODE -gt 7) { throw "复制 OBS 文件失败，robocopy 退出码 $LASTEXITCODE" }
}

function Copy-AppleLive([string]$stage) {
  $target = Join-Path $stage 'data\obs-plugins\AppleLive'
  New-Item -ItemType Directory -Path $target -Force | Out-Null
  foreach ($directory in @('dock', 'server', 'phone-plugin')) {
    $src = Join-Path $pluginRoot $directory
    $dst = Join-Path $target $directory
    if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
    Copy-Tree $src $dst
  }
  foreach ($file in @(
    'AppleLive.lua', 'AppleLiveDock.exe', 'AppleLiveSender.exe', 'ffmpeg.exe',
    'README.md', 'setup_lan.ps1', 'install_or_update.ps1',
    'Install-AppleLive.cmd', 'VERSION.txt'
  )) {
    $src = Join-Path $pluginRoot $file
    if (-not (Test-Path -LiteralPath $src)) { throw "AppleLive 包缺少 $file" }
    Copy-Item -LiteralPath $src -Destination (Join-Path $target $file) -Force
  }
  $phonePath = Join-Path $target 'phone-plugin\AppleLive.dylib'
  $phoneHash = (Get-FileHash -LiteralPath $phonePath -Algorithm SHA256).Hash.ToLowerInvariant()
  Set-Content -LiteralPath (Join-Path $target 'phone-plugin\SHA256.txt') -Value "$phoneHash  AppleLive.dylib" -Encoding ascii
  foreach ($stale in @('usb_forward.ps1', 'applelive-bridge.json', 'applelive-command.json',
                       'applelive-sender.log', 'applelive-status.json', 'applelive-stop.flag',
                       'applelive-usb-error.log', 'applelive-usb.log', 'unicode-launch.log', 'lan-access.ok',
                       'server\applelive-server.log', 'server\mediamtx.log',
                       'server\mediamtx.pid')) {
    Remove-Item -LiteralPath (Join-Path $target $stale) -Force -ErrorAction SilentlyContinue
  }
}

$ObsRoot = (Resolve-Path -LiteralPath $ObsRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $ObsRoot 'bin\64bit'))) {
  throw 'ObsRoot must contain bin\64bit.'
}
$launcher = Find-ObsLauncher $ObsRoot
if (-not $launcher) {
  throw 'No obs64.exe or recognized OBS launcher was found.'
}
foreach ($required in @('AppleLiveDock.exe', 'AppleLiveSender.exe', 'ffmpeg.exe', 'server\mediamtx.exe', 'phone-plugin\AppleLive.dylib')) {
  if (-not (Test-Path -LiteralPath (Join-Path $pluginRoot $required))) {
    throw "AppleLive package is missing $required"
  }
}

$buildRoot = Join-Path $projectRoot '.build\portable-obs'
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$id = [Guid]::NewGuid().ToString('N')
$stageRoot = Join-Path $buildRoot $id
$stage = Join-Path $stageRoot 'AppleLive OBS'
Copy-Tree $ObsRoot $stage
Copy-AppleLive $stage

# Make the staged tree self-contained and portable. Existing scenes/settings
# are kept; the embedded updater adds the AppleLive script and dock once.
New-Item -ItemType File -Path (Join-Path $stage 'portable_mode.txt') -Force | Out-Null
$embeddedUpdater = Join-Path $stage 'data\obs-plugins\AppleLive\install_or_update.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $embeddedUpdater -ObsRoot $stage -Embedded -NoElevation -NoLaunch
if ($LASTEXITCODE -ne 0) { throw "Embedded OBS configuration failed (exit code $LASTEXITCODE)." }

$launcherScript = @'
@echo off
setlocal
title AppleLive OBS
set "ROOT=%~dp0"
set "UPDATER=%ROOT%data\obs-plugins\AppleLive\install_or_update.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%UPDATER%" -ObsRoot "%ROOT%." -Embedded
exit /b %ERRORLEVEL%
'@
[IO.File]::WriteAllText((Join-Path $stage 'AppleLive-Launcher.cmd'), $launcherScript, (New-Object Text.UTF8Encoding($false)))

$usage = @'
AppleLive OBS portable package

1. Keep the folder structure intact and run AppleLive-Launcher.cmd.
2. In the AppleLive dock choose LAN or USB.
3. LAN uses the RTMP/RTSP addresses shown in the dock. USB uses Prepare USB Direct, then USB Direct on the phone.
4. Allow Windows Firewall and trust the iPhone when prompted.

The package embeds the AppleLive dock, sender, MediaMTX, phone dylib and OBS configuration. Users do not need to replace plugin files manually.
Apple Mobile Device/usbmux and VB-Cable are system drivers and are not copied from a third-party distribution. Install an authorized Apple Devices/iTunes or audio driver package when required.
'@
[IO.File]::WriteAllText((Join-Path $stage 'AppleLive-README.txt'), $usage, (New-Object Text.UTF8Encoding($false)))

if (-not $Output) {
  $Output = Join-Path $projectRoot 'artifacts\AppleLive-OBS-Portable.zip'
}
$Output = [IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Path (Split-Path -Parent $Output) -Force | Out-Null
if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $Output -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash
Set-Content -LiteralPath ($Output + '.sha256') -Value "$hash  $(Split-Path -Leaf $Output)" -Encoding ascii
Write-Host "Portable OBS archive: $Output"
Write-Host "Launcher: $launcher"
Write-Host "SHA256: $hash"
if (-not $KeepStage) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
