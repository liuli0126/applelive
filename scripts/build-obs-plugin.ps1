param(
  [string]$Python = "python",
  [string]$PhonePlugin = "",
  [switch]$SkipDock
)

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$output = Join-Path $projectRoot "obs-plugin"
$build = Join-Path $projectRoot ".build\obs-plugin"
if (-not $PhonePlugin) { $PhonePlugin = Join-Path $output "phone-plugin\AppleLive.dylib" }
if (-not (Test-Path -LiteralPath $PhonePlugin)) {
  throw "Missing phone-plugin/AppleLive.dylib. Download the injector build artifact first."
}
& $Python (Join-Path $projectRoot "scripts\verify-injector-dylib.py") $PhonePlugin
if ($LASTEXITCODE -ne 0) { throw "Phone library verification failed" }

if (-not $SkipDock) {
  & $Python -m PyInstaller --noconfirm --clean --onefile --noconsole `
  --name AppleLiveDock --distpath $output --workpath (Join-Path $build "dock") `
  --specpath $build (Join-Path $projectRoot "desktop_sender\dock_server.py")
  if ($LASTEXITCODE -ne 0) { throw "Dock build failed" }
  & $Python -m PyInstaller --noconfirm --clean --onefile --noconsole `
    --name AppleLiveSender --distpath $output --workpath (Join-Path $build "sender") `
    --specpath $build (Join-Path $projectRoot "desktop_sender\sender.py")
  if ($LASTEXITCODE -ne 0) { throw "USB sender build failed" }

  $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
  if (-not $ffmpeg) { throw "FFmpeg not found while building the USB package" }
  Copy-Item -LiteralPath $ffmpeg.Source -Destination (Join-Path $output "ffmpeg.exe") -Force
}

# Native components are produced against OBS 30.2.3 before packaging.
# The Python sender remains for legacy installs; a present native module
# that fails to load is reported as an error by the dock.
$nativeRelayCandidates = @(
  (Join-Path $projectRoot 'native-obs-usb\build\Release\AppleLiveUsbRelay.exe'),
  (Join-Path $projectRoot '.build\native-relay\Release\AppleLiveUsbRelay.exe')
)
$nativeRelay = $nativeRelayCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($nativeRelay) {
  Copy-Item -LiteralPath $nativeRelay -Destination (Join-Path $output 'AppleLiveUsbRelay.exe') -Force
}
$nativeOutputCandidates = @(
  (Join-Path $projectRoot 'native-obs-usb\build\Release\applelive-native-output.dll'),
  (Join-Path $projectRoot '.build\native-obs-output\Release\applelive-native-output.dll')
)
$nativeOutput = $nativeOutputCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($nativeOutput) {
  Copy-Item -LiteralPath $nativeOutput -Destination (Join-Path $output 'applelive-native-output.dll') -Force
}

Copy-Item -LiteralPath (Join-Path $projectRoot "desktop_sender\setup_lan.ps1") `
  -Destination (Join-Path $output "setup_lan.ps1") -Force

Write-Host "OBS plugin files: $output"
Write-Host "Load AppleLive.lua from OBS Tools > Scripts. Keep AppleLiveDock.exe next to it."

$artifactDirectory = Join-Path $projectRoot "artifacts"
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
$archive = Join-Path $artifactDirectory "AppleLive-OBS-Windows.zip"
$stage = Join-Path $build ("package-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
 $packageItems = @(
  (Join-Path $output "AppleLive.lua"),
  (Join-Path $output "AppleLiveDock.exe"),
  (Join-Path $output "AppleLiveSender.exe"),
  (Join-Path $output "ffmpeg.exe"),
  (Join-Path $output "dock"),
  (Join-Path $output "setup_lan.ps1"),
  (Join-Path $output "install_or_update.ps1"),
  (Join-Path $output "VERSION.txt"),
  (Join-Path $output "README.md")
)
foreach ($optional in @(
  (Join-Path $output "AppleLiveUsbRelay.exe"),
  (Join-Path $output "applelive-native-output.dll")
)) {
  if (Test-Path -LiteralPath $optional) { $packageItems += $optional }
}
foreach ($item in $packageItems) {
  Copy-Item -LiteralPath $item -Destination $stage -Recurse -Force
}
Get-ChildItem -LiteralPath $output -Filter "*.cmd" -File |
  Copy-Item -Destination $stage -Force
New-Item -ItemType Directory -Path (Join-Path $stage "server"), (Join-Path $stage "phone-plugin") -Force | Out-Null
foreach ($name in @("mediamtx.exe", "mediamtx.yml", "LICENSE")) {
  Copy-Item -LiteralPath (Join-Path $output "server\$name") -Destination (Join-Path $stage "server\$name") -Force
}
foreach ($name in @("FFmpeg-LICENSE.txt", "FFmpeg-SOURCE.txt", "fishhook-LICENSE.txt",
    "libusb-LICENSE.txt", "libuvc-LICENSE.txt", "USBHost-NOTICE.txt",
    "AppleLive-relink.tar.gz", "AppleLive-UVC-Service-rootless.deb")) {
  Copy-Item -LiteralPath (Join-Path $output "phone-plugin\$name") -Destination (Join-Path $stage "phone-plugin\$name") -Force
}
Copy-Item -LiteralPath $PhonePlugin -Destination (Join-Path $stage "phone-plugin\AppleLive.dylib") -Force
$digest = (Get-FileHash -LiteralPath $PhonePlugin -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath (Join-Path $stage "phone-plugin\SHA256.txt") -Value "$digest  AppleLive.dylib" -Encoding ascii
$freshArchive = Join-Path $build ("AppleLive-OBS-" + [guid]::NewGuid().ToString("N") + ".zip")
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $freshArchive
Copy-Item -LiteralPath $freshArchive -Destination $archive -Force
Write-Host "Portable OBS plugin: $archive"
