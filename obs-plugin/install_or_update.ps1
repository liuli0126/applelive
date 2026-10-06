param(
  [string]$ObsRoot = "",
  [string]$ConfigRoot = "",
  [switch]$NoElevation,
  [switch]$NoLaunch,
  [switch]$Embedded
)

$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
$required = @(
  'AppleLive.lua',
  'AppleLiveDock.exe',
  'AppleLiveSender.exe',
  'ffmpeg.exe',
  'dock\index.html',
  'server\mediamtx.exe',
  'server\mediamtx.yml',
  'phone-plugin\AppleLive.dylib'
)

foreach ($name in $required) {
  if (-not (Test-Path -LiteralPath (Join-Path $source $name))) {
    throw "The update package is incomplete: $name"
  }
}

function Get-ObsExecutable([string]$root) {
  if (-not $root) { return $null }
  if ($root.StartsWith('\\?\')) { $root = $root.Substring(4) }
  $bin = Join-Path $root 'bin\64bit'
  $standard = Join-Path $bin 'obs64.exe'
  if ([IO.File]::Exists($standard)) { return [IO.Path]::GetFullPath($standard) }
  if (-not (Test-Path -LiteralPath $bin)) { return $null }

  $custom = Get-ChildItem -LiteralPath $bin -Filter '*.exe' -File -ErrorAction SilentlyContinue |
    Where-Object {
      $_.VersionInfo.ProductName -eq 'OBS Studio' -or
      $_.VersionInfo.FileDescription -eq 'OBS Studio'
    } |
    Select-Object -First 1
  if ($custom) { return $custom.FullName }

  # Some custom portable distributions rename the OBS launcher (for example
  # AuxCam or a localized obs*.exe) while keeping the normal OBS bin/data
  # layout. Accept an explicit launcher-shaped name after checking the normal
  # ProductName, while excluding OBS helper/test executables.
  $renamed = Get-ChildItem -LiteralPath $bin -File -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -match '^(obs|AuxCam).*\.exe$' -and
      $_.Name -notmatch '(?i)(test|browser|ffmpeg|nvenc|qsv)'
    } |
    Select-Object -First 1
  if ($renamed) { return $renamed.FullName }
  return $null
}

function Convert-ToObsRoot([string]$path) {
  if (-not $path) { return $null }
  if ($path.StartsWith('\\?\')) { $path = $path.Substring(4) }
  try { $item = Get-Item -LiteralPath $path -ErrorAction Stop } catch { return $null }
  $candidate = if ($item.PSIsContainer) { $item.FullName } else { $item.DirectoryName }
  for ($index = 0; $index -lt 5 -and $candidate; $index++) {
    if (Get-ObsExecutable $candidate) { return $candidate }
    $candidate = Split-Path -Parent $candidate
  }
  return $null
}

function Set-JsonProperty($object, [string]$name, $value) {
  $property = $object.PSObject.Properties[$name]
  if ($property) {
    $property.Value = $value
  } else {
    $object | Add-Member -MemberType NoteProperty -Name $name -Value $value
  }
}

function Write-Utf8Json([string]$path, $value) {
  $temporary = "$path.applelive.tmp"
  $json = ConvertTo-Json -InputObject $value -Depth 100 -Compress
  [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
  [void](ConvertFrom-Json ([IO.File]::ReadAllText($temporary)))
  Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Get-IniValue([string]$path, [string]$section, [string]$key) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $current = ''
  foreach ($line in [IO.File]::ReadAllLines($path)) {
    if ($line -match '^\s*\[(.+)\]\s*$') {
      $current = $Matches[1]
    } elseif ($current -eq $section -and $line.StartsWith("$key=", [StringComparison]::OrdinalIgnoreCase)) {
      return $line.Substring($line.IndexOf('=') + 1)
    }
  }
  return $null
}

function Set-IniValue([string]$path, [string]$section, [string]$key, [string]$value) {
  $lines = New-Object 'Collections.Generic.List[string]'
  if (Test-Path -LiteralPath $path) {
    foreach ($line in [IO.File]::ReadAllLines($path)) { [void]$lines.Add($line) }
  }

  $sectionIndex = -1
  $sectionEnd = $lines.Count
  $keyIndex = -1
  for ($index = 0; $index -lt $lines.Count; $index++) {
    if ($lines[$index] -match '^\s*\[(.+)\]\s*$') {
      if ($sectionIndex -ge 0) { $sectionEnd = $index; break }
      if ($Matches[1] -eq $section) { $sectionIndex = $index }
    } elseif ($sectionIndex -ge 0 -and $lines[$index].StartsWith("$key=", [StringComparison]::OrdinalIgnoreCase)) {
      $keyIndex = $index
    }
  }

  $entry = "$key=$value"
  if ($keyIndex -ge 0) {
    $lines[$keyIndex] = $entry
  } elseif ($sectionIndex -ge 0) {
    $lines.Insert($sectionEnd, $entry)
  } else {
    if ($lines.Count -and $lines[$lines.Count - 1]) { [void]$lines.Add('') }
    [void]$lines.Add("[$section]")
    [void]$lines.Add($entry)
  }
  [IO.File]::WriteAllText($path, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($false)))
}

function Get-ObsConfigRoot([string]$root, [string]$requested) {
  if ($requested) {
    New-Item -ItemType Directory -Path $requested -Force | Out-Null
    return (Resolve-Path -LiteralPath $requested).Path
  }
  $portable = Join-Path $root 'config\obs-studio'
  if ((Test-Path -LiteralPath $portable) -or
      (Test-Path -LiteralPath (Join-Path $root 'portable_mode')) -or
      (Test-Path -LiteralPath (Join-Path $root 'portable_mode.txt'))) {
    New-Item -ItemType Directory -Path $portable -Force | Out-Null
    return (Resolve-Path -LiteralPath $portable).Path
  }
  if (-not $env:APPDATA) { throw 'The current Windows account has no APPDATA folder.' }
  $roaming = Join-Path $env:APPDATA 'obs-studio'
  New-Item -ItemType Directory -Path $roaming -Force | Out-Null
  return (Resolve-Path -LiteralPath $roaming).Path
}

function Register-AppleLiveScript([string]$root, [string]$scriptPath) {
  $sceneDirectory = Join-Path $root 'basic\scenes'
  if (-not (Test-Path -LiteralPath $sceneDirectory)) { return 0 }
  $normalizedPath = $scriptPath.Replace('\', '/')
  $count = 0
  foreach ($scenePath in Get-ChildItem -LiteralPath $sceneDirectory -Filter '*.json' -File) {
    $scene = ConvertFrom-Json ([IO.File]::ReadAllText($scenePath.FullName))
    if (-not $scene.modules) {
      Set-JsonProperty $scene 'modules' ([pscustomobject]@{})
    }
    $scriptsProperty = $scene.modules.PSObject.Properties['scripts-tool']
    $scripts = if ($scriptsProperty) { @($scriptsProperty.Value) } else { @() }
    $kept = @()
    $savedSettings = $null
    foreach ($entry in $scripts) {
      $entryPath = [string]$entry.path
      if ([IO.Path]::GetFileName($entryPath) -ieq 'AppleLive.lua') {
        if ($null -eq $savedSettings -and $null -ne $entry.settings) { $savedSettings = $entry.settings }
      } else {
        $kept += $entry
      }
    }
    if ($null -eq $savedSettings) { $savedSettings = [pscustomobject]@{} }
    $kept += [pscustomobject][ordered]@{ path = $normalizedPath; settings = $savedSettings }
    Set-JsonProperty $scene.modules 'scripts-tool' @($kept)
    $backup = "$($scenePath.FullName).applelive-backup"
    if (-not (Test-Path -LiteralPath $backup)) {
      Copy-Item -LiteralPath $scenePath.FullName -Destination $backup
    }
    Write-Utf8Json $scenePath.FullName $scene
    $count++
  }
  return $count
}

function Register-AppleLiveDock([string]$root) {
  $path = Join-Path $root 'global.ini'
  $value = Get-IniValue $path 'BasicWindow' 'ExtraBrowserDocks'
  $docks = @()
  $uuid = $null
  if ($value) {
    $parsedDocks = ConvertFrom-Json $value
    foreach ($dock in $parsedDocks) {
      if ($dock.title -eq 'AppleLive' -or $dock.url -eq 'http://127.0.0.1:18765/') {
        if (-not $uuid -and $dock.uuid) { $uuid = [string]$dock.uuid }
      } else {
        $docks += $dock
      }
    }
  }
  if (-not $uuid) { $uuid = [Guid]::NewGuid().ToString('N') }
  $docks += [pscustomobject][ordered]@{
    title = 'AppleLive'
    url = 'http://127.0.0.1:18765/'
    uuid = $uuid
  }
  $json = ConvertTo-Json -InputObject @($docks) -Compress
  $backup = "$path.applelive-backup"
  if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $path -Destination $backup
  }
  Set-IniValue $path 'BasicWindow' 'ExtraBrowserDocks' $json
}

function Enable-ObsWebSocket([string]$root) {
  $directory = Join-Path $root 'plugin_config\obs-websocket'
  $path = Join-Path $directory 'config.json'
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
  $config = if (Test-Path -LiteralPath $path) {
    ConvertFrom-Json ([IO.File]::ReadAllText($path))
  } else {
    [pscustomobject]@{}
  }
  Set-JsonProperty $config 'server_enabled' $true
  Set-JsonProperty $config 'first_load' $false
  if (-not $config.PSObject.Properties['server_port']) { Set-JsonProperty $config 'server_port' 4455 }
  if (-not $config.PSObject.Properties['auth_required']) { Set-JsonProperty $config 'auth_required' $true }
  if ($config.auth_required -and -not $config.server_password) {
    Set-JsonProperty $config 'server_password' ([Guid]::NewGuid().ToString('N'))
  }
  $backup = "$path.applelive-backup"
  if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $path -Destination $backup
  }
  Write-Utf8Json $path $config
}

function Find-ObsRootFromSavedState {
  if ($env:LOCALAPPDATA) {
    $marker = Join-Path $env:LOCALAPPDATA 'AppleLive\obs-root.txt'
    if (Test-Path -LiteralPath $marker) {
      $savedRoot = Convert-ToObsRoot ([IO.File]::ReadAllText($marker).Trim())
      if ($savedRoot) { return $savedRoot }
    }
  }
  if (-not $env:APPDATA) { return $null }
  $sceneDirectory = Join-Path $env:APPDATA 'obs-studio\basic\scenes'
  if (-not (Test-Path -LiteralPath $sceneDirectory)) { return $null }
  foreach ($scenePath in Get-ChildItem -LiteralPath $sceneDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue) {
    try {
      $scene = ConvertFrom-Json ([IO.File]::ReadAllText($scenePath.FullName))
      if (-not $scene.modules) { continue }
      $scriptsProperty = $scene.modules.PSObject.Properties['scripts-tool']
      if (-not $scriptsProperty) { continue }
      foreach ($entry in @($scriptsProperty.Value)) {
        if ([IO.Path]::GetFileName([string]$entry.path) -ieq 'AppleLive.lua') {
          $savedRoot = Convert-ToObsRoot ([string]$entry.path)
          if ($savedRoot) { return $savedRoot }
        }
      }
    } catch {
      continue
    }
  }
  return $null
}

if (-not $ObsRoot) {
  $running = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      if (-not $_.ExecutablePath) { return $false }
      $root = Convert-ToObsRoot $_.ExecutablePath
      if (-not $root) { return $false }
      $main = Get-ObsExecutable $root
      return $main -and $main.Equals($_.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)
    } |
    Select-Object -First 1
  if ($running) { $ObsRoot = Convert-ToObsRoot $running.ExecutablePath }
}

if (-not $ObsRoot) { $ObsRoot = Find-ObsRootFromSavedState }
if (-not $ObsRoot) { $ObsRoot = Convert-ToObsRoot $source }
if (-not $ObsRoot) {
  foreach ($candidate in @(
    "$env:ProgramFiles\obs-studio",
    "${env:ProgramFiles(x86)}\obs-studio",
    'C:\obs-studio',
    'D:\obs-studio'
  )) {
    $ObsRoot = Convert-ToObsRoot $candidate
    if ($ObsRoot) { break }
  }
}

if (-not $ObsRoot -and -not $NoLaunch) {
  Add-Type -AssemblyName System.Windows.Forms
  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  $dialog.Description = 'Select the OBS Studio installation folder'
  if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $ObsRoot = Convert-ToObsRoot $dialog.SelectedPath
  }
}

if (-not $ObsRoot) { throw 'OBS Studio was not found. Select the OBS folder that contains bin\64bit.' }
$ObsRoot = (Resolve-Path -LiteralPath $ObsRoot).Path
$obsExe = Get-ObsExecutable $ObsRoot
$target = Join-Path $ObsRoot 'data\obs-plugins\AppleLive'
$ConfigRoot = Get-ObsConfigRoot $ObsRoot $ConfigRoot
if (-not $Embedded -and $source.TrimEnd('\').Equals($target.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Run this updater from a newly extracted package outside the OBS installation folder.'
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoElevation) {
  $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ObsRoot `"$ObsRoot`""
  $arguments += " -ConfigRoot `"$ConfigRoot`""
  if ($NoLaunch) { $arguments += ' -NoLaunch' }
  if ($Embedded) { $arguments += ' -Embedded' }
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -WorkingDirectory $source | Out-Null
  exit 0
}

$obsProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object {
    $_.ExecutablePath -and
    $obsExe.Equals($_.ExecutablePath, [StringComparison]::OrdinalIgnoreCase)
  })
foreach ($entry in $obsProcesses) {
  try { [Diagnostics.Process]::GetProcessById($entry.ProcessId).CloseMainWindow() | Out-Null } catch {}
}
if ($obsProcesses.Count) {
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  do {
    Start-Sleep -Milliseconds 250
    $remaining = @($obsProcesses | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
  } while ($remaining.Count -and [DateTime]::UtcNow -lt $deadline)
  if ($remaining.Count) { throw 'Close OBS Studio and run the updater again.' }
}

$targetPrefix = $target.TrimEnd('\') + '\'
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object {
    $_.Name -in @('AppleLiveDock.exe', 'AppleLiveSender.exe', 'AppleLiveUsbRelay.exe', 'ffmpeg.exe', 'mediamtx.exe') -and
    $_.ExecutablePath -and $_.ExecutablePath.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)
  } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

New-Item -ItemType Directory -Path $target -Force | Out-Null
if (-not $Embedded) {
  foreach ($directory in @('dock', 'server', 'phone-plugin')) {
    $destination = Join-Path $target $directory
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $source $directory) -Destination $destination -Recurse -Force
  }
  foreach ($file in @(
    'AppleLive.lua',
    'AppleLiveDock.exe',
    'AppleLiveSender.exe',
    'ffmpeg.exe',
    'README.md',
    'setup_lan.ps1',
    'install_or_update.ps1',
    'Install-AppleLive.cmd',
    'VERSION.txt'
  )) {
    Copy-Item -LiteralPath (Join-Path $source $file) -Destination (Join-Path $target $file) -Force
  }

  foreach ($stale in @(
    'usb_forward.ps1',
    'applelive-bridge.json',
    'applelive-command.json',
  'applelive-sender.log',
  'applelive-status.json',
  'applelive-stop.flag',
  'applelive-usb-error.log',
  'unicode-launch.log',
  'lan-access.ok'
)) {
    Remove-Item -LiteralPath (Join-Path $target $stale) -Force -ErrorAction SilentlyContinue
  }
  $nativeRelay = Join-Path $source 'AppleLiveUsbRelay.exe'
  if (Test-Path -LiteralPath $nativeRelay) {
    Copy-Item -LiteralPath $nativeRelay -Destination (Join-Path $target 'AppleLiveUsbRelay.exe') -Force
  }
  $nativeOutput = Join-Path $source 'applelive-native-output.dll'
  if (Test-Path -LiteralPath $nativeOutput) {
    $nativeTarget = Join-Path $ObsRoot 'obs-plugins\64bit'
    New-Item -ItemType Directory -Path $nativeTarget -Force | Out-Null
    Copy-Item -LiteralPath $nativeOutput -Destination (Join-Path $nativeTarget 'applelive-native-output.dll') -Force
    Unblock-File -LiteralPath (Join-Path $nativeTarget 'applelive-native-output.dll') -ErrorAction SilentlyContinue
  }
}

Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
$resolvedConfigRoot = $ConfigRoot
$registeredScenes = Register-AppleLiveScript $resolvedConfigRoot (Join-Path $target 'AppleLive.lua')
Register-AppleLiveDock $resolvedConfigRoot
Enable-ObsWebSocket $resolvedConfigRoot
if (-not ($Embedded -and $NoLaunch)) {
  $stateDirectory = Join-Path $env:LOCALAPPDATA 'AppleLive'
  New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $stateDirectory 'obs-root.txt'), $ObsRoot, (New-Object Text.UTF8Encoding($false)))
}
$version = (Get-Content -LiteralPath (Join-Path $source 'VERSION.txt') -Raw).Trim()
Write-Host "AppleLive $version installed to: $target"
Write-Host "OBS configured at: $resolvedConfigRoot ($registeredScenes scene collection(s))"

if (-not $NoLaunch) {
  Start-Process -FilePath $obsExe -WorkingDirectory (Split-Path -Parent $obsExe)
}
