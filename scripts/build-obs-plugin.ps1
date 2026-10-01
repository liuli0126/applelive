param(
  [string]$Python = "python",
  [switch]$SkipSender,
  [switch]$SkipDock
)

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$sender = Join-Path $projectRoot "desktop_sender\sender.py"
$output = Join-Path $projectRoot "obs-plugin"
$build = Join-Path $projectRoot ".build\obs-plugin"

if (-not $SkipSender) {
  & $Python -m PyInstaller --noconfirm --clean --onefile --noconsole `
  --name AppleLiveSender --distpath $output --workpath $build `
  --specpath $build $sender
if ($LASTEXITCODE -ne 0) { throw "PyInstaller build failed" }
}

if (-not $SkipDock) {
  & $Python -m PyInstaller --noconfirm --clean --onefile --noconsole `
  --name AppleLiveDock --distpath $output --workpath (Join-Path $build "dock") `
  --specpath $build (Join-Path $projectRoot "desktop_sender\dock_server.py")
if ($LASTEXITCODE -ne 0) { throw "Dock build failed" }
}

Copy-Item -LiteralPath (Join-Path $projectRoot "desktop_sender\usb_forward.ps1") `
  -Destination (Join-Path $output "usb_forward.ps1") -Force

Write-Host "OBS plugin files: $output"
Write-Host "Load AppleLive.lua from OBS Tools > Scripts. Keep AppleLiveSender.exe next to it."

$artifactDirectory = Join-Path $projectRoot "artifacts"
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
$archive = Join-Path $artifactDirectory "AppleLive-OBS-Windows.zip"
Compress-Archive -LiteralPath @(
  (Join-Path $output "AppleLive.lua"),
  (Join-Path $output "AppleLiveSender.exe"),
  (Join-Path $output "AppleLiveDock.exe"),
  (Join-Path $output "dock"),
  (Join-Path $output "usb_forward.ps1"),
  (Join-Path $output "README.md")
) -DestinationPath $archive -Force
Write-Host "Portable OBS plugin: $archive"
