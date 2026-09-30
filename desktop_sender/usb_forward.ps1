param(
  [int]$Port = 8765,
  [int]$ForwardPort = 2222,
  [string]$Device = ""
)

$ErrorActionPreference = "Stop"

$python = (python -c "import sys; print(sys.executable)").Trim()
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $python)) {
  throw "Python is unavailable."
}
& $python -m pymobiledevice3 usbmux --help *> $null
if ($LASTEXITCODE -ne 0) {
  throw "pymobiledevice3 is unavailable. Install it with: python -m pip install pymobiledevice3"
}
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
  throw "Windows OpenSSH client (ssh.exe) is unavailable."
}

$devices = @(& $python -m pymobiledevice3 usbmux list | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or $devices.Count -eq 0) {
  throw "No iPhone is connected over USB or trusted by this PC."
}
if (-not $Device) {
  if ($devices.Count -ne 1) { throw "Multiple iPhones connected. Specify -Device with the UDID." }
  $Device = $devices[0].UniqueDeviceID
}
if ($Device -notmatch '^[A-Za-z0-9-]+$') { throw "Invalid device UDID." }
if ($Port -lt 1024 -or $Port -gt 65535 -or $ForwardPort -lt 1024 -or $ForwardPort -gt 65535) {
  throw "Ports must be between 1024 and 65535."
}

$forwarder = Start-Process -FilePath $python -ArgumentList @(
  "-m", "pymobiledevice3", "usbmux", "forward", "$ForwardPort", "22", "--serial", $Device
) -PassThru -WindowStyle Hidden
try {
  Start-Sleep -Milliseconds 700
  $forwarder.Refresh()
  if ($forwarder.HasExited) { throw "USB port forwarding could not start. Check the cable and device trust." }
  Write-Host "USB connected: $Device"
  Write-Host "Opening an SSH reverse tunnel to iPhone port 8765. Keep this window open."
  Write-Host "The iPhone needs OpenSSH from Cydia. Its password is entered only in the SSH prompt."
  & ssh -p $ForwardPort -o "HostKeyAlias=applelive-$Device" `
    -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes `
    -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 `
    -N -T -R "127.0.0.1:8765:127.0.0.1:$Port" root@127.0.0.1
  if ($LASTEXITCODE -ne 0) {
    throw "USB tunnel failed. Verify OpenSSH is installed and running on the iPhone, then retry."
  }
} finally {
  if (-not $forwarder.HasExited) { Stop-Process -Id $forwarder.Id -Force }
}
