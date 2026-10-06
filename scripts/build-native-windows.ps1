<#!
.SYNOPSIS
  Build the native AppleLive OBS output and usbmux relay against an existing OBS tree.

.DESCRIPTION
  OBS does not ship a development import library in its portable package. The
  native output only needs the stable libobs exports, so this script generates
  a small import library from the user's obs.dll and builds both components.
#>
param(
  [Parameter(Mandatory = $true)]
  [string]$ObsRoot,
  [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$obs = (Resolve-Path -LiteralPath $ObsRoot).Path
$obsDll = Join-Path $obs 'bin\64bit\obs.dll'
if (-not (Test-Path -LiteralPath $obsDll)) { throw "OBS DLL not found: $obsDll" }

$dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
$lib = Get-Command lib.exe -ErrorAction SilentlyContinue
if (-not $dumpbin -or -not $lib) {
  throw 'Run this script from a Visual Studio Developer PowerShell so dumpbin.exe and lib.exe are available.'
}

$buildRoot = Join-Path $projectRoot '.build\native-obs-output'
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$required = @(
  'blog', 'obs_audio_encoder_create', 'obs_data_create', 'obs_data_release',
  'obs_data_set_int', 'obs_encoder_get_codec', 'obs_encoder_get_extra_data', 'obs_data_set_string', 'obs_encoder_set_video', 'obs_encoder_set_audio',
  'obs_encoder_release', 'obs_get_audio', 'obs_get_audio_info', 'obs_get_video',
  'obs_get_video_info', 'obs_output_begin_data_capture', 'obs_output_create',
  'obs_output_end_data_capture', 'obs_output_active', 'obs_output_can_begin_data_capture', 'obs_output_initialize_encoders', 'obs_output_release',
  'obs_output_set_audio_encoder', 'obs_output_set_last_error', 'obs_output_set_media',
  'obs_output_set_video_encoder', 'obs_output_start', 'obs_output_stop',
  'obs_register_output_s', 'obs_video_encoder_create'
)
$dump = & $dumpbin.Source /exports $obsDll | Out-String
$def = @('LIBRARY obs.dll', 'EXPORTS')
foreach ($name in $required) {
  # Some dumpbin versions append forwarded/export alias information.
  if ($dump -notmatch "(?m)^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+$name(?=\s|$)") {
    throw "The installed obs.dll does not export $name"
  }
  $def += $name
}
$defPath = Join-Path $buildRoot 'obs.def'
$libPath = Join-Path $buildRoot 'obs.lib'
Set-Content -LiteralPath $defPath -Value $def -Encoding ascii
& $lib.Source /def:$defPath /machine:x64 /out:$libPath | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Failed to generate obs.lib' }

$relayBuild = Join-Path $projectRoot '.build\native-relay'
cmake -S (Join-Path $projectRoot 'native-obs-usb') -B $relayBuild -G 'Visual Studio 17 2022' -A x64 -DAPPLELIVE_BUILD_OBS_OUTPUT=OFF
if ($LASTEXITCODE -ne 0) { throw 'Relay CMake configure failed' }
cmake --build $relayBuild --config $Configuration --target AppleLiveUsbRelay -- /m:2
if ($LASTEXITCODE -ne 0) { throw 'Relay build failed' }

cmake -S (Join-Path $projectRoot 'native-obs-usb') -B $buildRoot -G 'Visual Studio 17 2022' -A x64 `
  -DAPPLELIVE_BUILD_OBS_OUTPUT=ON ("-DOBS_LIBRARY={0}" -f $libPath)
if ($LASTEXITCODE -ne 0) { throw 'Native output CMake configure failed' }
cmake --build $buildRoot --config $Configuration --target applelive-native-output -- /m:2
if ($LASTEXITCODE -ne 0) { throw 'Native output build failed' }

$output = Join-Path $projectRoot 'obs-plugin'
Copy-Item -LiteralPath (Join-Path $relayBuild "$Configuration\AppleLiveUsbRelay.exe") -Destination (Join-Path $output 'AppleLiveUsbRelay.exe') -Force
Copy-Item -LiteralPath (Join-Path $buildRoot "$Configuration\applelive-native-output.dll") -Destination (Join-Path $output 'applelive-native-output.dll') -Force
Write-Host "Native AppleLive components copied to $output"
