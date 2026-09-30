param(
  [string]$Python = "python"
)

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$sender = Join-Path $projectRoot "desktop_sender\sender.py"
$output = Join-Path $projectRoot "obs-plugin"
$build = Join-Path $projectRoot ".build\obs-plugin"

& $Python -m PyInstaller --noconfirm --clean --onefile --noconsole `
  --name AppleLiveSender --distpath $output --workpath $build `
  --specpath $build $sender
if ($LASTEXITCODE -ne 0) { throw "PyInstaller build failed" }

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
  (Join-Path $output "usb_forward.ps1"),
  (Join-Path $output "README.md")
) -DestinationPath $archive -Force
Write-Host "Portable OBS plugin: $archive"
