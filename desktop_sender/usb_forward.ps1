param(
  [int]$Port = 8765,
  [string]$Device = ""
)

# pymobiledevice3's documented `usbmux forward` direction is PC -> iPhone.
# AppleLive's default transport is iPhone -> PC, so a jailbreak-side reverse
# socket daemon is required for USB. Do not silently run the opposite direction
# and report a false success.
if (-not (Get-Command pymobiledevice3 -ErrorAction SilentlyContinue)) {
  throw "Install pymobiledevice3 first: python -m pip install -U pymobiledevice3"
}

Write-Host "AppleLive USB requires a jailbreak-side reverse TCP tunnel for device 127.0.0.1:$Port."
Write-Host "pymobiledevice3 usbmux forward is PC-to-device and cannot replace that reverse tunnel."
Write-Host "Start the reverse service supplied by your jailbreak, then set the tweak server to 127.0.0.1:$Port."
Write-Host "LAN mode does not need this step: python sender.py --host 0.0.0.0 --port $Port"
exit 2
