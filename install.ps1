# Boundless Windows installer and updater
# Usage: irm https://raw.githubusercontent.com/BoundlessReader/Boundless/main/install.ps1 | iex
#
# Finds the latest release on github.com/BoundlessReader/Boundless, checks the download against the
# SHA-256 the release publishes, closes Boundless, saves a copy of your library and settings, and
# installs the MSI for your user (no administrator prompt). Every run writes a log you can attach
# to a bug report; its path is printed at the end.
#
# Env (set before the command, for example: $env:BOUNDLESS_DEMO = '1'):
#   BOUNDLESS_DEMO=1        preview the installer, download and change nothing
#   BOUNDLESS_PLAIN=1       plain text, no colors or animation
#   BOUNDLESS_NO_ANIM=1     colors but no animation
#   BOUNDLESS_INSTALL_DIR   where to install (default %LOCALAPPDATA%\Programs\Boundless)
#   BOUNDLESS_INSTALL_LOG   where to write the log (default %TEMP%\Boundless-install-<time>.log)
#   BOUNDLESS_BACKUPS       how many library backups to keep (default 5)
#   BOUNDLESS_LOCAL_MSI     install this MSI file instead of downloading one (testing)
& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

  $InstallerVersion = '2.0.0'
  $Repo = 'BoundlessReader/Boundless'
  $DiscordUrl = 'https://discord.gg/BDbk4AYV72'
  $Demo = $env:BOUNDLESS_DEMO -eq '1'
  $LocalMsi = $env:BOUNDLESS_LOCAL_MSI
  $InstallDir = if ($env:BOUNDLESS_INSTALL_DIR) { $env:BOUNDLESS_INSTALL_DIR.TrimEnd('\') } else { Join-Path $env:LOCALAPPDATA 'Programs\Boundless' }
  $DataDir = if ($env:BOUNDLESS_DATA_DIR) { $env:BOUNDLESS_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'Boundless' }
  $Keep = 5
  if ($env:BOUNDLESS_BACKUPS -match '^\d+$') { $Keep = [int]$env:BOUNDLESS_BACKUPS }
  $Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $LogFile = if ($env:BOUNDLESS_INSTALL_LOG) { $env:BOUNDLESS_INSTALL_LOG } else { Join-Path ([IO.Path]::GetTempPath()) "Boundless-install-$Stamp.log" }
  $E = [string][char]27

  function Log([string]$m) {
    try { Add-Content -LiteralPath $LogFile -Value ('{0:HH:mm:ss.fff}  {1}' -f (Get-Date), $m) -Encoding UTF8 } catch {}
  }

  # ---- terminal ---------------------------------------------------------------------------------
  $S = @{
    T = 0; Mode = 'plain'; Anim = $false; Tier = 'plain'; Nap = 45
    Stage = @('pending', 'pending', 'pending', 'pending', 'pending', 'pending')
    Detail = @('', '', '', '', '', '')
    Status = ''; StatusKind = 'txt'; Right = ''; Pct = -1.0
    Foot = @('', '', ''); Menu = $null; Sel = 0; InAlt = $false; NoKeys = $false
  }
  $StageName = @('Check for updates', 'Download', 'Verify checksum', 'Close and back up', 'Install', 'All set')

  $vtOk = $false
  $savedMode = $null
  try {
    if (-not [Console]::IsOutputRedirected) {
      try {
        Add-Type -Namespace Boundless -Name VtInstaller -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@
      } catch {}
      $h = [Boundless.VtInstaller]::GetStdHandle(-11)
      $m = [uint32]0
      if ([Boundless.VtInstaller]::GetConsoleMode($h, [ref]$m)) {
        $savedMode = $m
        $vtOk = [Boundless.VtInstaller]::SetConsoleMode($h, ($m -bor 5))
      }
    }
  } catch {}

  $cols = 80; $rows = 24
  try { $cols = $Host.UI.RawUI.WindowSize.Width; $rows = $Host.UI.RawUI.WindowSize.Height } catch {}
  $isConsoleHost = $Host.Name -eq 'ConsoleHost'
  $wantPlain = ($env:BOUNDLESS_PLAIN -eq '1') -or ($env:NO_COLOR) -or (-not $vtOk) -or (-not $isConsoleHost)
  if (-not $wantPlain) {
    if ($cols -ge 68 -and $rows -ge 38) { $S.Tier = 'full' }
    elseif ($cols -ge 68 -and $rows -ge 29) { $S.Tier = 'mid' }
    elseif ($cols -ge 52 -and $rows -ge 19) { $S.Tier = 'compact' }
    else { $wantPlain = $true }
  }
  if (-not $wantPlain) {
    $S.Mode = 'ui'
    $S.Anim = $env:BOUNDLESS_NO_ANIM -ne '1'
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch {}
  }
  $S.NoKeys = $true
  try { $S.NoKeys = [Console]::IsInputRedirected } catch {}
  if ($Demo -and $S.Mode -eq 'plain') { $S.NoKeys = $true }

  $rich = [bool]($env:WT_SESSION -or $env:TERM_PROGRAM -eq 'vscode' -or $env:ConEmuANSI -eq 'ON')
  function Ch([int]$c) { [string][char]$c }
  $G = @{
    TL = Ch $(if ($rich) { 0x256D } else { 0x250C }); TR = Ch $(if ($rich) { 0x256E } else { 0x2510 })
    BL = Ch $(if ($rich) { 0x2570 } else { 0x2514 }); BR = Ch $(if ($rich) { 0x256F } else { 0x2518 })
    H = Ch 0x2500; V = Ch 0x2502
    Check = Ch $(if ($rich) { 0x2713 } else { 0x221A }); Cross = $(if ($rich) { Ch 0x2717 } else { 'x' })
    Pend = $(if ($rich) { Ch 0x25CB } else { '.' })
    Spin = $(if ($rich) { @((Ch 0x25D0), (Ch 0x25D3), (Ch 0x25D1), (Ch 0x25D2)) } else { @('|', '/', '-', '\') })
    Arrow = 'to'
  }
  $HB = @(' ', (Ch 0x2580), (Ch 0x2584), (Ch 0x2588))
  $WaveH = @((Ch 0x2581), (Ch 0x2582), (Ch 0x2583), (Ch 0x2584), (Ch 0x2585), (Ch 0x2586), (Ch 0x2587), (Ch 0x2588))
  $Full = Ch 0x2588; $Track = Ch 0x2591

  function Fg([int]$r, [int]$g, [int]$b) { "$E[38;2;$r;$g;${b}m" }
  function Bg([int]$r, [int]$g, [int]$b) { "$E[48;2;$r;$g;${b}m" }
  function New-Gradient($stops, [int]$n) {
    $out = New-Object 'string[]' $n
    $seg = $stops.Count - 1
    for ($i = 0; $i -lt $n; $i++) {
      $p = if ($n -gt 1) { $i * $seg / ($n - 1) } else { 0 }
      $k = [Math]::Min([int][Math]::Floor($p), $seg - 1)
      $f = $p - $k
      $a = $stops[$k]; $b = $stops[$k + 1]
      $out[$i] = Fg ([int]($a[0] + ($b[0] - $a[0]) * $f)) ([int]($a[1] + ($b[1] - $a[1]) * $f)) ([int]($a[2] + ($b[2] - $a[2]) * $f))
    }
    $out
  }
  $RS = "$E[0m"
  $cDim = Fg 110 116 160; $cTxt = Fg 223 227 255; $cLav = Fg 167 159 255; $cCy = Fg 95 210 240
  $cErr = Fg 255 120 130; $cOk = Fg 120 230 170; $pillBg = Bg 36 38 78; $pillFg = Fg 212 217 255
  $selBg = Bg 70 60 190; $white = Fg 255 255 255; $bold = "$E[1m"
  $AUR = 72; $WMN = 48
  if ($S.Mode -eq 'ui') {
    $gAur = New-Gradient @(@(59, 43, 214), @(106, 47, 217), @(124, 92, 255), @(95, 210, 240), @(28, 95, 214), @(59, 43, 214)) $AUR
    $gWm = New-Gradient @(@(255, 255, 255), @(217, 220, 255), @(143, 134, 255), @(79, 199, 234)) $WMN
    $gTag = New-Gradient @(@(167, 159, 255), @(95, 210, 240)) 25
    $gBrd = New-Gradient @(@(59, 43, 214), @(124, 92, 255), @(95, 210, 240)) 72
  }

  $MarkRows = @(
    '000000022200000000000000002220000000', '000233333333322000000223333333332000',
    '023331100011133320023331110001133320', '033300000000001333333100000000003330',
    '033300000000002333333200000000003330', '013332200022233310013332220002233310',
    '000133333333311000000113333333331000', '000000011100000000000000001110000000')
  $Glyph = @{
    B = '#####|#...#|#...#|####.|#...#|#...#|####.'; o = '.....|.....|.###.|#...#|#...#|#...#|.###.'
    u = '.....|.....|#...#|#...#|#...#|#..##|.##.#'; n = '.....|.....|#.##.|##..#|#...#|#...#|#...#'
    d = '....#|....#|.####|#...#|#...#|#...#|.####'; l = '##.|.#.|.#.|.#.|.#.|.#.|.##'
    e = '.....|.....|.###.|#...#|#####|#....|.####'; s = '.....|.....|.####|#....|.###.|....#|####.'
  }
  $Glyph['B'] = '####.|#...#|#...#|####.|#...#|#...#|####.'
  $WordRows = $null
  if ($S.Mode -eq 'ui') {
    $word = 'Boundless'
    $px = @('', '', '', '', '', '', '', '')
    for ($i = 0; $i -lt $word.Length; $i++) {
      $parts = $Glyph[[string]$word[$i]].Split('|')
      for ($r = 0; $r -lt 8; $r++) {
        $seg = if ($r -lt 7) { $parts[$r] } else { '.' * $parts[0].Length }
        $px[$r] += $seg + $(if ($i -lt $word.Length - 1) { '.' } else { '' })
      }
    }
    $WordRows = @()
    for ($k = 0; $k -lt 4; $k++) {
      $line = New-Object Text.StringBuilder
      for ($x = 0; $x -lt $px[0].Length; $x++) {
        $t = if ($px[2 * $k][$x] -eq '#') { 1 } else { 0 }
        $b = if ($px[2 * $k + 1][$x] -eq '#') { 2 } else { 0 }
        [void]$line.Append($HB[$t + $b])
      }
      $WordRows += $line.ToString()
    }
  }

  $IW = if ($S.Tier -eq 'compact') { 48 } else { 62 }
  $Tag1 = 'Comics, manga and novels, '
  $Tag2 = 'one liquid glass library.'

  function Trim-To([string]$s, [int]$n) { if ($s.Length -le $n) { $s } elseif ($n -gt 1) { $s.Substring(0, $n - 1) + '~' } else { '' } }

  # ---- drawing ----------------------------------------------------------------------------------
  function New-Row { @{ s = (New-Object Text.StringBuilder); n = 0 } }
  function Put($row, [string]$esc, [string]$text) { [void]$row.s.Append($esc).Append($text); $row.n += $text.Length }

  function Draw {
    $T = $S.T
    $w = $IW
    try { $cols = $Host.UI.RawUI.WindowSize.Width } catch { $cols = 80 }
    $margin = [Math]::Max(0, [int](($cols - ($w + 2)) / 2))
    $pad = ' ' * $margin
    $out = New-Object Text.StringBuilder
    [void]$out.Append("$E[H")
    $shift = if ($S.Anim) { $T * 2 } else { 0 }
    $bi = { param($i) $gBrd[(($i + $shift) % 72 + 72) % 72] }

    function EmitRow($row) {
      [void]$out.Append($pad).Append((& $bi 0)).Append($G.V).Append($RS)
      [void]$out.Append($row.s.ToString()).Append($RS)
      $fill = $w - $row.n
      if ($fill -gt 0) { [void]$out.Append(' ' * $fill) }
      [void]$out.Append((& $bi 40)).Append($G.V).Append($RS).Append("$E[K`n")
    }
    function Blank { EmitRow (New-Row) }
    function Center($row, [int]$len) { $row.s.Append(' ' * [Math]::Max(0, [int](($w - $len) / 2))) | Out-Null; $row.n += [Math]::Max(0, [int](($w - $len) / 2)) }

    $top = New-Object Text.StringBuilder
    [void]$top.Append($pad).Append((& $bi 0)).Append($G.TL)
    for ($i = 0; $i -lt $w; $i++) { [void]$top.Append((& $bi $i)).Append($G.H) }
    [void]$top.Append((& $bi 60)).Append($G.TR).Append($RS).Append("$E[K`n")
    [void]$out.Append($top.ToString())

    Blank
    if ($S.Tier -eq 'full') {
      foreach ($mr in $MarkRows) {
        $row = New-Row
        Center $row 36
        for ($x = 0; $x -lt 36; $x++) {
          $v = [int]([string]$mr[$x])
          if ($v -eq 0) { Put $row '' ' ' } else { Put $row $gAur[(($x * 2 + $shift) % $AUR + $AUR) % $AUR] $HB[$v] }
        }
        EmitRow $row
      }
      Blank
    }
    if ($S.Tier -ne 'compact') {
      for ($k = 0; $k -lt 4; $k++) {
        $row = New-Row
        $len = $WordRows[$k].Length
        Center $row $len
        for ($x = 0; $x -lt $len; $x++) {
          $c = $WordRows[$k][$x]
          if ($c -eq ' ') { Put $row '' ' ' } else { Put $row $gWm[[Math]::Min($WMN - 1, [int]($x * $WMN / $len))] ([string]$c) }
        }
        EmitRow $row
      }
      Blank
      $row = New-Row
      Center $row 51
      Put $row $cTxt $Tag1
      for ($i = 0; $i -lt $Tag2.Length; $i++) { Put $row $gTag[$i] ([string]$Tag2[$i]) }
      EmitRow $row
      Blank
      $row = New-Row
      Center $row 28
      Put $row ($pillBg + $pillFg + $bold) ' SYNC '; Put $row $RS '  '
      Put $row ($pillBg + $pillFg + $bold) ' OFFLINE '; Put $row $RS '  '
      Put $row ($pillBg + $pillFg + $bold) ' STREAKS '
      EmitRow $row
      Blank
    } else {
      $row = New-Row
      Center $row 9
      for ($i = 0; $i -lt 9; $i++) { Put $row $gWm[$i * 5] ([string]'Boundless'[$i]) }
      EmitRow $row
      Blank
    }

    $nameW = 20
    $detW = $w - 3 - 3 - $nameW - 2 - 1
    for ($i = 0; $i -lt 6; $i++) {
      $row = New-Row
      Put $row '' '   '
      switch ($S.Stage[$i]) {
        'done' { Put $row $cCy $G.Check; $nc = $cLav; $bd = '' }
        'active' {
          $idx = (($T * 3 + $i * 5) % $AUR)
          $sp = if ($S.Anim) { $G.Spin[[int]($T / 2) % 4] } else { $G.Spin[0] }
          Put $row $gAur[$idx] $sp; $nc = $cTxt; $bd = $bold
        }
        'error' { Put $row $cErr $G.Cross; $nc = $cErr; $bd = '' }
        default { Put $row $cDim $G.Pend; $nc = $cDim; $bd = '' }
      }
      Put $row '' '  '
      $nm = Trim-To $StageName[$i] $nameW
      Put $row ($nc + $bd) $nm
      Put $row '' (' ' * ($nameW - $nm.Length + 2))
      $dt = Trim-To $S.Detail[$i] $detW
      Put $row $cDim $dt
      EmitRow $row
    }
    Blank

    $row = New-Row
    Put $row '' '   '
    $sc = switch ($S.StatusKind) { 'err' { $cErr } 'ok' { $cOk } default { $cTxt } }
    $st = Trim-To $S.Status ($w - 6 - $S.Right.Length - 2)
    Put $row ($sc + $bold) $st
    $gap = $w - 6 - $st.Length - $S.Right.Length
    if ($gap -gt 0) { Put $row '' (' ' * $gap) }
    Put $row $cDim $S.Right
    Put $row '' '   '
    EmitRow $row

    $row = New-Row
    Put $row '' '   '
    $bw = $w - 6
    $p = $S.Pct
    $filled = if ($p -ge 0) { [int]($bw * $p) } else { 0 }
    for ($i = 0; $i -lt $bw; $i++) {
      if ($p -ge 0 -and $i -lt $filled) {
        $col = $gAur[(($i * 2 + $T * 3) % $AUR + $AUR) % $AUR]
        if ($rich) {
          $hi = [int][Math]::Round(3.5 + 3.4 * [Math]::Sin($i * 0.45 - $(if ($S.Anim) { $T * 0.35 } else { 0 })))
          Put $row $col $WaveH[[Math]::Max(0, [Math]::Min(7, $hi))]
        } else { Put $row $col $Full }
      } elseif ($p -lt 0) {
        $pos = if ($S.Anim) { ($T * 1.1) % ($bw + 16) - 8 } else { $bw / 2 }
        $d = [Math]::Abs($i - $pos)
        if ($d -lt 7) {
          $col = $gAur[(($i * 2 + $T * 3) % $AUR + $AUR) % $AUR]
          if ($rich) { Put $row $col $WaveH[[Math]::Max(0, [Math]::Min(7, 7 - [int]$d))] } else { Put $row $col $Full }
        } else { Put $row $cDim $(if ($rich) { $WaveH[0] } else { $Track }) }
      } else {
        Put $row $cDim $(if ($rich) { $WaveH[0] } else { $Track })
      }
    }
    Put $row '' '   '
    EmitRow $row
    Blank

    for ($i = 0; $i -lt 4; $i++) {
      $row = New-Row
      Put $row '' '   '
      if ($i -eq 3) {
        if ($S.Menu) {
          $used = 0
          for ($m = 0; $m -lt $S.Menu.Count; $m++) {
            $label = ' [' + $S.Menu[$m].k + '] ' + $S.Menu[$m].t + ' '
            if ($used + $label.Length + 1 -gt $w - 6) { break }
            if ($m -eq $S.Sel) { Put $row ($selBg + $white + $bold) $label } else { Put $row $cLav $label }
            Put $row $RS ' '
            $used += $label.Length + 1
          }
        }
      } else {
        $ft = Trim-To $S.Foot[$i] ($w - 6)
        $fc = if ($i -eq 0) { $cLav } else { $cDim }
        if ($S.StatusKind -eq 'err') { $fc = $cTxt }
        Put $row $fc $ft
      }
      EmitRow $row
    }
    Blank

    $bot = New-Object Text.StringBuilder
    [void]$bot.Append($pad).Append((& $bi 0)).Append($G.BL)
    for ($i = 0; $i -lt $w; $i++) { [void]$bot.Append((& $bi $i)).Append($G.H) }
    [void]$bot.Append((& $bi 60)).Append($G.BR).Append($RS).Append("$E[K`n$E[J")
    [void]$out.Append($bot.ToString())
    [Console]::Out.Write($out.ToString())
  }

  function Frame {
    $S.T++
    if ($S.Mode -eq 'ui') { Draw }
    Start-Sleep -Milliseconds $S.Nap
  }

  function Ui-Begin {
    if ($S.Mode -ne 'ui') { return }
    [Console]::Out.Write("$E[?1049h$E[?25l$E[2J$E[H")
    $S.InAlt = $true
  }
  function Ui-End {
    if ($S.InAlt) { [Console]::Out.Write("$E[?25h$E[?1049l"); $S.InAlt = $false }
    if ($savedMode -ne $null) { try { [void][Boundless.VtInstaller]::SetConsoleMode([Boundless.VtInstaller]::GetStdHandle(-11), $savedMode) } catch {} }
  }

  function Say([string]$m) { Write-Host $m }
  function Set-Stage([int]$i, [string]$state, [string]$detail) {
    $S.Stage[$i] = $state
    if ($detail -or $state -eq 'active' -or $state -eq 'error') { $S.Detail[$i] = $detail }
    Log ("stage {0} {1} {2}: {3}" -f $i, $StageName[$i], $state, $detail)
    if ($S.Mode -eq 'plain') {
      if ($state -eq 'active') { Say ('[{0}/6] {1}...' -f ($i + 1), $StageName[$i]) }
      elseif ($state -eq 'done' -and $detail) { Say ('      ' + $detail) }
    }
  }
  function Set-Status([string]$text, [string]$right, [string]$kind) {
    $S.Status = $text; $S.Right = $right; $S.StatusKind = $kind
    if ($S.Mode -eq 'plain' -and $text) { Log ('status: ' + $text) }
  }

  function Wait-Until([scriptblock]$cond, [scriptblock]$each) {
    while (-not (& $cond)) {
      if ($each) { & $each }
      Frame
    }
  }

  function Show-Menu($items) {
    if ($S.NoKeys -or $S.Mode -ne 'ui') { return $null }
    $S.Menu = $items; $S.Sel = 0
    try {
      while ($true) {
        Frame
        while ([Console]::KeyAvailable) {
          $k = [Console]::ReadKey($true)
          switch ($k.Key) {
            'LeftArrow' { $S.Sel = ($S.Sel + $items.Count - 1) % $items.Count }
            'UpArrow' { $S.Sel = ($S.Sel + $items.Count - 1) % $items.Count }
            'RightArrow' { $S.Sel = ($S.Sel + 1) % $items.Count }
            'DownArrow' { $S.Sel = ($S.Sel + 1) % $items.Count }
            'Tab' { $S.Sel = ($S.Sel + 1) % $items.Count }
            'Enter' { return $items[$S.Sel].k }
            'Escape' { return 'Q' }
            default {
              $c = ([string]$k.KeyChar).ToUpper()
              foreach ($it in $items) { if ($it.k -eq $c) { return $it.k } }
            }
          }
        }
      }
    } finally { $S.Menu = $null }
  }

  # ---- state ------------------------------------------------------------------------------------
  $Inst = $null       # what is installed now
  $Latest = $null     # what the release offers
  $FailMark = 'BOUNDLESS_INSTALL_FAILED'
  $S.Result = 'none'

  function Fail([int]$stage, [string]$headline, [string[]]$lines) {
    Log ('FAILED: ' + $headline)
    foreach ($l in $lines) { Log ('  ' + $l) }
    if ($stage -ge 0) { Set-Stage $stage 'error' '' }
    Set-Status $headline '' 'err'
    $S.Pct = 0.0
    $foot = @()
    foreach ($l in $lines) { $foot += $l }
    $foot += ('Log: ' + $LogFile)
    while ($foot.Count -lt 3) { $foot = @('') + $foot }
    $S.Foot = $foot[($foot.Count - 3)..($foot.Count - 1)]
    $S.Result = 'failed'
    if ($S.Mode -eq 'plain') {
      Say ''; Say ('Install failed: ' + $headline)
      foreach ($l in $lines) { Say ('  ' + $l) }
      Say ('Log: ' + $LogFile)
    } else {
      $items = @(@{ k = 'O'; t = 'Open log' }, @{ k = 'D'; t = 'Discord' }, @{ k = 'Q'; t = 'Quit' })
      while ($true) {
        $c = Show-Menu $items
        if ($c -eq 'O') { try { Start-Process notepad.exe -ArgumentList ('"' + $LogFile + '"') } catch {} }
        elseif ($c -eq 'D') { try { Start-Process $DiscordUrl } catch {} }
        else { break }
      }
    }
    throw $FailMark
  }

  # ---- helpers: versions --------------------------------------------------------------------------
  function Get-Installed {
    $r = @{ Found = $false; Version = $null; Build = $null; Code = $null; Dir = $InstallDir; Legacy = $false; Exe = Join-Path $InstallDir 'Boundless.exe' }
    $keys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    foreach ($k in $keys) {
      foreach ($c in (Get-ChildItem $k -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty $c.PSPath -ErrorAction SilentlyContinue
        if ($p.DisplayName -eq 'Boundless' -and ($p.UninstallString -match 'MsiExec')) {
          $r.Found = $true; $r.Version = [string]$p.DisplayVersion
          if ($p.UninstallString -match '(\{[0-9A-Fa-f-]{36}\})') { $r.Code = $Matches[1] }
          if ($p.InstallLocation) { $r.Dir = ([string]$p.InstallLocation).TrimEnd('\') }
        }
      }
    }
    if (-not $r.Found -and (Test-Path -LiteralPath $r.Exe)) {
      $r.Found = $true; $r.Version = [string](Get-Item -LiteralPath $r.Exe).VersionInfo.ProductVersion
    }
    $legacyExe = Join-Path $InstallDir 'boundless.exe'
    if (Test-Path (Join-Path $InstallDir 'flutter_windows.dll')) {
      $r.Found = $true; $r.Legacy = $true
      if (Test-Path -LiteralPath $legacyExe) { $r.Version = [string](Get-Item -LiteralPath $legacyExe).VersionInfo.ProductVersion }
    }
    if ($r.Version -match '^(\d+)\.(\d+)\.(\d+)') { if (-not $r.Legacy) { $r.Build = [int]$Matches[3] } }
    $r
  }
  function Get-VersionCode([string]$body) { if ($body -match 'version code (\d+)') { [int]$Matches[1] } else { $null } }

  function Get-Running {
    $list = @()
    foreach ($p in (Get-Process -Name 'Boundless' -ErrorAction SilentlyContinue)) { $list += $p }
    $list
  }
  function Close-App {
    $running = Get-Running
    if (-not $running) { return $false }
    Log ('closing ' + $running.Count + ' Boundless process(es)')
    foreach ($p in $running) { try { [void]$p.CloseMainWindow() } catch {} }
    $until = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $until -and (Get-Running)) { Frame }
    foreach ($p in (Get-Running)) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {} }
    $until = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $until -and (Get-Running)) { Frame }
    $true
  }

  function Backup-Library([string]$label) {
    $db = Join-Path $DataDir 'boundless.db'
    if (-not (Test-Path -LiteralPath $db)) { return $null }
    $safe = ($label -replace '[^0-9A-Za-z._-]', '_')
    $dest = Join-Path $DataDir ('backups\' + $Stamp + '-' + $safe)
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $bytes = 0
    foreach ($n in 'boundless.db', 'boundless.db-wal', 'boundless.db-shm', 'window.properties') {
      $f = Join-Path $DataDir $n
      if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination $dest -Force; $bytes += (Get-Item -LiteralPath $f).Length }
    }
    foreach ($d in 'preferences', 'secrets') {
      $f = Join-Path $DataDir $d
      if (Test-Path -LiteralPath $f) {
        Copy-Item -LiteralPath $f -Destination $dest -Recurse -Force
        $bytes += (Get-ChildItem -LiteralPath $f -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
      }
    }
    $root = Join-Path $DataDir 'backups'
    foreach ($old in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -Skip $Keep)) {
      try { Remove-Item -LiteralPath $old.FullName -Recurse -Force } catch {}
    }
    Log ('backup: ' + $dest + ' (' + $bytes + ' bytes)')
    @{ Path = $dest; Bytes = $bytes }
  }

  function Format-Size([double]$b) { if ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) } elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) } else { '{0:N0} B' -f $b } }
  function Short-Path([string]$p) {
    if ($env:LOCALAPPDATA -and $p.StartsWith($env:LOCALAPPDATA, [StringComparison]::OrdinalIgnoreCase)) { return '%LOCALAPPDATA%' + $p.Substring($env:LOCALAPPDATA.Length) }
    $p
  }

  # ---- helpers: background work -----------------------------------------------------------------
  function Start-Work([scriptblock]$code, [hashtable]$vars) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    foreach ($k in $vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $vars[$k]) }
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($code)
    @{ Ps = $ps; Rs = $rs; Ar = $ps.BeginInvoke() }
  }
  function Stop-Work($w) { try { $w.Ps.Dispose() } catch {}; try { $w.Rs.Dispose() } catch {} }

  $CheckCode = {
    $ErrorActionPreference = 'Stop'
    try {
      $r = Invoke-RestMethod -Headers @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'boundless-installer' } -Uri $url
      $sync.releases = $r
      $sync.code = 200
    } catch {
      $sync.code = 0
      try { $sync.code = [int]$_.Exception.Response.StatusCode } catch {}
      $sync.error = $_.Exception.Message
    }
    $sync.done = $true
  }
  $DownloadCode = {
    $ErrorActionPreference = 'Stop'
    try {
      Add-Type -AssemblyName System.Net.Http
      $c = New-Object System.Net.Http.HttpClient
      $c.Timeout = [TimeSpan]::FromMinutes(40)
      $c.DefaultRequestHeaders.UserAgent.ParseAdd('boundless-installer')
      $resp = $c.GetAsync($url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
      [void]$resp.EnsureSuccessStatusCode()
      $len = $resp.Content.Headers.ContentLength
      if ($len) { $sync.total = [double]$len }
      $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
      $out = [IO.File]::Create($dest)
      try {
        $buf = New-Object byte[] 262144
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
          $out.Write($buf, 0, $n)
          $sync.bytes = $sync.bytes + $n
        }
      } finally { $out.Close(); $in.Close() }
      $sync.ok = $true
    } catch { $sync.error = $_.Exception.Message }
    $sync.done = $true
  }
  $VerifyCode = {
    $ErrorActionPreference = 'Stop'
    try {
      $sync.hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLower()
      if (-not $digest -and $sumsUrl) {
        $text = (Invoke-WebRequest -UseBasicParsing -Uri $sumsUrl -Headers @{ 'User-Agent' = 'boundless-installer' }).Content
        if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
        foreach ($line in ($text -split "`n")) {
          if ($line -match [regex]::Escape($name)) { $sync.want = ($line.Trim() -split '\s+')[0].ToLower(); break }
        }
      }
    } catch { $sync.error = $_.Exception.Message }
    $sync.done = $true
  }

  # ---- msiexec ------------------------------------------------------------------------------------
  function Run-Msiexec([string]$arguments) {
    Log ('msiexec ' + $arguments)
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -PassThru -WindowStyle Hidden
    $null = $p.Handle
    $t0 = Get-Date
    while (-not $p.HasExited) {
      $S.Right = ('{0:N0}s' -f ((Get-Date) - $t0).TotalSeconds)
      Frame
    }
    $p.WaitForExit()
    $code = $p.ExitCode
    Log ('msiexec exit ' + $code)
    $code
  }
  function Read-LogText([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { [Text.Encoding]::Unicode.GetString($bytes) }
    else { [Text.Encoding]::Default.GetString($bytes) }
  }
  function Get-MsiProblem([string]$path) {
    $text = Read-LogText $path
    if (-not $text) { return @() }
    $lines = $text -split "`r?`n"
    $found = @()
    foreach ($l in $lines) {
      if ($l -match 'Error (\d{4})\.' -or $l -match 'returned actual error code (\d+)' -or $l -match 'cannot access the file' -or $l -match 'being used by another process') {
        $t = ($l -replace '^\s*MSI \([sc]\) \([0-9A-F:]+\) \[[0-9:]+\]:\s*', '').Trim()
        if ($t -and ($found -notcontains $t)) { $found += $t }
      }
    }
    if ($found.Count -gt 3) { $found = $found[0..2] }
    $tail = $lines | Select-Object -Last 40
    Log ('--- msi log tail (' + $path + ') ---')
    foreach ($t in $tail) { Log ('  ' + $t) }
    $found
  }
  function Explain-Code([int]$code) {
    switch ($code) {
      1602 { 'The install was cancelled.' }
      1603 { 'Windows Installer hit a fatal error (1603).' }
      1618 { 'Another install is already running (1618). Wait for it to finish.' }
      1619 { 'The installer file could not be opened (1619).' }
      1620 { 'The installer file is damaged (1620).' }
      1622 { 'The installer log could not be written (1622).' }
      1625 { 'This computer blocks the install by policy (1625).' }
      1638 { 'Another version of Boundless is installed (1638).' }
      1925 { 'This needs administrator rights (1925).' }
      default { 'Windows Installer stopped with code ' + $code + '.' }
    }
  }

  # ---- the run --------------------------------------------------------------------------------------
  Log ('Boundless installer ' + $InstallerVersion + ' on ' + [Environment]::OSVersion.VersionString + ', PowerShell ' + $PSVersionTable.PSVersion + ', mode ' + $S.Mode + '/' + $S.Tier + ', demo ' + $Demo)
  Log ('install dir ' + $InstallDir + ', data dir ' + $DataDir)
  Log ('terminal: vt ' + $vtOk + ', host ' + $Host.Name + ', size ' + $cols + 'x' + $rows + ', NO_COLOR ' + [bool]$env:NO_COLOR + ', plain env ' + $env:BOUNDLESS_PLAIN + ', output redirected ' + [Console]::IsOutputRedirected)
  try {
    if ([Environment]::OSVersion.Version.Major -lt 10) { Write-Host 'Boundless needs Windows 10 or later.'; return }
    if (-not [Environment]::Is64BitOperatingSystem) { Write-Host 'Boundless for Windows needs a 64-bit PC.'; return }
    Ui-Begin
    if ($S.Mode -eq 'plain') { Say ''; Say ('Boundless installer ' + $InstallerVersion + $(if ($Demo) { ' (demo, nothing is changed)' } else { '' })) }
    for ($i = 0; $i -lt 8 -and $S.Mode -eq 'ui'; $i++) { Frame }

    # 1. check
    Set-Stage 0 'active' 'contacting GitHub'
    Set-Status 'Checking for the latest version' '' 'txt'
    $S.Pct = -1.0
    $Inst = Get-Installed
    if ($Inst.Found -and -not $env:BOUNDLESS_INSTALL_DIR -and $Inst.Dir -and (Test-Path -LiteralPath $Inst.Dir)) { $InstallDir = $Inst.Dir }
    $tag = $null; $latestVer = $null; $latestBuild = $null; $asset = $null; $sumsAsset = $null; $buildToTag = @{}
    if ($Demo) {
      $until = $S.T + 40
      Wait-Until { $S.T -ge $until } $null
      $latestVer = '3.5.0'; $tag = 'v3.5.0'; $latestBuild = 180
      $Inst = @{ Found = $true; Version = '3.4.171'; Build = 171; Code = $null; Dir = $InstallDir; Legacy = $false; Exe = Join-Path $InstallDir 'Boundless.exe' }
      $buildToTag[171] = '3.4.2'
      $asset = @{ name = 'boundless-v3.5.0-windows-x64.msi'; size = 304149171; browser_download_url = ''; digest = $null }
    } elseif ($LocalMsi) {
      $latestVer = 'local'; $tag = 'vlocal'
      $asset = @{ name = (Split-Path $LocalMsi -Leaf); size = (Get-Item -LiteralPath $LocalMsi).Length; browser_download_url = ''; digest = $null }
      Log ('local msi ' + $LocalMsi)
    } else {
      $sync = [hashtable]::Synchronized(@{ done = $false; code = 0 })
      $job = Start-Work $CheckCode @{ sync = $sync; url = "https://api.github.com/repos/$Repo/releases?per_page=30" }
      Wait-Until { $sync.done } $null
      Stop-Work $job
      if ($sync.code -ne 200) {
        if ($sync.code -eq 403 -or $sync.code -eq 429) { Fail 0 'GitHub is limiting requests from this network.' @('Wait a few minutes and run the installer again.') }
        Fail 0 'Could not reach GitHub.' @('Check your internet connection and try again.', ([string]$sync.error))
      }
      $rel = $null
      foreach ($r in $sync.releases) {
        if ($r.draft) { continue }
        $a = $r.assets | Where-Object { $_.name -like 'boundless-v*-windows-x64.msi' } | Select-Object -First 1
        if ($a) {
          $bc = Get-VersionCode ([string]$r.body)
          $tg = ([string]$r.tag_name) -replace '^(release-)?v', ''
          if ($bc) { $buildToTag[$bc] = $tg }
          if (-not $rel) { $rel = $r; $asset = $a; $latestBuild = $bc }
        }
      }
      if (-not $asset) { Fail 0 'This release has no Windows download yet.' @('Try again later, or ask in the Discord.') }
      $tag = [string]$rel.tag_name
      $latestVer = $tag -replace '^(release-)?v', ''
      if ($tag -notmatch '^[0-9A-Za-z._-]+$') { Fail 0 'GitHub sent a release this installer does not understand.' @($tag) }
      if ($asset.browser_download_url -notlike "https://github.com/$Repo/releases/download/*") { Fail 0 'The release points somewhere unexpected, so nothing was downloaded.' @([string]$asset.browser_download_url) }
      $sumsAsset = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' } | Select-Object -First 1
    }
    $instLabel = $null
    if ($Inst.Found) {
      if ($Inst.Legacy) { $instLabel = [string]$Inst.Version + ' (older app)' }
      elseif ($Inst.Build -and $buildToTag.ContainsKey([int]$Inst.Build)) { $instLabel = [string]$buildToTag[[int]$Inst.Build] }
      else { $instLabel = [string]$Inst.Version }
    }
    Log ('installed: ' + $(if ($Inst.Found) { $instLabel + ' (product ' + $Inst.Version + ', code ' + $Inst.Code + ', legacy ' + $Inst.Legacy + ')' } else { 'none' }))
    Log ('latest: ' + $latestVer + ' (build ' + $latestBuild + ')')

    $relation = 'fresh'
    if ($Inst.Found) {
      if ($Inst.Legacy) { $relation = 'update' }
      elseif ($latestBuild -and $Inst.Build) {
        if ($Inst.Build -eq $latestBuild) { $relation = 'same' } elseif ($Inst.Build -gt $latestBuild) { $relation = 'newer' } else { $relation = 'update' }
      } elseif ($instLabel -eq $latestVer) { $relation = 'same' }
      else { $relation = 'update' }
    }
    if ($relation -eq 'update') { Set-Stage 0 'done' ($instLabel + '  ' + $G.Arrow + '  ' + $latestVer) }
    else { Set-Stage 0 'done' ('Boundless ' + $latestVer) }

    if ($env:BOUNDLESS_CHECK_ONLY -eq '1') {
      $S.Result = 'checked'
      $S.Note = ('installed: ' + $(if ($Inst.Found) { $instLabel + ' (product ' + $Inst.Version + ')' } else { 'none' }) + ' | latest: ' + $latestVer + ' (build ' + $latestBuild + ') | relation: ' + $relation + ' | dir: ' + $InstallDir)
      return
    }
    $Reinstall = $false
    if ($relation -eq 'same' -or $relation -eq 'newer') {
      if ($env:BOUNDLESS_REINSTALL -eq '1') { $Reinstall = $true }
      if (-not $Reinstall) {
        $skipText = @('', 'Nothing to download', 'Up to date', 'Nothing to change', 'Already installed')
        for ($i = 1; $i -le 4; $i++) { Set-Stage $i 'done' $skipText[$i] }
        Set-Stage 5 'done' 'Ready to read'
      }
      $S.Pct = 1.0
      if ($relation -eq 'same') { Set-Status ('Boundless ' + $latestVer + ' is already installed') '' 'ok' }
      else { Set-Status ('You have a newer build (' + $instLabel + ') than the latest release (' + $latestVer + ')') '' 'ok' }
      $S.Foot = @('Reinstall repairs the app and keeps your library.', ('Log: ' + $LogFile), '')
      if ($env:BOUNDLESS_REINSTALL -eq '1') { $Reinstall = $true }
      if ($S.Mode -eq 'plain' -and -not $Reinstall) { Say ('Boundless ' + $instLabel + ' is installed, the latest release is ' + $latestVer + '. Nothing to do.'); $S.Result = 'same'; return }
      $items = @(@{ k = 'L'; t = 'Launch Boundless' }, @{ k = 'R'; t = 'Reinstall' }, @{ k = 'N'; t = "What's new" }, @{ k = 'Q'; t = 'Quit' })
      while (-not $Reinstall) {
        $c = Show-Menu $items
        if ($c -eq 'L') { if (-not $Demo) { try { Start-Process $Inst.Exe -WorkingDirectory $Inst.Dir } catch {} }; break }
        elseif ($c -eq 'N') { try { Start-Process ("https://github.com/$Repo/releases/tag/$tag") } catch {} }
        elseif ($c -eq 'R') { $Reinstall = $true; break }
        else { break }
      }
      if (-not $Reinstall) { $S.Result = 'same'; return }
      for ($i = 1; $i -le 5; $i++) { $S.Stage[$i] = 'pending'; $S.Detail[$i] = '' }
      $S.Foot = @('', '', '')
    }

    # 2. download
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('boundless-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $msi = Join-Path $tmp 'Boundless.msi'
    try {
      $total = [double]$asset.size
      Set-Stage 1 'active' 'starting'
      Set-Status ('Downloading Boundless ' + $latestVer) '0%' 'txt'
      $S.Pct = 0.0
      if ($Demo) {
        $t0 = $S.T; $span = 90
        Wait-Until { ($S.T - $t0) -ge $span } {
          $f = [Math]::Min(1.0, ($S.T - $t0) / $span)
          $S.Pct = $f
          $S.Right = ('{0:N0}%   {1}/s' -f ($f * 100), (Format-Size (6.2MB)))
          $S.Detail[1] = ('{0} of {1}' -f (Format-Size ($total * $f)), (Format-Size $total))
        }
      } elseif ($LocalMsi) {
        Copy-Item -LiteralPath $LocalMsi -Destination $msi -Force
        $S.Pct = 1.0
      } else {
        $sync = [hashtable]::Synchronized(@{ done = $false; bytes = [double]0; total = $total; ok = $false })
        $job = Start-Work $DownloadCode @{ sync = $sync; url = [string]$asset.browser_download_url; dest = $msi }
        $dl = @{ lastT = (Get-Date); lastB = [double]0; speed = [double]0 }
        Wait-Until { $sync.done } {
          $now = Get-Date
          $dt = ($now - $dl.lastT).TotalSeconds
          if ($dt -ge 0.4) {
            $instant = ($sync.bytes - $dl.lastB) / $dt
            $dl.speed = if ($dl.speed -eq 0) { $instant } else { $dl.speed * 0.8 + $instant * 0.2 }
            $dl.lastT = $now; $dl.lastB = $sync.bytes
          }
          $speed = $dl.speed
          $tot = [double]$sync.total
          if ($tot -gt 0) {
            $f = [Math]::Min(1.0, $sync.bytes / $tot)
            $S.Pct = $f
            $eta = if ($speed -gt 1) { [int](($tot - $sync.bytes) / $speed) } else { 0 }
            $etaText = if ($speed -gt 1) { '{0}:{1:00}' -f [int][Math]::Floor($eta / 60), ($eta % 60) } else { '--:--' }
            $S.Right = ('{0:N0}%   {1}/s   {2}' -f ($f * 100), (Format-Size $speed), $etaText)
            $S.Detail[1] = ('{0} of {1}' -f (Format-Size $sync.bytes), (Format-Size $tot))
          }
        }
        Stop-Work $job
        if (-not $sync.ok) { Fail 1 'The download did not finish.' @('Check your connection and run the installer again.', ([string]$sync.error)) }
      }
      Set-Stage 1 'done' (Format-Size $total)
      $S.Right = '100%'

      # 3. verify
      Set-Stage 2 'active' 'SHA-256'
      Set-Status 'Verifying the download' '' 'txt'
      $S.Pct = -1.0; $S.Right = ''
      if ($Demo) {
        $until = $S.T + 30
        Wait-Until { $S.T -ge $until } $null
        Set-Stage 2 'done' 'Checksum matches'
      } elseif ($LocalMsi) {
        Set-Stage 2 'done' 'Local file, not checked'
      } else {
        $digest = ''
        if ($asset.digest -and ([string]$asset.digest) -match '^sha256:([0-9a-f]{64})$') { $digest = $Matches[1] }
        $sync = [hashtable]::Synchronized(@{ done = $false })
        $job = Start-Work $VerifyCode @{ sync = $sync; file = $msi; digest = $digest; sumsUrl = $(if ($sumsAsset) { [string]$sumsAsset.browser_download_url } else { '' }); name = [string]$asset.name }
        Wait-Until { $sync.done } $null
        Stop-Work $job
        if ($sync.error) { Fail 2 'Could not check the download.' @([string]$sync.error) }
        $want = if ($digest) { $digest } else { [string]$sync.want }
        if ($want) {
          if ($want -ne $sync.hash) { Fail 2 'The download does not match its published checksum.' @('Nothing was installed. Run the installer again.') }
          Set-Stage 2 'done' 'Checksum matches'
        } else {
          Set-Stage 2 'done' 'No checksum published'
        }
      }

      # 4. close and back up
      Set-Stage 3 'active' 'checking'
      Set-Status 'Closing Boundless and saving your library' '' 'txt'
      $S.Pct = -1.0
      $detail = ''
      if ($Demo) {
        $until = $S.T + 36
        Wait-Until { $S.T -ge $until } $null
        $detail = 'Library saved, 2.0 MB'
      } else {
        $closed = Close-App
        $bk = $null
        try { $bk = Backup-Library $(if ($instLabel) { $instLabel } else { 'first' }) } catch { Log ('backup failed: ' + $_.Exception.Message) }
        if ($bk) { $detail = 'Library saved, ' + (Format-Size $bk.Bytes) }
        elseif (Test-Path -LiteralPath (Join-Path $DataDir 'boundless.db')) { $detail = 'Backup skipped, see the log' }
        else { $detail = 'No library to save yet' }
        if ($closed) { $detail = 'Closed the app. ' + $detail }
      }
      Set-Stage 3 'done' $detail

      # 5. install
      Set-Stage 4 'active' 'starting'
      Set-Status ('Installing Boundless ' + $latestVer) '' 'txt'
      $S.Pct = -1.0
      if ($Demo) {
        $until = $S.T + 70
        Wait-Until { $S.T -ge $until } $null
        if ($env:BOUNDLESS_DEMO_FAIL -eq '1') { Fail 4 'The installer could not finish.' @('Windows Installer hit a fatal error (1603).', 'Close Boundless and the installer window, then retry.') }
      } else {
        $msiLog = Join-Path ([IO.Path]::GetTempPath()) ('Boundless-msi-' + $Stamp + '.log')
        $installArgs = '/i "' + $msi + '" /qn /norestart INSTALLDIR="' + $InstallDir + '" /l*v "' + $msiLog + '"'
        $uninstallArgs = $(if ($Inst.Code) { '/x ' + $Inst.Code + ' /qn /norestart /l*v "' + (Join-Path ([IO.Path]::GetTempPath()) ('Boundless-msi-remove-' + $Stamp + '.log')) + '"' } else { $null })
        $S.Detail[4] = Short-Path $InstallDir
        $code = 0
        if ($Reinstall -and $uninstallArgs) {
          $S.Detail[4] = 'removing the old copy'
          [void](Run-Msiexec $uninstallArgs)
          $S.Detail[4] = Short-Path $InstallDir
        }
        $busy = 0
        while ($true) {
          $code = Run-Msiexec $installArgs
          if ($code -eq 1618 -and $busy -lt 3) { $busy++; $S.Detail[4] = 'waiting for another install'; $until = (Get-Date).AddSeconds(15); while ((Get-Date) -lt $until) { Frame }; continue }
          break
        }
        if ($code -ne 0 -and $code -ne 3010 -and $code -ne 1641) {
          Log ('first attempt failed with ' + $code + ', cleaning up and trying again')
          [void](Get-MsiProblem $msiLog)
          $S.Detail[4] = 'cleaning up and trying again'
          [void](Close-App)
          if ($uninstallArgs) { [void](Run-Msiexec $uninstallArgs) }
          if ((Test-Path -LiteralPath $InstallDir) -and ((Test-Path (Join-Path $InstallDir 'Boundless.exe')) -or (Test-Path (Join-Path $InstallDir 'boundless.exe')) -or (Test-Path (Join-Path $InstallDir 'flutter_windows.dll')))) {
            try { Remove-Item -LiteralPath $InstallDir -Recurse -Force } catch { Log ('could not remove ' + $InstallDir + ': ' + $_.Exception.Message) }
          }
          $S.Detail[4] = Short-Path $InstallDir
          $msiLog2 = Join-Path ([IO.Path]::GetTempPath()) ('Boundless-msi-retry-' + $Stamp + '.log')
          $code = Run-Msiexec ('/i "' + $msi + '" /qn /norestart INSTALLDIR="' + $InstallDir + '" /l*v "' + $msiLog2 + '"')
          if ($code -ne 0 -and $code -ne 3010 -and $code -ne 1641) {
            $why = Get-MsiProblem $msiLog2
            $lines = @((Explain-Code $code)) + @($why)
            if ($code -eq 1603 -or $code -eq 1925) { $lines += 'Close Boundless and the installer window, then retry.' }
            $lines = $lines | Select-Object -First 2
            Fail 4 'The installer could not finish.' $lines
          }
        }
        $newExe = Join-Path $InstallDir 'Boundless.exe'
        if (-not (Test-Path -LiteralPath $newExe)) { Fail 4 'The install finished but Boundless.exe is missing.' @('See the log: ' + $LogFile) }
        Log ('installed ' + (Get-Item -LiteralPath $newExe).VersionInfo.ProductVersion)
      }
      Set-Stage 4 'done' (Short-Path $InstallDir)
    } finally {
      if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # 6. done
    Set-Stage 5 'done' 'Ready to read'
    $S.Pct = 1.0; $S.Right = ''
    if ($Demo) { Set-Status 'Demo complete, nothing was installed' '' 'ok' }
    elseif ($relation -eq 'update') { Set-Status ('Updated to Boundless ' + $latestVer) '' 'ok' }
    else { Set-Status ('Boundless ' + $latestVer + ' is installed') '' 'ok' }
    $S.Foot = @('Open Boundless from the Start menu or the button below.', 'Your library and settings live in %LOCALAPPDATA%\Boundless.', ('Log: ' + $LogFile))
    $S.Result = 'installed'
    if ($S.Mode -eq 'plain') {
      Say ''; Say ($S.Status + '.')
      if (-not $Demo -and -not $S.NoKeys) {
        $reply = Read-Host 'Launch Boundless now? [Y/n]'
        if ($reply -notmatch '^[Nn]') { try { Start-Process (Join-Path $InstallDir 'Boundless.exe') -WorkingDirectory $InstallDir } catch {} }
      }
      return
    }
    $items = @(@{ k = 'L'; t = 'Launch Boundless' }, @{ k = 'N'; t = "What's new" }, @{ k = 'D'; t = 'Discord' }, @{ k = 'Q'; t = 'Quit' })
    if ($S.NoKeys) { for ($i = 0; $i -lt 10; $i++) { Frame }; return }
    while ($true) {
      $c = Show-Menu $items
      if ($c -eq 'L') { if (-not $Demo) { try { Start-Process (Join-Path $InstallDir 'Boundless.exe') -WorkingDirectory $InstallDir } catch {} }; break }
      elseif ($c -eq 'N') { try { Start-Process ("https://github.com/$Repo/releases/tag/$tag") } catch {} }
      elseif ($c -eq 'D') { try { Start-Process $DiscordUrl } catch {} }
      else { break }
    }
  } catch {
    if ($_.Exception.Message -ne $FailMark -and "$_" -ne $FailMark) {
      Log ('UNEXPECTED: ' + $_.Exception.Message)
      Log ($_.ScriptStackTrace)
      $S.Result = 'failed'
      try { $S.Mode = 'plain' } catch {}
      Ui-End
      Write-Host ''
      Write-Host ('Install failed: ' + $_.Exception.Message)
    }
  } finally {
    Ui-End
    if ($S.Result -eq 'installed' -and $Demo) { Write-Host ''; Write-Host ('Demo finished, nothing was changed. Log: ' + $LogFile) }
    elseif ($S.Result -eq 'installed') { Write-Host ''; Write-Host ('Boundless is installed. Log: ' + $LogFile) }
    elseif ($S.Result -eq 'failed') { Write-Host ''; Write-Host ('Boundless was not installed. Log: ' + $LogFile) }
    elseif ($S.Result -eq 'same') { Write-Host ''; Write-Host ('Boundless is up to date. Log: ' + $LogFile) }
    elseif ($S.Result -eq 'checked') { Write-Host $S.Note }
  }
}
