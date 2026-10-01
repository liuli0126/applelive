param(
  [int]$Port = 8765,
  [int]$ForwardPort = 2222,
  [string]$Device = "",
  [int]$ObsPid = 0,
  [switch]$SingleAttempt
)

$ErrorActionPreference = "Stop"

if ($Port -lt 1024 -or $Port -gt 65535 -or $ForwardPort -lt 1024 -or $ForwardPort -gt 65535) {
  throw "Ports must be between 1024 and 65535."
}
if ($Device -and $Device -notmatch '^[A-Za-z0-9-]+$') { throw "Invalid device UDID." }

# Standalone USB is owned by the packaged sender; SSH is only for paired legacy debs.
$legacyKeyDirectory = Join-Path $env:USERPROFILE '.ssh'
if ($Device) {
  $hasLegacyKey = Test-Path -LiteralPath (Join-Path $legacyKeyDirectory "applelive-$Device") -PathType Leaf
} else {
  $hasLegacyKey = [bool](Get-ChildItem -LiteralPath $legacyKeyDirectory -Filter 'applelive-*' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^applelive-[A-Za-z0-9-]+$' } | Select-Object -First 1)
}
if (-not $hasLegacyKey) { exit 0 }

# One supervisor per USB route. A failed forwarding process or SSH connection
# is retried automatically; repeated OBS Start clicks do not spawn duplicates.
if (-not $SingleAttempt) {
  $mutex = [Threading.Mutex]::new($false, "Local\AppleLive-USB-$ForwardPort-$Port")
  $ownsMutex = $false
  $attempt = $null
  try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { exit 0 }
    $attemptArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -SingleAttempt -Port ' + $Port + ' -ForwardPort ' + $ForwardPort
    if ($Device) { $attemptArguments += ' -Device ' + $Device }
    while ($ObsPid -eq 0 -or (Get-Process -Id $ObsPid -ErrorAction SilentlyContinue)) {
      $attempt = Start-Process -FilePath 'powershell.exe' -ArgumentList $attemptArguments -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $PSScriptRoot 'applelive-usb.log') `
        -RedirectStandardError (Join-Path $PSScriptRoot 'applelive-usb-error.log')
      while (-not $attempt.HasExited) {
        if ($ObsPid -gt 0 -and -not (Get-Process -Id $ObsPid -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Seconds 1
      }
      if (-not $attempt.HasExited) { break }
      $attempt.Dispose()
      $attempt = $null
      Start-Sleep -Seconds 2
    }
  } finally {
    if ($attempt) {
      # Only the process tree started above belongs to this supervisor.
      if (-not $attempt.HasExited) { & taskkill.exe /PID $attempt.Id /T /F *> $null }
      $attempt.Dispose()
    }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
  exit 0
}

# Reuse a paired tunnel started earlier by AppleLive instead of competing for port 2222.
$existingTunnel = Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" | Where-Object {
  $_.CommandLine -match 'HostKeyAlias=applelive-' -and
  $_.CommandLine -match ([regex]::Escape("127.0.0.1:8765:127.0.0.1:$Port") + '(?:\s|"|$)')
} | Select-Object -First 1
if ($existingTunnel) {
  $listener = Get-NetTCPConnection -LocalPort $ForwardPort -State Listen -ErrorAction SilentlyContinue
  $transport = Get-NetTCPConnection -OwningProcess $existingTunnel.ProcessId -State Established -ErrorAction SilentlyContinue |
    Where-Object { $_.RemoteAddress -eq '127.0.0.1' -and $_.RemotePort -eq $ForwardPort }
  if ($listener -and $transport) { Write-Host "AppleLive USB tunnel is already running."; exit 0 }
  # This exact AppleLive SSH command has lost its USB transport. It cannot be reused.
  Stop-Process -Id $existingTunnel.ProcessId -ErrorAction SilentlyContinue
}

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

$deviceJson = & $python -m pymobiledevice3 usbmux list
$parsedDevices = $deviceJson | ConvertFrom-Json
$devices = @($parsedDevices | Where-Object { $_ -and $_.UniqueDeviceID -and $_.ConnectionType -eq 'USB' })
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

$identityPath = Join-Path $env:USERPROFILE ".ssh\applelive-$Device"
$identityArgs = @()
if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
  $identityArgs = @("-i", $identityPath, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes")
} else {
  throw "USB SSH key pairing is required before automatic connection."
}

$forwarder = Start-Process -FilePath $python -ArgumentList @(
  "-m", "pymobiledevice3", "usbmux", "forward", "$ForwardPort", "22", "--serial", $Device
) -PassThru -WindowStyle Hidden
try {
  $deadline = [DateTime]::UtcNow.AddSeconds(12)
  $listening = $false
  while (-not $forwarder.HasExited -and [DateTime]::UtcNow -lt $deadline) {
    $listening = [bool](Get-NetTCPConnection -LocalPort $ForwardPort -State Listen -ErrorAction SilentlyContinue |
      Where-Object { $_.OwningProcess -eq $forwarder.Id })
    if ($listening) { break }
    Start-Sleep -Milliseconds 200
  }
  if (-not $listening) { throw "USB port forwarding could not start. Check the cable and device trust." }
  Write-Host "USB connected: $Device"
  Write-Host "Opening an SSH reverse tunnel to iPhone port 8765. Keep this window open."
  if ($identityArgs.Count) {
    Write-Host "Using this PC's paired iPhone key."
  } else {
    Write-Host "The iPhone needs OpenSSH from Cydia. Its password is entered only in the SSH prompt."
  }
  & ssh @identityArgs -p $ForwardPort -o "HostKeyAlias=applelive-$Device" `
    -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes `
    -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 `
    -N -T -R "127.0.0.1:8765:127.0.0.1:$Port" mobile@127.0.0.1
  if ($LASTEXITCODE -ne 0) {
    throw "USB tunnel failed. Verify OpenSSH is installed and running on the iPhone, then retry."
  }
} finally {
  if (-not $forwarder.HasExited) { Stop-Process -Id $forwarder.Id -Force }
}
