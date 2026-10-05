# Boundless Windows installer / updater
# Usage: irm https://raw.githubusercontent.com/BoundlessReader/Boundless/main/install.ps1 | iex
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Repo = 'BoundlessReader/Boundless'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Boundless'
$StartMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Boundless.lnk'

function Ok($m)   { Write-Host '  ' -NoNewline; Write-Host ([char]0x2713) -ForegroundColor Green -NoNewline; Write-Host "  $m" }
function Info($m) { Write-Host '  ' -NoNewline; Write-Host ([char]0x2192) -ForegroundColor Cyan -NoNewline; Write-Host "  $m" }
function Warn($m) { Write-Host '  ' -NoNewline; Write-Host '!' -ForegroundColor Yellow -NoNewline; Write-Host "  $m" }
function Fail($m) { Write-Host ''; Write-Host '  ' -NoNewline; Write-Host ([char]0x2717) -ForegroundColor Red -NoNewline; Write-Host "  $m"; Write-Host ''; throw $m }

function Install-Boundless {
  Write-Host ''
  Write-Host '  Boundless' -ForegroundColor White
  Write-Host ('  manga ' + [char]0xB7 + ' comics ' + [char]0xB7 + ' novels') -ForegroundColor DarkGray
  Write-Host ''

  # detect arch
  $arch = $env:PROCESSOR_ARCHITECTURE
  if ($arch -eq 'AMD64') { Ok 'Detected: x64 (AMD64)' }
  elseif ($arch -eq 'ARM64') { Ok 'Detected: ARM64 (runs the x64 build under emulation)' }
  else { Fail "Boundless for Windows needs a 64-bit PC. Found $arch." }

  if ([Environment]::OSVersion.Version.Major -lt 10) { Fail 'Boundless requires Windows 10 or later.' }

  # the Visual C++ runtime is not bundled with the app
  if (-not (Test-Path (Join-Path $env:SystemRoot 'System32\vcruntime140.dll'))) {
    Warn 'Microsoft Visual C++ Runtime not found. Install it with:'
    Write-Host '       winget install Microsoft.VCRedist.2015+.x64'
  }

  # latest release that ships a Windows build
  Info 'Checking for latest release...'
  try {
    $releases = Invoke-RestMethod -Headers @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'boundless-installer' } `
      -Uri "https://api.github.com/repos/$Repo/releases?per_page=30"
  } catch { Fail 'Could not reach GitHub. Check your internet connection.' }

  $release = $null; $asset = $null
  foreach ($r in $releases) {
    if ($r.draft) { continue }
    $a = $r.assets | Where-Object { $_.name -like 'boundless-v*-windows-x64.zip' } | Select-Object -First 1
    if ($a) { $release = $r; $asset = $a; break }
  }
  if (-not $asset) { Fail 'No Windows build found in the releases yet.' }
  $latest = $release.tag_name -replace '^(release-)?v', ''

  # existing install
  $exe = Join-Path $InstallDir 'boundless.exe'
  $isUpdate = $false
  if (Test-Path $exe) {
    $installed = ((Get-Item $exe).VersionInfo.ProductVersion -split '\.')[0..2] -join '.'
    if ($installed -eq $latest) {
      Warn "Boundless $latest is already installed."
      $reply = Read-Host '  Reinstall anyway? [y/N]'
      if ($reply -notmatch '^[Yy]') { Write-Host ''; Write-Host '  Nothing to do.'; Write-Host ''; return }
    } else {
      $isUpdate = $true
      Ok "Update: $installed  $([char]0x2192)  $latest"
    }
  } else {
    Ok "Latest version: $latest"
  }

  # download
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("boundless-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $zip = Join-Path $tmp 'Boundless.zip'
  try {
    Write-Host ''
    Write-Host "  Downloading Boundless $latest..." -ForegroundColor DarkGray
    & curl.exe -fL --progress-bar -o $zip $asset.browser_download_url
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zip)) { Fail 'Download failed.' }
    Ok 'Downloaded'

    # quit a running instance
    $running = Get-Process -Name boundless -ErrorAction SilentlyContinue
    $wasRunning = [bool]$running
    if ($running) {
      Info 'Quitting Boundless...'
      $running | ForEach-Object { $null = $_.CloseMainWindow() }
      Start-Sleep -Seconds 3
      Get-Process -Name boundless -ErrorAction SilentlyContinue | Stop-Process -Force
      Ok 'Boundless quit'
    }

    # install
    Info "Installing to $InstallDir..."
    if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Expand-Archive -Path $zip -DestinationPath $InstallDir -Force
    Ok 'Installed'

    # Start Menu shortcut
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($StartMenu)
    $lnk.TargetPath = $exe
    $lnk.WorkingDirectory = $InstallDir
    $lnk.IconLocation = "$exe,0"
    $lnk.Save()
    Ok 'Added to the Start menu'
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }

  Write-Host ''
  if ($isUpdate) { Write-Host "  Updated to Boundless $latest." -ForegroundColor Green }
  else { Write-Host "  Boundless $latest installed." -ForegroundColor Green }
  Write-Host ''

  if ($wasRunning) { Start-Process $exe -WorkingDirectory $InstallDir }
  else {
    $reply = Read-Host '  Launch Boundless now? [Y/n]'
    if ($reply -notmatch '^[Nn]') { Start-Process $exe -WorkingDirectory $InstallDir }
  }
  Write-Host ''
}

Install-Boundless
