$ErrorActionPreference = 'Stop'
$rules = @(
  @{ Name = 'AppleLive LAN RTMP'; Ports = '1935' },
  @{ Name = 'AppleLive LAN RTSP'; Ports = '8554' }
)

foreach ($rule in $rules) {
  Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $rule.Ports -Profile Any -RemoteAddress Any | Out-Null
}

$machineGuid = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'lan-access.ok') `
  -Value "AppleLiveLAN2:$machineGuid" -Encoding ascii
Write-Host "AppleLive LAN access is enabled."
