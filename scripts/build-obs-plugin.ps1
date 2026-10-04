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
foreach ($item in @(
  (Join-Path $output "AppleLive.lua"),
  (Join-Path $output "AppleLiveDock.exe"),
  (Join-Path $output "dock"),
  (Join-Path $output "setup_lan.ps1"),
  (Join-Path $output "install_or_update.ps1"),
  (Join-Path $output "VERSION.txt"),
  (Join-Path $output "README.md")
)) {
  Copy-Item -LiteralPath $item -Destination $stage -Recurse -Force
}
Get-ChildItem -LiteralPath $output -Filter "*.cmd" -File |
  Copy-Item -Destination $stage -Force
New-Item -ItemType Directory -Path (Join-Path $stage "server"), (Join-Path $stage "phone-plugin") -Force | Out-Null
foreach ($name in @("mediamtx.exe", "mediamtx.yml", "LICENSE")) {
  Copy-Item -LiteralPath (Join-Path $output "server\$name") -Destination (Join-Path $stage "server\$name") -Force
}
foreach ($name in @("FFmpeg-LICENSE.txt", "FFmpeg-SOURCE.txt", "fishhook-LICENSE.txt")) {
  Copy-Item -LiteralPath (Join-Path $output "phone-plugin\$name") -Destination (Join-Path $stage "phone-plugin\$name") -Force
}
Copy-Item -LiteralPath $PhonePlugin -Destination (Join-Path $stage "phone-plugin\AppleLive.dylib") -Force
$digest = (Get-FileHash -LiteralPath $PhonePlugin -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath (Join-Path $stage "phone-plugin\SHA256.txt") -Value "$digest  AppleLive.dylib" -Encoding ascii
$freshArchive = Join-Path $build ("AppleLive-OBS-" + [guid]::NewGuid().ToString("N") + ".zip")
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $freshArchive
Copy-Item -LiteralPath $freshArchive -Destination $archive -Force
Write-Host "Portable OBS plugin: $archive"
