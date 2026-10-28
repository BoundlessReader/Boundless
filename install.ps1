# Boundless Windows installer / updater
# Usage: irm https://raw.githubusercontent.com/BoundlessReader/Boundless/main/install.ps1 | iex
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Repo = 'BoundlessReader/Boundless'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Boundless'
$StartMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Boundless.lnk'

# -- colors & styles ----------------------------------------------------------
# Windows Terminal and PowerShell 7 take ANSI codes as is. Older consoles need
# virtual terminal processing switched on first; if that fails, stay plain.
$script:Ansi = $false
try {
  if (-not [Console]::IsOutputRedirected) {
    Add-Type -Namespace Boundless -Name Vt -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@
    $h = [Boundless.Vt]::GetStdHandle(-11)
    $mode = 0
    if ([Boundless.Vt]::GetConsoleMode($h, [ref]$mode)) {
      $script:Ansi = [Boundless.Vt]::SetConsoleMode($h, $mode -bor 4)
    }
  }
} catch {}

$E = [char]27
function C($code, $text) { if ($script:Ansi) { "$E[${code}m$text$E[0m" } else { $text } }
$Bold = { param($t) C '1' $t }
$Dim = { param($t) C '2' $t }
$Green = { param($t) C '0;32' $t }
$Cyan = { param($t) C '0;36' $t }
$Yellow = { param($t) C '1;33' $t }
$Red = { param($t) C '0;31' $t }
$White = { param($t) C '1;37' $t }

$Check = [string][char]0x2713
$Arrow = [string][char]0x2192
$Cross = [string][char]0x2717
$Dot = [string][char]0xB7

function Clear-Line { if ($script:Ansi) { Write-Host -NoNewline "`r$E[2K" } else { Write-Host -NoNewline ("`r" + (' ' * 78) + "`r") } }
function Ok($m)   { Write-Host ("  " + (& $Green $Check) + "  $m") }
function Info($m) { Write-Host ("  " + (& $Cyan $Arrow) + "  $m") }
function Warn($m) { Write-Host ("  " + (& $Yellow '!') + "  $m") }
function Fail($m) { Write-Host ''; Write-Host ("  " + (& $Red $Cross) + "  $m"); Write-Host ''; throw $m }

# A step that shows "-> label" while it runs, then turns into a tick.
function Step($label, $done, [scriptblock]$work) {
  Write-Host -NoNewline ("  " + (& $Cyan $Arrow) + "  $label")
  try { & $work } catch { Clear-Line; throw }
  Clear-Line
  Ok $done
}

function Ask($question, $default) {
  try {
    $reply = Read-Host "  $question"
    if ([string]::IsNullOrWhiteSpace($reply)) { return $default }
    return $reply
  } catch { return $default }
}

function Format-MB($bytes) { '{0:N1}' -f ($bytes / 1MB) }

function Get-File($url, $dest) {
  Add-Type -AssemblyName System.Net.Http
  $client = New-Object System.Net.Http.HttpClient
  $client.DefaultRequestHeaders.UserAgent.ParseAdd('boundless-installer')
  $client.Timeout = [TimeSpan]::FromMinutes(30)
  try {
    $resp = $client.GetAsync($url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $resp.EnsureSuccessStatusCode() | Out-Null
    $total = $resp.Content.Headers.ContentLength
    $src = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $dst = [IO.File]::Create($dest)
    $buf = New-Object byte[] 262144
    $read = 0L
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $width = 30
    try {
      while (($n = $src.Read($buf, 0, $buf.Length)) -gt 0) {
        $dst.Write($buf, 0, $n)
        $read += $n
        if ($clock.ElapsedMilliseconds -ge 80 -and $total) {
          $clock.Restart()
          $pct = [Math]::Min(1.0, $read / $total)
          $fill = [int][Math]::Floor($pct * $width)
          $bar = (& $Cyan ([string][char]0x2588 * $fill)) + (& $Dim ([string][char]0x2591 * ($width - $fill)))
          Write-Host -NoNewline ("`r  $bar  {0,3}%  $(Format-MB $read) / $(Format-MB $total) MB " -f [int]($pct * 100))
        }
      }
    } finally { $dst.Dispose(); $src.Dispose() }
    Clear-Line
  } finally { $client.Dispose() }
}

function Install-Boundless {
  # -- header -----------------------------------------------------------------
  Write-Host ''
  Write-Host ("  " + (& $White (& $Bold 'Boundless')))
  Write-Host ("  " + (& $Dim "manga $Dot comics $Dot novels"))
  Write-Host ''

  # -- detect arch ------------------------------------------------------------
  $arch = $env:PROCESSOR_ARCHITECTURE
  if ($arch -eq 'AMD64') { Ok 'Detected: x64 (AMD64)' }
  elseif ($arch -eq 'ARM64') { Ok 'Detected: ARM64 (runs the x64 build under emulation)' }
  else { Fail "Boundless for Windows needs a 64-bit PC. Found $arch." }

  if ([Environment]::OSVersion.Version.Major -lt 10) { Fail 'Boundless requires Windows 10 or later.' }

  # The Visual C++ runtime is not bundled with the app.
  if (-not (Test-Path (Join-Path $env:SystemRoot 'System32\vcruntime140.dll'))) {
    Warn 'Microsoft Visual C++ Runtime not found. Install it with:'
    Write-Host ("       " + (& $Dim 'winget install Microsoft.VCRedist.2015+.x64'))
  }

  # -- latest release that ships a Windows build ------------------------------
  $releases = $null
  Step 'Checking for latest release...' 'Release found' {
    try {
      $script:releases = Invoke-RestMethod -Headers @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'boundless-installer' } `
        -Uri "https://api.github.com/repos/$Repo/releases?per_page=30"
    } catch { Fail 'Could not reach GitHub. Check your internet connection.' }
  }
  $release = $null; $asset = $null
  foreach ($r in $script:releases) {
    if ($r.draft) { continue }
    $a = $r.assets | Where-Object { $_.name -like 'boundless-v*-windows-x64.msi' } | Select-Object -First 1
    if ($a) { $release = $r; $asset = $a; break }
  }
  if (-not $asset) { Fail 'No Windows build found in the releases yet.' }
  $latest = $release.tag_name -replace '^(release-)?v', ''
  $sums = $release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1

  # -- check existing install -------------------------------------------------
  $exe = Join-Path $InstallDir 'Boundless.exe'
  $isUpdate = Test-Path $exe
  if ($isUpdate) { Ok ("Update to " + (& $Bold $latest)) }
  else { Ok ("Latest version: " + (& $Bold $latest)) }

  # -- download ---------------------------------------------------------------
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('boundless-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $msi = Join-Path $tmp 'Boundless.msi'
  $wasRunning = $false
  try {
    Write-Host ''
    Write-Host ("  " + (& $Dim "Downloading Boundless $latest..."))
    try { Get-File $asset.browser_download_url $msi } catch { Fail 'Download failed.' }
    Ok ("Downloaded  " + (& $Dim "$(Format-MB (Get-Item $msi).Length) MB"))

    # -- verify the download against the release's checksums -------------------
    if ($sums) {
      Step 'Verifying the download...' 'Checksum matches' {
        $text = (Invoke-WebRequest -UseBasicParsing -Uri $sums.browser_download_url).Content
        if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
        $line = ($text -split "`n") | Where-Object { $_ -match [regex]::Escape($asset.name) } | Select-Object -First 1
        if (-not $line) { Fail 'The release has no checksum for this installer.' }
        $want = ($line.Trim() -split '\s+')[0].ToLower()
        $have = (Get-FileHash -Algorithm SHA256 -Path $msi).Hash.ToLower()
        if ($want -ne $have) { Fail 'The download does not match its checksum. Try again.' }
      }
    }

    # -- quit running instance if present -------------------------------------
    $running = Get-Process -Name boundless -ErrorAction SilentlyContinue
    if ($running) {
      $wasRunning = $true
      Step 'Quitting Boundless...' 'Boundless quit' {
        $running | ForEach-Object { $null = $_.CloseMainWindow() }
        for ($i = 0; $i -lt 25; $i++) {
          if (-not (Get-Process -Name boundless -ErrorAction SilentlyContinue)) { break }
          Start-Sleep -Milliseconds 200
        }
        Get-Process -Name boundless -ErrorAction SilentlyContinue | Stop-Process -Force
      }
    }

    # -- install --------------------------------------------------------------
    Step 'Installing...' "Installed to $InstallDir" {
      # A leftover of the earlier Flutter build would sit beside the new files.
      if (Test-Path (Join-Path $InstallDir 'flutter_windows.dll')) { Remove-Item -Recurse -Force $InstallDir }
      $p = Start-Process msiexec.exe -Wait -PassThru `
        -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart', "INSTALLDIR=`"$InstallDir`"")
      if ($p.ExitCode -ne 0) { Fail "The installer stopped with code $($p.ExitCode)." }
    }
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }

  # -- done -------------------------------------------------------------------
  Write-Host ''
  if ($isUpdate) { Write-Host ("  " + (& $Green (& $Bold "Updated to Boundless $latest."))) }
  else { Write-Host ("  " + (& $Green (& $Bold "Boundless $latest installed."))) }
  Write-Host ''

  if ($wasRunning) { Start-Process $exe -WorkingDirectory $InstallDir }
  else {
    $reply = Ask 'Launch Boundless now? [Y/n]' 'y'
    if ($reply -notmatch '^[Nn]') { Start-Process $exe -WorkingDirectory $InstallDir }
  }
  Write-Host ''
}

Install-Boundless
