param(
  [ValidateRange(1, 65535)]
  [int]$VideoPort = 8765
)

$ErrorActionPreference = 'Stop'
$rules = @(
  @{ Name = 'AppleLive LAN plugin download'; Ports = "$VideoPort" },
  @{ Name = 'AppleLive LAN RTMP'; Ports = '1935' }
)

Get-NetFirewallRule -DisplayName 'AppleLive LAN video', 'AppleLive LAN RTSP' -ErrorAction SilentlyContinue |
  Remove-NetFirewallRule

foreach ($rule in $rules) {
  Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $rule.Ports -Profile Any -RemoteAddress LocalSubnet | Out-Null
}

Write-Host "AppleLive LAN access is enabled for this computer's local subnet."
