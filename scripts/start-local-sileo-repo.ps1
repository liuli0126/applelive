param()
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$pythonPath = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python314\python.exe'
if (-not (Test-Path -LiteralPath $pythonPath)) { $pythonPath = (Get-Command python -ErrorAction Stop).Source }
$route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' |
  Where-Object { $_.NextHop -ne '0.0.0.0' } | Sort-Object RouteMetric | Select-Object -First 1
if (-not $route) { throw 'No LAN route was found.' }
$address = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex |
  Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1 -ExpandProperty IPAddress
$repo = Join-Path $workspace '.build\sileo-repo'
if (-not (Test-Path -LiteralPath (Join-Path $repo 'Packages'))) { throw 'The local Sileo source is missing.' }
Write-Host ''
Write-Host 'AppleLive Sileo source - keep this window open while installing.' -ForegroundColor Cyan
Write-Host "Add this URL in Sileo on the phone: http://${address}:18766/" -ForegroundColor Green
Write-Host 'Search: AppleLive USB Capture Service  (version 0.1.1)'
Write-Host 'Close this window after phone installation to stop sharing.'
Write-Host ''
& $pythonPath -u (Join-Path $PSScriptRoot 'local-sileo-repo.py') serve --root $repo --bind $address --port 18766
if ($LASTEXITCODE -ne 0) { throw "Source server stopped with exit code $LASTEXITCODE" }
