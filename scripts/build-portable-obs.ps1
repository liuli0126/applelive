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
  if ([IO.File]::Exists($standard)) { return [IO.Path]::GetFullPath($standard) }
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

function Remove-StagedDirectory([string]$path) {
  $resolved = [IO.Path]::GetFullPath($path)
  $boundary = [IO.Path]::GetFullPath($stageRoot).TrimEnd('\') + '\'
  if (-not $resolved.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove a path outside this build stage: $resolved"
  }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

function Copy-AppleLive([string]$stage) {
  $target = Join-Path $stage 'data\obs-plugins\AppleLive'
  New-Item -ItemType Directory -Path $target -Force | Out-Null
  foreach ($directory in @('dock', 'server', 'phone-plugin')) {
    $src = Join-Path $pluginRoot $directory
    $dst = Join-Path $target $directory
    Remove-StagedDirectory $dst
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
  foreach ($file in @('AppleLiveUsbRelay.exe')) {
    $src = Join-Path $pluginRoot $file
    if (Test-Path -LiteralPath $src) {
      Copy-Item -LiteralPath $src -Destination (Join-Path $target $file) -Force
    }
  }
  $nativeOutput = Join-Path $pluginRoot 'applelive-native-output.dll'
  if (Test-Path -LiteralPath $nativeOutput) {
    $nativeTarget = Join-Path $stage 'obs-plugins\64bit'
    New-Item -ItemType Directory -Path $nativeTarget -Force | Out-Null
    Copy-Item -LiteralPath $nativeOutput -Destination (Join-Path $nativeTarget 'applelive-native-output.dll') -Force
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
foreach ($required in @('AppleLiveDock.exe', 'AppleLiveSender.exe', 'AppleLiveUsbRelay.exe', 'applelive-native-output.dll', 'ffmpeg.exe', 'server\mediamtx.exe', 'phone-plugin\AppleLive.dylib')) {
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

# A customer distribution starts with a fresh scene/profile. Do not ship the
# operator's stream keys, browser sessions, logs, or machine-specific sources.
Remove-StagedDirectory (Join-Path $stage 'config')
$config = Join-Path $stage 'config\obs-studio'
$scenes = Join-Path $config 'basic\scenes'
$profile = Join-Path $config 'basic\profiles\AppleLive'
New-Item -ItemType Directory -Path $scenes, $profile -Force | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$scene = [ordered]@{
  name = 'AppleLive'; current_scene = 'Scene'; current_program_scene = 'Scene'
  scene_order = @(@{name='Scene'})
  sources = @(@{name='Scene'; id='scene'; versioned_id='scene'; settings=@{id_counter=0;items=@()}; enabled=$true; volume=1.0; mixers=0})
  modules = @{}
}
[IO.File]::WriteAllText((Join-Path $scenes 'AppleLive.json'), (ConvertTo-Json $scene -Depth 10), $utf8)
$globalIni = @'
[General]
Language=zh-CN
FirstRun=false
[Basic]
Profile=AppleLive
ProfileDir=AppleLive
SceneCollection=AppleLive
SceneCollectionFile=AppleLive
'@
$profileIni = @'
[General]
Name=AppleLive
[Video]
BaseCX=1920
BaseCY=1080
OutputCX=1920
OutputCY=1080
FPSType=0
FPSCommon=30
ColorFormat=NV12
ColorSpace=709
ColorRange=Partial
[Output]
Mode=Simple
[SimpleOutput]
StreamEncoder=x264
VBitrate=6000
ABitrate=160
[Audio]
SampleRate=48000
ChannelSetup=Stereo
'@
[IO.File]::WriteAllText((Join-Path $config 'global.ini'), $globalIni, $utf8)
[IO.File]::WriteAllText((Join-Path $profile 'basic.ini'), $profileIni, $utf8)
New-Item -ItemType File -Path (Join-Path $stage 'portable_mode.txt') -Force | Out-Null
$embeddedUpdater = Join-Path $stage 'data\obs-plugins\AppleLive\install_or_update.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $embeddedUpdater -ObsRoot $stage -Embedded -NoElevation -NoLaunch
if ($LASTEXITCODE -ne 0) { throw "Embedded OBS configuration failed (exit code $LASTEXITCODE)." }
# The launcher generates a fresh local control password on each customer's
# first run instead of distributing one shared build-time password.
$websocketPath = Join-Path $config 'plugin_config\obs-websocket\config.json'
$websocket = ConvertFrom-Json ([IO.File]::ReadAllText($websocketPath))
$websocket.server_password = ''
[IO.File]::WriteAllText($websocketPath, (ConvertTo-Json $websocket), $utf8)

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
3. LAN uses the RTMP/RTSP addresses shown in the dock. USB uses Prepare USB Direct, then USB Direct on the phone; the native OBS output and usbmux relay start automatically.
4. Allow Windows Firewall and trust the iPhone when prompted.

The package embeds the AppleLive dock, sender, MediaMTX, phone dylib and OBS configuration. Users do not need to replace plugin files manually.
USB requires Apple's Mobile Device driver (Apple Devices/iTunes). No virtual camera or virtual audio driver is required. Driver installers are not included.
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
if (-not $KeepStage) {
  $resolvedStage = (Resolve-Path -LiteralPath $stageRoot).Path
  $buildBoundary = (Resolve-Path -LiteralPath $buildRoot).Path.TrimEnd('\') + '\'
  if (-not $resolvedStage.StartsWith($buildBoundary, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid cleanup path' }
  Remove-Item -LiteralPath $resolvedStage -Recurse -Force
}
