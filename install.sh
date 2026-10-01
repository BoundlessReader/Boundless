#!/bin/bash
# Boundless macOS installer and updater
# Usage: bash <(curl -fsSL "https://raw.githubusercontent.com/BoundlessReader/Boundless/main/install.sh")
#
# Downloads the latest release from github.com/BoundlessReader/Boundless, checks it
# against the SHA-256 GitHub publishes for the file and replaces Boundless.app.
#
# Flags: --demo (preview, changes nothing) --discord --no-anim --plain --help --version
# Env:   BOUNDLESS_INSTALL_DIR (default /Applications), NO_COLOR, BOUNDLESS_NO_ANIM
# Test hooks: BOUNDLESS_FAKE_UNAME=<uname -s output>, BOUNDLESS_FAKE_WSL=1
set -euo pipefail

INSTALLER_VERSION="2.0.0"
REPO="BoundlessReader/Boundless"
DISCORD_URL="https://discord.gg/BDbk4AYV72"
DISCORD_API="https://discord.com/api/v10/invites/BDbk4AYV72?with_counts=true"
INSTALL_DIR="${BOUNDLESS_INSTALL_DIR:-/Applications}"
DEMO="${BOUNDLESS_DEMO:-0}"
NO_ANIM="${BOUNDLESS_NO_ANIM:-0}"
DISCORD_ONLY=0
FORCE_PLAIN=0

usage() {
  cat <<'EOF'
Boundless installer

Usage: bash install.sh [options]

  --demo       Preview the installer without downloading or changing anything
  --discord    Open the Boundless Discord invite
  --no-anim    Skip the animations
  --plain      Plain text output, no colors
  --version    Show the installer version
  -h, --help   Show this help

Set BOUNDLESS_INSTALL_DIR to install somewhere other than /Applications.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --demo) DEMO=1 ;;
    --discord) DISCORD_ONLY=1 ;;
    --no-anim) NO_ANIM=1 ;;
    --plain) FORCE_PLAIN=1 ;;
    --version) echo "Boundless installer $INSTALLER_VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

# ── platform ──────────────────────────────────────────────────────────────────
UNAME_S="${BOUNDLESS_FAKE_UNAME:-$(uname -s)}"
OS_KIND=mac
if [ "${BOUNDLESS_FAKE_WSL:-0}" = 1 ]; then
  OS_KIND=windows
else
  case "$UNAME_S" in
    Darwin) ;;
    MINGW*|MSYS*|CYGWIN*) OS_KIND=windows ;;
    Linux)
      if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
        OS_KIND=windows
      else
        OS_KIND=other
      fi ;;
    *) OS_KIND=other ;;
  esac
fi

# ── terminal capabilities ─────────────────────────────────────────────────────
ESC=$'\033'
R="${ESC}[0m"

utf8_ok() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-UTF-8}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) return 0 ;;
    *) return 1 ;;
  esac
}

MODE=anim
if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ] || [ "${TERM:-dumb}" = dumb ] || [ "$FORCE_PLAIN" = 1 ] || ! utf8_ok; then
  MODE=plain
elif [ "$NO_ANIM" = 1 ]; then
  MODE=still
fi

ROWS=24; COLS=80; TIER=full
if [ "$MODE" != plain ]; then
  sz=$(stty size 2>/dev/null </dev/tty || stty size 2>/dev/null || true)
  ROWS=${sz%% *}; COLS=${sz##* }
  case "$ROWS$COLS" in ''|*[!0-9]*) ROWS=24; COLS=80 ;; esac
  [ "$ROWS" -gt 0 ] || ROWS=24
  [ "$COLS" -gt 0 ] || COLS=80
  if [ "$COLS" -ge 80 ] && [ "$ROWS" -ge 25 ]; then TIER=full
  elif [ "$COLS" -ge 58 ] && [ "$ROWS" -ge 23 ]; then TIER=mid
  elif [ "$COLS" -ge 40 ] && [ "$ROWS" -ge 17 ]; then TIER=compact
  else MODE=plain
  fi
fi

CT=16
case "${TERM:-}" in *256color*|*kitty*|*ghostty*|*alacritty*|*wezterm*|*direct*) CT=256 ;; esac
case "${TERM_PROGRAM:-}" in Apple_Terminal|iTerm.app|WezTerm|ghostty|vscode|Hyper) CT=256 ;; esac
case "${COLORTERM:-}" in truecolor|24bit) CT=true ;; esac
case "${TERM_PROGRAM:-}" in iTerm.app|WezTerm|ghostty|vscode|Hyper) CT=true ;; esac
case "${TERM:-}" in *kitty*|*ghostty*|*alacritty*|*wezterm*|*direct*) CT=true ;; esac

LINKS=0
case "${TERM_PROGRAM:-}" in iTerm.app|WezTerm|ghostty|vscode|Hyper) LINKS=1 ;; esac
case "${TERM:-}" in *kitty*|*ghostty*|*wezterm*) LINKS=1 ;; esac

HAVE_TTY=0
if [ -t 0 ] || { [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; }; then HAVE_TTY=1; fi

# ── cleanup ───────────────────────────────────────────────────────────────────
TMP=""
JOB_PID=""
STTY_SAVE=""
CURSOR_HIDDEN=0
CLEANED=0

cleanup() {
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  if [ -n "$JOB_PID" ]; then kill "$JOB_PID" 2>/dev/null || true; fi
  if [ -n "$STTY_SAVE" ]; then stty "$STTY_SAVE" 2>/dev/null </dev/tty || true; fi
  if [ "$CURSOR_HIDDEN" = 1 ]; then printf '%s[?25h' "$ESC"; fi
  if [ "$MODE" != plain ]; then printf '%s' "$R"; fi
  if [ -n "$TMP" ]; then
    if [ -d "$TMP/dmg/Boundless.app" ]; then hdiutil detach "$TMP/dmg" -quiet 2>/dev/null || hdiutil detach "$TMP/dmg" -force -quiet 2>/dev/null || true; fi
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT
trap 'cleanup; printf "\n"; echo "Cancelled."; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# ── colors ────────────────────────────────────────────────────────────────────
Q=0; CS=""
q256() {
  local r=$1 g=$2 b=$3 ri gi bi cr cg cb av gv gl dc dg
  ri=$(( r < 48 ? 0 : r < 115 ? 1 : (r - 35) / 40 ))
  gi=$(( g < 48 ? 0 : g < 115 ? 1 : (g - 35) / 40 ))
  bi=$(( b < 48 ? 0 : b < 115 ? 1 : (b - 35) / 40 ))
  cr=$(( ri > 0 ? 55 + 40 * ri : 0 )); cg=$(( gi > 0 ? 55 + 40 * gi : 0 )); cb=$(( bi > 0 ? 55 + 40 * bi : 0 ))
  av=$(( (r + g + b) / 3 ))
  gv=$(( av < 8 ? 0 : av > 238 ? 23 : (av - 3) / 10 )); gl=$(( 8 + 10 * gv ))
  dc=$(( (r-cr)*(r-cr) + (g-cg)*(g-cg) + (b-cb)*(b-cb) ))
  dg=$(( (r-gl)*(r-gl) + (g-gl)*(g-gl) + (b-gl)*(b-gl) ))
  if [ "$dg" -lt "$dc" ]; then Q=$(( 232 + gv )); else Q=$(( 16 + 36 * ri + 6 * gi + bi )); fi
}

q16() { # plain 16-color: blue, magenta, cyan, default text
  local r=$1 g=$2 b=$3
  if [ $(( r + g + b )) -gt 560 ]; then Q=39
  elif [ "$g" -gt $(( r + 40 )) ] && [ "$b" -gt 160 ]; then Q=36
  elif [ "$r" -gt 90 ] && [ "$b" -gt 150 ]; then Q=35
  elif [ "$b" -gt "$r" ]; then Q=34
  else Q=90
  fi
}

rgb_seq() { # kind(38|48) r g b -> CS
  case "$CT" in
    true) CS="${ESC}[$1;2;$2;$3;$4m" ;;
    256) q256 "$2" "$3" "$4"; CS="${ESC}[$1;5;${Q}m" ;;
    *) if [ "$1" = 38 ]; then q16 "$2" "$3" "$4"; CS="${ESC}[${Q}m"; else CS=""; fi ;;
  esac
}

GF=()
AUR=0;  AURN=72
WM=72;  WMN=48
WMH=120
TAG=168; TAGN=24
BRD=192; BRDN=48
BRDD=240

grad_make() { # base count r g b r g b ...
  local base=$1 n=$2 i t seg f ns r g b
  shift 2
  local -a st
  st=("$@")
  ns=$(( ${#st[@]} / 3 ))
  for (( i = 0; i < n; i++ )); do
    t=$(( i * (ns - 1) * 256 / (n - 1) ))
    seg=$(( t / 256 )); [ "$seg" -lt $(( ns - 1 )) ] || seg=$(( ns - 2 ))
    f=$(( t - seg * 256 ))
    r=$(( (st[seg*3] * (256 - f) + st[(seg+1)*3] * f) / 256 ))
    g=$(( (st[seg*3+1] * (256 - f) + st[(seg+1)*3+1] * f) / 256 ))
    b=$(( (st[seg*3+2] * (256 - f) + st[(seg+1)*3+2] * f) / 256 ))
    rgb_seq 38 "$r" "$g" "$b"; GF[base+i]=$CS
  done
}

# ── plain output helpers ──────────────────────────────────────────────────────
STEP_N=0
STEP_TOTAL=5
say() { printf '%s\n' "$1"; }
plain_step() { STEP_N=$(( STEP_N + 1 )); printf '[%d/%d] %s\n' "$STEP_N" "$STEP_TOTAL" "$1"; }

# ── unsupported platforms ─────────────────────────────────────────────────────
# Rendered by the panel code further down; the plain text version is here.
plain_unsupported() {
  if [ "$OS_KIND" = windows ]; then
    say "Sorry, Windows is not compatible yet."
    say "It has been delayed, please wait slightly longer."
    say "Thanks."
    say ""
    say "Updates and news: $DISCORD_URL"
  else
    say "This installer is for macOS."
    say "Downloads for other platforms: https://github.com/$REPO/releases/latest"
    say ""
    say "Need a hand? $DISCORD_URL"
  fi
}

# ── JSON helpers (osascript is always there on a Mac) ─────────────────────────
asset_field() { # json suffix url|digest|size
  osascript -l JavaScript - "$1" "$2" "$3" <<'JS' 2>/dev/null || true
function run(argv) {
  var release = JSON.parse(argv[0]);
  var assets = release.assets || [];
  for (var i = 0; i < assets.length; i++) {
    var name = assets[i].name || "";
    if (name.slice(-argv[1].length) === argv[1]) {
      if (argv[2] === "digest") return assets[i].digest || "";
      if (argv[2] === "size") return String(assets[i].size || "");
      return assets[i].browser_download_url || "";
    }
  }
  return "";
}
JS
}

json_field() { # json key
  osascript -l JavaScript - "$1" "$2" <<'JS' 2>/dev/null || true
function run(argv) {
  var o = JSON.parse(argv[0]);
  var parts = argv[1].split(".");
  for (var i = 0; i < parts.length && o != null; i++) o = o[parts[i]];
  return o == null ? "" : String(o);
}
JS
}

# ── art ───────────────────────────────────────────────────────────────────────
# One awk run draws the infinity mark and the wordmark as rows of half-block codes
# (0 empty, 1 upper half, 2 lower half, 3 full).
INFB=(); INFW=18; WMK=()
art_init() {
  local out kind row
  out=$(awk -v CW=18 '
  BEGIN {
    DW = CW * 2; DH = 16; r = 1.45; a = DW / 2 - r - 0.6; n = 420
    for (i = 0; i < n; i++) {
      t = 6.283185307 * i / n; d = 1 + sin(t) * sin(t)
      px[i] = DW / 2 + a * cos(t) / d
      py[i] = DH / 2 + a * sin(t) * cos(t) / d * 0.92
    }
    for (y = 0; y < DH; y++) for (x = 0; x < DW; x++) {
      cx = x + 0.5; cy = y + 0.5; best = 1e9
      for (i = 0; i < n; i++) { dx = cx - px[i]; dy = cy - py[i]; q = dx * dx + dy * dy; if (q < best) best = q }
      g[x, y] = (best <= r * r) ? 1 : 0
    }
    split("1 2 4 64", b0, " "); split("8 16 32 128", b1, " ")
    line = "I"
    for (k = 0; k < 4; k++) for (cx = 0; cx < CW; cx++) {
      v = 0
      for (dy = 0; dy < 4; dy++) {
        if (g[2 * cx, 4 * k + dy]) v += b0[dy + 1]
        if (g[2 * cx + 1, 4 * k + dy]) v += b1[dy + 1]
      }
      line = line " " v
    }
    print line
    L["B"] = "####.|#...#|#...#|####.|#...#|#...#|####."
    L["o"] = ".....|.....|.###.|#...#|#...#|#...#|.###."
    L["u"] = ".....|.....|#...#|#...#|#...#|#..##|.##.#"
    L["n"] = ".....|.....|#.##.|##..#|#...#|#...#|#...#"
    L["d"] = "....#|....#|.####|#...#|#...#|#...#|.####"
    L["l"] = "##.|.#.|.#.|.#.|.#.|.#.|.##"
    L["e"] = ".....|.....|.###.|#...#|#####|#....|.####"
    L["s"] = ".....|.....|.####|#....|.###.|....#|####."
    word = "Boundless"
    for (row = 0; row < 8; row++) ln[row] = ""
    for (i = 1; i <= length(word); i++) {
      ch = substr(word, i, 1); split(L[ch], rr, "|"); w = length(rr[1])
      for (row = 0; row < 8; row++) {
        seg = ""
        if (row < 7) seg = rr[row + 1]; else for (j = 0; j < w; j++) seg = seg "."
        ln[row] = ln[row] seg (i < length(word) ? "." : "")
      }
    }
    for (k = 0; k < 4; k++) {
      s = ""
      for (x = 1; x <= length(ln[0]); x++) {
        top = (substr(ln[2 * k], x, 1) == "#") ? 1 : 0
        bot = (substr(ln[2 * k + 1], x, 1) == "#") ? 1 : 0
        s = s (top + 2 * bot)
      }
      print "W " s
    }
  }')
  while IFS=' ' read -r kind row; do
    case "$kind" in
      I) read -r -a INFB <<<"$row" ;;
      W) WMK[${#WMK[@]}]=$row ;;
    esac
  done <<EOF2
$out
EOF2
}

HB=(" " "▀" "▄" "█")
SINT=(); BRL=()
tables_init() {
  local i fmt ch
  SINT=($(awk 'BEGIN{for(i=0;i<256;i++) printf "%d ", 127*sin(i*6.283185307/256)}'))
  for (( i = 0; i < 256; i++ )); do
    printf -v fmt '\\342\\%03o\\%03o' $(( 160 + (i >> 6) )) $(( 128 + (i & 63) ))
    printf -v ch "$fmt"
    BRL[i]=$ch
  done
}

# braille bits for a column's 4 dot rows: col0 uses 1,2,4,64 and col1 uses 8,16,32,128
BT0=(); BT1=()
bits_init() {
  local n
  for (( n = 0; n < 16; n++ )); do
    BT0[n]=$(( (n & 1 ? 1 : 0) | (n & 2 ? 2 : 0) | (n & 4 ? 4 : 0) | (n & 8 ? 64 : 0) ))
    BT1[n]=$(( (n & 1 ? 8 : 0) | (n & 2 ? 16 : 0) | (n & 4 ? 32 : 0) | (n & 8 ? 128 : 0) ))
  done
}

# ── layout and palette ────────────────────────────────────────────────────────
INNER=76; MARG=""; WV=70; WB=2; NPANEL=20; NL=23; DW=40
STAGE_NAME=("Check for updates" "Download" "Verify checksum" "Install" "All set")
ST=(pending pending pending pending pending)
STD=("" "" "" "" "")
C_DIM=""; C_TXT=""; C_LAV=""; C_CY=""; C_ERR=""; C_PILLBG=""; C_PILLFG=""; C_HI=""
PB=()

layout_init() {
  local m
  case "$TIER" in
    full) INNER=76; WB=2; NPANEL=20 ;;
    mid) INNER=$(( COLS - 4 )); [ "$INNER" -le 76 ] || INNER=76; WB=2; NPANEL=19 ;;
    *) INNER=$(( COLS - 4 )); [ "$INNER" -le 60 ] || INNER=60; WB=1; NPANEL=12 ;;
  esac
  WV=$(( INNER - 6 ))
  DW=$(( INNER - 18 - 11 ))
  m=$(( (COLS - INNER - 2) / 2 )); [ "$m" -ge 0 ] || m=0
  printf -v MARG '%*s' "$m" ''
  NL=$(( 1 + NPANEL + 2 ))
}

palette_init() {
  rgb_seq 38 110 116 160; C_DIM=$CS
  rgb_seq 38 223 227 255; C_TXT=$CS
  rgb_seq 38 167 159 255; C_LAV=$CS
  rgb_seq 38 95 210 240;  C_CY=$CS
  rgb_seq 38 255 120 130; C_ERR=$CS
  rgb_seq 48 36 38 78;    C_PILLBG=$CS
  rgb_seq 38 212 217 255; C_PILLFG=$CS
  rgb_seq 38 255 255 255; C_HI=$CS
  grad_make $AUR $AURN 59 43 214  106 47 217  124 92 255  95 210 240  28 95 214  59 43 214
  grad_make $WM $WMN 255 255 255  217 220 255  143 134 255  79 199 234
  grad_make $WMH $WMN 255 255 255  255 255 255  217 220 255  160 230 250
  grad_make $TAG $TAGN 167 159 255  95 210 240
  grad_make $BRD $BRDN 59 43 214  124 92 255  95 210 240
  grad_make $BRDD $BRDN 28 24 80  50 40 110  30 80 110
}

# panel glass: slightly lighter at the top, deeper at the bottom
panel_bg_init() {
  local i r g b
  for (( i = 0; i < 24; i++ )); do
    r=$(( 17 - i / 3 )); g=$(( 19 - i / 3 )); b=$(( 40 - i ))
    if [ "$CT" != true ]; then r=13; g=15; b=30; fi
    rgb_seq 48 "$r" "$g" "$b"; PB[i]=$CS
  done
}

# ── frame state ───────────────────────────────────────────────────────────────
T=0            # frame counter
TV=0           # visual time (0 when animations are off)
SCREEN=progress
PCT=0          # wave fill, 0-100
AMPD=40        # wave amplitude in 1/16 dots
WSPD=9         # wave phase speed
AMP_AUTO=1
STATUS=""
STATUS_R=""
FOOT1=""
FOOT2=""
MSG=()         # message screen body: "kind|text"
SEL=-1
MENU=()
PULSE=0
INTRO_END=0
LINES_OUT=()
FIRST_DRAW=1

clamp() { # value lo hi -> echoes via CL
  CL=$1
  [ "$CL" -ge "$2" ] || CL=$2
  [ "$CL" -le "$3" ] || CL=$3
}

LB=""; LWID=0; SPC=""
lp() { LB+="$1"; LWID=$(( LWID + $2 )); }
lsp() { if [ "$1" -gt 0 ]; then printf -v SPC '%*s' "$1" ''; LB+="$SPC"; LWID=$(( LWID + $1 )); fi; }

CURBG=""
start_row() { # row
  local row=$1 il ir
  CURBG=${PB[row]}
  il=$(( (row * 3 + TV / 2) % BRDN )); ir=$(( (BRDN - 1) - (row * 2 + TV / 3) % BRDN ))
  if [ "$TV" -lt 10 ] && [ "$MODE" = anim ]; then
    LB="${MARG}${GF[BRDD+il]}│${PB[row]}"
  else
    LB="${MARG}${GF[BRD+il]}│${PB[row]}"
  fi
  LWID=0
  ROWIR=$ir
}
ROWIR=0
end_row() { # row
  local row=$1
  lsp $(( INNER - LWID ))
  if [ "$TV" -lt 10 ] && [ "$MODE" = anim ]; then
    LB+="${R}${GF[BRDD+ROWIR]}│${R}${ESC}[K"
  else
    LB+="${R}${GF[BRD+ROWIR]}│${R}${ESC}[K"
  fi
  LINES_OUT[row+1]=$LB
}

border_row() { # row top|bottom
  local row=$1 kind=$2 i idx lim l r
  if [ "$kind" = top ]; then l="╭"; r="╮"; else l="╰"; r="╯"; fi
  lim=$(( TV * 7 ))
  LB="${MARG}"
  for (( i = 0; i < INNER + 2; i++ )); do
    idx=$(( (i * BRDN / (INNER + 2) + TV / 2 + PULSE * 6) % BRDN ))
    if [ "$i" -gt "$lim" ] && [ "$MODE" = anim ]; then LB+="${GF[BRDD+idx]}"; else LB+="${GF[BRD+idx]}"; fi
    if [ "$i" -eq 0 ]; then LB+="$l"; elif [ "$i" -eq $(( INNER + 1 )) ]; then LB+="$r"; else LB+="─"; fi
  done
  LB+="${R}${ESC}[K"
  LINES_OUT[row+1]=$LB
}

# ── header art ────────────────────────────────────────────────────────────────
render_inf() { # row
  local row=$1 i b idx rev
  rev=$(( (TV - 3) * 2 )); [ "$MODE" = anim ] || rev=99
  for (( i = 0; i < INFW; i++ )); do
    b=${INFB[row * INFW + i]}
    if [ "$b" = 0 ] || [ "$i" -ge "$rev" ]; then LB+=" "; continue; fi
    if [ $(( rev - i )) -le 2 ]; then LB+="${C_HI}${BRL[b]}"; continue; fi
    idx=$(( (i * 3 + row * 4 + TV * 2) % AURN ))
    LB+="${GF[AUR+idx]}${BRL[b]}"
  done
}

render_wm() { # row
  local s=${WMK[$1]} i c idx n=${#WMK[0]} rev sweep
  rev=$(( (TV - 10) * 3 )); [ "$MODE" = anim ] || rev=99
  sweep=$(( (TV * 2 - 60) % 140 - 20 ))
  [ "$MODE" = anim ] || sweep=-99
  for (( i = 0; i < n; i++ )); do
    c=${s:i:1}
    if [ "$c" = 0 ] || [ "$i" -ge "$rev" ]; then LB+=" "; continue; fi
    idx=$(( i * WMN / n ))
    if [ $(( i - sweep )) -lt 5 ] && [ $(( sweep - i )) -lt 5 ]; then LB+="${GF[WMH+idx]}${HB[c]}"; else LB+="${GF[WM+idx]}${HB[c]}"; fi
  done
}

# ── rows ──────────────────────────────────────────────────────────────────────
TAG1="Comics, manga and novels, "
TAG2="one liquid glass library."

row_header() { # row index within header 0-3
  local k=$1 w
  if [ "$TIER" = full ]; then
    lsp 2; render_inf "$k"; LWID=$(( LWID + INFW )); lsp 2; render_wm "$k"; LWID=$(( LWID + ${#WMK[0]} ))
  else
    w=${#WMK[0]}; lsp $(( (INNER - w) / 2 )); render_wm "$k"; LWID=$(( LWID + w ))
  fi
}

row_title_compact() {
  local i word="Boundless" idx
  lsp 2; lp "${GF[AUR+10]}∞ " 2
  for (( i = 0; i < ${#word}; i++ )); do
    idx=$(( i * WMN / ${#word} )); lp "${GF[WM+idx]}${ESC}[1m${word:i:1}${R}${CURBG}" 1
  done
}

row_tagline() {
  local total=51 n shown i idx pad
  n=$(( (TV - 38) * 2 )); [ "$MODE" = anim ] || n=99
  clamp "$n" 0 "$total"; shown=$CL
  pad=$(( (INNER - total) / 2 )); lsp "$pad"
  for (( i = 0; i < shown; i++ )); do
    if [ "$i" -lt 26 ]; then
      lp "${C_TXT}${TAG1:i:1}" 1
    else
      idx=$(( (i - 26) * TAGN / 25 )); lp "${GF[TAG+idx]}${TAG2:i-26:1}" 1
    fi
  done
}

row_pills() {
  local n pad
  n=$(( (TV - 50) / 3 )); [ "$MODE" = anim ] || n=3
  clamp "$n" 0 3; n=$CL
  pad=$(( (INNER - 28) / 2 )); lsp "$pad"
  [ "$n" -ge 1 ] && lp "${C_PILLBG}${C_PILLFG}${ESC}[1m SYNC ${R}${CURBG}" 6 || lsp 6
  lsp 2
  [ "$n" -ge 2 ] && lp "${C_PILLBG}${C_PILLFG}${ESC}[1m OFFLINE ${R}${CURBG}" 9 || lsp 9
  lsp 2
  [ "$n" -ge 3 ] && lp "${C_PILLBG}${C_PILLFG}${ESC}[1m STREAKS ${R}${CURBG}" 9 || lsp 9
}

SPIN=("◐" "◓" "◑" "◒")
row_stage() { # idx
  local i=$1 nw dw name detail icon col namec idx
  nw=18
  dw=$DW
  name=${STAGE_NAME[i]}; detail=${STD[i]}
  [ "${#name}" -le "$nw" ] || name=${name:0:nw}
  [ "${#detail}" -le "$dw" ] || detail=${detail:0:dw}
  case "${ST[i]}" in
    done) icon="${C_CY}✓"; namec="${C_LAV}" ;;
    active)
      idx=$(( (TV * 3 + i * 5) % AURN ))
      if [ "$MODE" = anim ]; then icon="${GF[AUR+idx]}${SPIN[(TV / 2) % 4]}"; else icon="${GF[AUR+idx]}●"; fi
      namec="${C_TXT}${ESC}[1m" ;;
    error) icon="${C_ERR}✗"; namec="${C_ERR}" ;;
    *) icon="${C_DIM}○"; namec="${C_DIM}" ;;
  esac
  lsp 3; lp "${icon}${R}${CURBG}  " 3
  lp "${namec}${name}${R}${CURBG}" "${#name}"
  lsp $(( nw - ${#name} ))
  lsp 2
  lsp $(( dw - ${#detail} ))
  lp "${C_DIM}${detail}${R}${CURBG}" "${#detail}"
}

# the wave: filled part is a flowing sine in the brand gradient, the rest a calm track
declare -a WM_M
row_wave() { # band row (0 or 1); computes the columns on band row 0
  local br=$1 nd=$(( WV * 2 )) c edge s tap rr thk y16 mid16 cx m0 m1 n0 n1 bits idx amp wt
  if [ "$br" -eq 0 ]; then
    wt=2; [ "$WB" -lt 2 ] || wt=3
    mid16=$(( ((WB * 4 - wt) / 2) * 16 + 8 ))
    edge=$(( PCT * nd / 100 )); amp=$(( AMPD * WB / 2 ))
    for (( c = 0; c < nd; c++ )); do
      if [ "$c" -lt "$edge" ]; then
        s=${SINT[(c * 7 + TV * WSPD) & 255]}
        tap=10; [ $(( edge - c )) -ge 10 ] || tap=$(( edge - c ))
        y16=$(( mid16 + (amp * s * tap) / 1270 ))
        rr=$(( y16 / 16 )); thk=$wt
      else
        rr=$(( WB * 4 / 2 - 1 )); thk=1
      fi
      clamp "$rr" 0 $(( WB * 4 - thk )); rr=$CL
      WM_M[c]=$(( ((1 << thk) - 1) << rr ))
    done
    WEDGE=$edge
  fi
  lsp 3
  for (( cx = 0; cx < WV; cx++ )); do
    m0=${WM_M[cx*2]}; m1=${WM_M[cx*2+1]}
    n0=$(( (m0 >> (4 * br)) & 15 )); n1=$(( (m1 >> (4 * br)) & 15 ))
    bits=$(( BT0[n0] | BT1[n1] ))
    if [ $(( cx * 2 )) -lt "$WEDGE" ]; then
      idx=$(( (cx * 2 + TV * 2) % AURN ))
      LB+="${GF[AUR+idx]}${BRL[bits]}"
    else
      LB+="${C_DIM}${BRL[bits]}"
    fi
  done
  LWID=$(( LWID + WV ))
}
WEDGE=0

row_status() {
  local left=$STATUS right=$STATUS_R
  lsp 3
  lp "${C_TXT}${left}${R}${CURBG}" "${#left}"
  lsp $(( INNER - LWID - ${#right} - 3 ))
  lp "${C_LAV}${ESC}[1m${right}${R}${CURBG}" "${#right}"
}

row_msg() { # index of message line
  local line=${MSG[$1]:-|} kind text w pad col
  kind=${line%%|*}; text=${line#*|}
  w=${#text}
  case "$kind" in
    title) col="${C_TXT}${ESC}[1m" ;;
    big)  col="${C_TXT}${ESC}[1m" ;;
    dim)  col="${C_DIM}" ;;
    link) col="${C_CY}${ESC}[4m" ;;
    err)  col="${C_ERR}${ESC}[1m" ;;
    grad) col="${C_LAV}" ;;
    *)    col="${C_TXT}" ;;
  esac
  [ "$kind" != live ] || w=$(( w + 2 ))
  [ "$w" -le $(( INNER - 4 )) ] || { text=${text:0:INNER-4}; w=${#text}; }
  pad=$(( (INNER - w) / 2 )); lsp "$pad"
  if [ "$kind" = live ]; then
    lp "${C_CY}●${R}${CURBG} ${C_TXT}${text}${R}${CURBG}" "$w"
  elif [ "$kind" = link ] && [ "$LINKS" = 1 ]; then
    lp "${ESC}]8;;${text}${ESC}\\${col}${text}${R}${CURBG}${ESC}]8;;${ESC}\\" "$w"
  else
    lp "${col}${text}${R}${CURBG}" "$w"
  fi
}

# ── compose a frame ───────────────────────────────────────────────────────────
KIND=(); BODY_START=0; BODY_END=0
kinds_init() {
  case "$TIER" in
    full) KIND=(top blank h0 h1 h2 h3 blank tag pills blank s0 s1 s2 s3 s4 blank w0 w1 status bottom); BODY_START=10; BODY_END=18 ;;
    mid) KIND=(top blank h0 h1 h2 h3 blank tag blank s0 s1 s2 s3 s4 blank w0 w1 status bottom); BODY_START=9; BODY_END=17 ;;
    *) KIND=(top title blank s0 s1 s2 s3 s4 blank w0 status bottom); BODY_START=3; BODY_END=10 ;;
  esac
}

compose() {
  local r kind mi nmsg off
  LINES_OUT[0]="${ESC}[K"
  nmsg=${#MSG[@]}
  off=0
  if [ "$SCREEN" = message ]; then
    off=$(( (BODY_END - BODY_START + 1 - nmsg) / 2 )); [ "$off" -ge 0 ] || off=0
  fi
  for (( r = 0; r < NPANEL; r++ )); do
    kind=${KIND[r]}
    if [ "$kind" = top ] || [ "$kind" = bottom ]; then border_row "$r" "$kind"; continue; fi
    start_row "$r"
    if [ "$SCREEN" = message ] && [ "$r" -ge "$BODY_START" ] && [ "$r" -le "$BODY_END" ]; then
      mi=$(( r - BODY_START - off ))
      if [ "$mi" -ge 0 ] && [ "$mi" -lt "$nmsg" ]; then row_msg "$mi"; fi
    else
      case "$kind" in
        h0|h1|h2|h3) row_header "${kind#h}" ;;
        title) row_title_compact ;;
        tag) row_tagline ;;
        pills) row_pills ;;
        s0|s1|s2|s3|s4) row_stage "${kind#s}" ;;
        w0) row_wave 0 ;;
        w1) row_wave 1 ;;
        status) row_status ;;
      esac
    fi
    end_row "$r"
  done
  LINES_OUT[NPANEL+1]="${MARG}${FOOT1}${R}${ESC}[K"
  LINES_OUT[NPANEL+2]="${MARG}${FOOT2}${R}${ESC}[K"
}

draw() {
  local i buf
  compose
  buf="${ESC}[?2026h"$'\r'"${ESC}[$(( NL - 1 ))A"
  for (( i = 0; i < NL; i++ )); do
    buf+="${LINES_OUT[i]}"
    if [ "$i" -lt $(( NL - 1 )) ]; then buf+=$'\n'; fi
  done
  buf+="${ESC}[?2026l"
  printf '%s' "$buf"
}

ui_begin() {
  local i
  printf '%s[?25l' "$ESC"; CURSOR_HIDDEN=1
  for (( i = 1; i < NL; i++ )); do printf '\n'; done
}

ui_end() {
  printf '\n'
  printf '%s[?25h' "$ESC"; CURSOR_HIDDEN=0
}

ui_init() {
  layout_init
  kinds_init
  palette_init
  panel_bg_init
  art_init
  tables_init
  bits_init
  FOOT1=""; FOOT2=""
}

foot() { # line text color
  local pad
  pad=$(( (INNER + 2 - ${#2}) / 2 )); [ "$pad" -ge 0 ] || pad=0
  printf -v SPC '%*s' "$pad" ''
  if [ "$1" = 1 ]; then FOOT1="${SPC}${3}${2}"; else FOOT2="${SPC}${3}${2}"; fi
}

# ── engine ────────────────────────────────────────────────────────────────────
JOB_RC=0; MIN_T=0; SIM_DONE=1; SIM_END=0; INTRO_FRAMES=66

tick() {
  T=$(( T + 1 ))
  if [ "$MODE" = anim ]; then
    TV=$T
    if [ "$AMP_AUTO" = 1 ]; then AMPD=$(( 38 + SINT[(TV * 3) & 255] / 16 )); fi
  fi
}

nap() { if [ "$MODE" = anim ]; then sleep 0.04; else sleep 0.3; fi; }

job_alive() {
  if [ -n "$JOB_PID" ]; then kill -0 "$JOB_PID" 2>/dev/null; else [ "$SIM_DONE" = 0 ]; fi
}

sim_start() { SIM_DONE=0; SIM_END=$(( T + $1 )); }
sim_hook() { if [ "$T" -ge "$SIM_END" ]; then SIM_DONE=1; fi; }
noop_hook() { :; }

await() { # [hook]
  local hook=${1:-noop_hook}
  JOB_RC=0
  if [ "$MODE" = plain ]; then
    if [ -n "$JOB_PID" ]; then wait "$JOB_PID" 2>/dev/null || JOB_RC=$?; JOB_PID=""; else sleep 0.2; fi
    return 0
  fi
  while job_alive || [ "$T" -lt "$MIN_T" ]; do
    "$hook"
    tick; draw; nap
  done
  if [ -n "$JOB_PID" ]; then wait "$JOB_PID" 2>/dev/null || JOB_RC=$?; JOB_PID=""; fi
  "$hook"
  tick; draw
}

st_set() { # idx state detail
  ST[$1]=$2; STD[$1]=${3:-}
  if [ "$MODE" = plain ] && [ "$2" = active ]; then plain_step "${STAGE_NAME[$1]}"; fi
}

mb() { # bytes -> MBS like 18.4
  local t=$(( $1 * 10 / 1048576 ))
  MBS="$(( t / 10 )).$(( t % 10 ))"
}

# ── Discord ───────────────────────────────────────────────────────────────────
D_MEM=""; D_ON=""; D_NAME="Boundless Reader"

discord_fetch_job() {
  trap - EXIT INT TERM HUP
  curl -fsS -m 4 "$DISCORD_API" -o "$TMP/discord.json" 2>/dev/null
}

open_url() { # url
  [ "$DEMO" = 1 ] && return 0
  open "$1" >/dev/null 2>&1 || true
}

discord_screen() {
  local json n i shown_m shown_o steps
  [ -n "$TMP" ] || TMP=$(mktemp -d)
  if [ "$MODE" = plain ]; then
    say "Join the Boundless Discord: $DISCORD_URL"
    open_url "$DISCORD_URL"
    return 0
  fi
  local keep_screen=$SCREEN keep_foot1=$FOOT1 keep_foot2=$FOOT2
  SCREEN=message
  MSG=("title|Join the Boundless Discord" "dim|Questions, bug reports, early builds and good company." "|" "grad|Checking who is around..." "|" "link|$DISCORD_URL" "|" "dim| ")
  foot 1 "" "$C_DIM"; foot 2 "" "$C_DIM"
  D_MEM=""; D_ON=""
  if [ "$DEMO" = 1 ]; then
    sim_start 30; D_MEM=33; D_ON=8
  else
    discord_fetch_job & JOB_PID=$!
  fi
  MIN_T=$(( T + 24 ))
  await sim_hook
  if [ "$DEMO" != 1 ] && [ "$JOB_RC" -eq 0 ] && [ -s "$TMP/discord.json" ]; then
    json=$(cat "$TMP/discord.json")
    D_MEM=$(json_field "$json" approximate_member_count)
    D_ON=$(json_field "$json" approximate_presence_count)
    n=$(json_field "$json" guild.name); [ -z "$n" ] || D_NAME=$n
  fi
  case "$D_MEM$D_ON" in ''|*[!0-9]*) D_MEM=""; D_ON="" ;; esac
  if [ -n "$D_MEM" ]; then
    steps=20
    for (( i = 1; i <= steps; i++ )); do
      shown_m=$(( D_MEM * i / steps )); shown_o=$(( D_ON * i / steps ))
      MSG[3]="live|${shown_m} members     ${shown_o} online now"
      tick; draw; nap
    done
    MSG[3]="live|${D_MEM} members     ${D_ON} online now"
  else
    MSG[3]="grad|Come say hi."
  fi
  if [ "$DEMO" = 1 ]; then MSG[7]="dim|Demo mode: not opening your browser."; else MSG[7]="dim|Opening the invite in your browser..."; fi
  tick; draw
  open_url "$DISCORD_URL"
  MIN_T=$(( T + 30 )); SIM_DONE=1
  await
  if [ "${DISCORD_STANDALONE:-0}" = 1 ]; then
    foot 1 "See you there" "$C_LAV"; foot 2 "" "$C_DIM"; tick; draw
    return 0
  fi
  SCREEN=$keep_screen; FOOT1=$keep_foot1; FOOT2=$keep_foot2; MSG=()
}

# ── keyboard ──────────────────────────────────────────────────────────────────
KEY=""
getkey() { # 0.1 s poll; sets KEY to a letter, ENTER, UP, DOWN, LEFT, RIGHT, ESC or ""
  local c r1 r2
  KEY=""
  c=$(dd bs=1 count=1 2>/dev/null </dev/tty || true)
  [ -n "$c" ] || return 0
  case "$c" in
    $'\r') KEY=ENTER ;;
    $'\t') KEY=RIGHT ;;
    $'\033')
      r1=$(dd bs=1 count=1 2>/dev/null </dev/tty || true)
      if [ "$r1" = "[" ]; then
        r2=$(dd bs=1 count=1 2>/dev/null </dev/tty || true)
        case "$r2" in A) KEY=UP ;; B) KEY=DOWN ;; C) KEY=RIGHT ;; D) KEY=LEFT ;; *) KEY=ESC ;; esac
      else
        KEY=ESC
      fi ;;
    *) KEY=$c ;;
  esac
}

keys_on() {
  [ "$HAVE_TTY" = 1 ] || return 1
  STTY_SAVE=$(stty -g 2>/dev/null </dev/tty || true)
  [ -n "$STTY_SAVE" ] || return 1
  stty -icanon -echo -icrnl min 0 time 1 2>/dev/null </dev/tty || { STTY_SAVE=""; return 1; }
}
keys_off() {
  if [ -n "$STTY_SAVE" ]; then stty "$STTY_SAVE" 2>/dev/null </dev/tty || true; STTY_SAVE=""; fi
}

lower_of() { case "$1" in L) LK=l ;; D) LK=d ;; N) LK=n ;; Q) LK=q ;; R) LK=r ;; *) LK=$1 ;; esac; }

menu_footer() { # sel
  local i item sel=$1 line="" w=0 pad key label pre post
  for (( i = 0; i < ${#MENU[@]}; i++ )); do
    item=${MENU[i]}; key=${item%%|*}; label=${item#*|}
    lower_of "$key"
    pre=${label%%[$key$LK]*}; post=${label#"$pre"?}
    if [ "$i" -eq "$sel" ]; then
      line+="${C_PILLBG}${C_HI}${ESC}[1m  ${pre}${ESC}[4m${label:${#pre}:1}${ESC}[24m${post}  ${R}"
    else
      line+="${C_DIM}  ${pre}${C_LAV}${ESC}[4m${label:${#pre}:1}${R}${C_DIM}${post}  ${R}"
    fi
    line+=" "
    w=$(( w + ${#label} + 5 ))
  done
  pad=$(( (INNER + 2 - w) / 2 )); [ "$pad" -ge 0 ] || pad=0
  printf -v SPC '%*s' "$pad" ''
  FOOT1="${SPC}${line}"
}

# the chosen item's key ends up in CHOICE
menu_loop() {
  local sel=0 n=${#MENU[@]} i k
  CHOICE=""
  foot 2 "Arrow keys and Enter, or press a letter" "$C_DIM"
  if ! keys_on; then CHOICE=Q; return 0; fi
  while :; do
    menu_footer "$sel"
    tick; draw
    getkey
    case "$KEY" in
      ENTER) CHOICE=${MENU[sel]%%|*}; break ;;
      LEFT|UP) sel=$(( (sel + n - 1) % n )) ;;
      RIGHT|DOWN) sel=$(( (sel + 1) % n )) ;;
      ESC) CHOICE=Q; break ;;
      "") ;;
      *)
        k=$(printf '%s' "$KEY" | tr '[:lower:]' '[:upper:]')
        for (( i = 0; i < n; i++ )); do
          if [ "${MENU[i]%%|*}" = "$k" ]; then CHOICE=$k; break 2; fi
        done ;;
    esac
  done
  keys_off
}

any_key() { # waits for a key; returns it in KEY (empty on timeout of ~30 s)
  local i
  KEY=""
  if ! keys_on; then return 0; fi
  for (( i = 0; i < 300; i++ )); do
    tick; draw
    getkey
    [ -z "$KEY" ] || break
  done
  keys_off
}

# ── message screens ───────────────────────────────────────────────────────────
screen_in() { # run the short intro for message screens
  ui_init
  ui_begin
  SCREEN=message
  PCT=100
  MIN_T=$(( T + INTRO_FRAMES ))
  [ "$MODE" = anim ] || MIN_T=$T
  SIM_DONE=1
  await
}

show_unsupported() {
  if [ "$MODE" = plain ]; then plain_unsupported; return 0; fi
  if [ "$OS_KIND" = windows ]; then
    MSG=("big|Sorry, Windows is not compatible yet." "|" "text|It has been delayed, please wait slightly longer." "text|Thanks." "|" "dim|Updates and news land on the Discord:" "link|$DISCORD_URL")
  else
    MSG=("big|This installer is for macOS." "|" "text|Downloads for other platforms are on GitHub:" "link|https://github.com/$REPO/releases/latest" "|" "dim|Need a hand? Join the Discord:" "link|$DISCORD_URL")
  fi
  screen_in
  if [ "$HAVE_TTY" = 1 ]; then
    foot 1 "Press D to join the Discord, or any other key to close" "$C_LAV"
    foot 2 "" "$C_DIM"
    any_key
    case "$KEY" in d|D) discord_screen ;; esac
  else
    foot 1 "" "$C_DIM"
  fi
  ui_end
}

fatal() { # message
  local msg=$1 i
  if [ "$MODE" = plain ]; then
    printf 'Error: %s\n' "$msg" >&2
    printf 'Need a hand? Join the Discord: %s\n' "$DISCORD_URL" >&2
    exit 1
  fi
  for (( i = 0; i < 5; i++ )); do
    if [ "${ST[i]}" = active ]; then ST[i]=error; fi
  done
  STATUS=$msg; STATUS_R=""
  SCREEN=message
  MSG=("err|Installation stopped" "|" "text|$msg" "|" "dim|Nothing was left half installed." "|" "dim|Need a hand? Join the Discord:" "link|$DISCORD_URL")
  AMP_AUTO=0; AMPD=0
  tick; draw
  if [ "$HAVE_TTY" = 1 ]; then
    foot 1 "Press D to join the Discord, or any other key to close" "$C_LAV"
    any_key
    case "$KEY" in d|D) discord_screen ;; esac
  fi
  ui_end
  exit 1
}

# ── install flow ──────────────────────────────────────────────────────────────
APP=""; LATEST=""; INSTALLED_VER=""; IS_UPDATE=0; DL_URL=""; DIGEST=""; TOTAL=0; DMG=""; SUDO=""
LAST_S=0; LAST_SZ=0; SPEED=0; DL_T0=0; DL_TICKS=105; INST_T0=0; ETA="--:--"
RELEASE_JSON=""; CHOICE=""

fmt_eta() { # seconds -> ETA
  if [ "$1" -lt 0 ] || [ "$1" -gt 5999 ]; then ETA="--:--"; return 0; fi
  printf -v ETA '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 ))
}

dl_text() { # size
  local cur tot spd
  mb "$1"; cur=$MBS; mb "$TOTAL"; tot=$MBS; mb "$SPEED"; spd=$MBS
  if [ "$DW" -ge 36 ]; then STD[1]="${cur} of ${tot} MB   ${spd} MB/s   ETA ${ETA}"
  elif [ "$DW" -ge 22 ]; then STD[1]="${cur}/${tot} MB  ${spd} MB/s"
  else STD[1]="${spd} MB/s"
  fi
  STATUS_R="${PCT}%"
}

dl_hook_real() {
  local size
  [ $(( T % 5 )) -eq 0 ] || return 0
  size=$(stat -f %z "$DMG" 2>/dev/null || echo 0)
  PCT=$(( size * 100 / TOTAL )); clamp "$PCT" 0 100; PCT=$CL
  if [ "$SECONDS" -ne "$LAST_S" ]; then
    SPEED=$(( (size - LAST_SZ) / (SECONDS - LAST_S) ))
    LAST_S=$SECONDS; LAST_SZ=$size
  fi
  if [ "$SPEED" -gt 0 ]; then fmt_eta $(( (TOTAL - size) / SPEED )); else ETA="--:--"; fi
  dl_text "$size"
}

dl_hook_demo() {
  local dt=$(( T - DL_T0 )) size
  PCT=$(( dt * 100 / DL_TICKS )); clamp "$PCT" 0 100; PCT=$CL
  size=$(( TOTAL / 100 * PCT ))
  SPEED=$(( 6300000 + SINT[(T * 5) & 255] * 9000 ))
  fmt_eta $(( (TOTAL - size) / SPEED ))
  dl_text "$size"
  if [ "$PCT" -ge 100 ]; then SIM_DONE=1; fi
}

inst_hook_real() {
  local line
  [ $(( T % 5 )) -eq 0 ] || return 0
  if [ -r "$TMP/inst.stage" ]; then IFS= read -r line < "$TMP/inst.stage" || line=""; [ -z "$line" ] || STD[3]=$line; fi
}

inst_hook_demo() {
  local dt=$(( T - INST_T0 ))
  if [ "$dt" -lt 10 ]; then STD[3]="Quitting Boundless"
  elif [ "$dt" -lt 20 ]; then STD[3]="Opening disk image"
  elif [ "$dt" -lt 38 ]; then STD[3]="Copying the app"
  else STD[3]="Swapping in place"
  fi
  if [ "$dt" -ge 46 ]; then SIM_DONE=1; fi
}

check_job() {
  trap - EXIT INT TERM HUP
  curl -sS -m 20 -H "Accept: application/vnd.github+json" -o "$TMP/release.json" -w '%{http_code}' \
    "https://api.github.com/repos/$REPO/releases/latest" >"$TMP/check.code" 2>"$TMP/check.err" || true
}

download_job() {
  trap - EXIT INT TERM HUP
  curl -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 30 --retry 2 -o "$DMG" "$DL_URL" 2>"$TMP/dl.err"
}

verify_job() {
  trap - EXIT INT TERM HUP
  shasum -a 256 "$DMG" 2>/dev/null | awk '{print $1}' >"$TMP/sha"
}

install_job() {
  trap - EXIT INT TERM HUP
  local stage="$TMP/inst.stage" staged="$INSTALL_DIR/.Boundless.app.new" _
  if [ "$INSTALL_DIR" = /Applications ] && pgrep -xq Boundless 2>/dev/null; then
    echo "Quitting Boundless" >"$stage"
    osascript -e 'tell application "Boundless" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 25); do pgrep -xq Boundless || break; sleep 0.2; done
    pkill -x Boundless 2>/dev/null || true
  fi
  echo "Opening disk image" >"$stage"
  mkdir -p "$TMP/dmg"
  hdiutil attach "$DMG" -mountpoint "$TMP/dmg" -nobrowse -quiet >/dev/null 2>&1 || return 11
  [ -d "$TMP/dmg/Boundless.app" ] || return 12
  echo "Copying the app" >"$stage"
  $SUDO rm -rf "$staged"
  $SUDO ditto "$TMP/dmg/Boundless.app" "$staged" || { $SUDO rm -rf "$staged"; return 13; }
  echo "Swapping in place" >"$stage"
  $SUDO rm -rf "$APP"
  $SUDO mv "$staged" "$APP" || return 14
  hdiutil detach "$TMP/dmg" -quiet >/dev/null 2>&1 || true
  return 0
}

short_dir() {
  case "$INSTALL_DIR" in
    "$HOME"*) SHORT="~${INSTALL_DIR#"$HOME"}" ;;
    *) SHORT=$INSTALL_DIR ;;
  esac
}

stage_pause() { MIN_T=$(( T + ${1:-10} )); [ "$MODE" = anim ] || MIN_T=$T; }

stage_check() {
  local code arch_suffix size
  st_set 0 active "contacting GitHub"; STATUS="Checking for the latest version"; STATUS_R=""
  PCT=100; AMP_AUTO=1
  MIN_T=$INTRO_FRAMES; [ "$MODE" = anim ] || MIN_T=0
  if [ "$DEMO" = 1 ]; then
    sim_start 40
    LATEST=3.1.0; TOTAL=25400000; INSTALLED_VER=3.0.1; DIGEST="sha256:demo"; DL_URL="demo"
  else
    check_job & JOB_PID=$!
  fi
  await sim_hook
  if [ "$DEMO" != 1 ]; then
    code=$(cat "$TMP/check.code" 2>/dev/null || echo 000)
    case "$code" in
      200) ;;
      403|429) fatal "GitHub is limiting requests from this network. Wait a few minutes and run the installer again." ;;
      *) fatal "Could not reach GitHub. Check your internet connection and try again." ;;
    esac
    RELEASE_JSON=$(cat "$TMP/release.json")
    LATEST=$(json_field "$RELEASE_JSON" tag_name); LATEST=${LATEST#release-}; LATEST=${LATEST#v}
    [[ $LATEST =~ ^[0-9A-Za-z._-]+$ ]] || fatal "GitHub sent a release this installer does not understand."
    if [ "$(uname -m)" = arm64 ]; then arch_suffix="-macos-apple-silicon.dmg"; else arch_suffix="-macos-intel.dmg"; fi
    DL_URL=$(asset_field "$RELEASE_JSON" "$arch_suffix" url)
    DIGEST=$(asset_field "$RELEASE_JSON" "$arch_suffix" digest)
    size=$(asset_field "$RELEASE_JSON" "$arch_suffix" size)
    if [ -z "$DL_URL" ]; then
      DL_URL=$(asset_field "$RELEASE_JSON" "-macos.dmg" url)
      DIGEST=$(asset_field "$RELEASE_JSON" "-macos.dmg" digest)
      size=$(asset_field "$RELEASE_JSON" "-macos.dmg" size)
    fi
    [ -n "$DL_URL" ] || fatal "This release has no Mac download yet."
    [[ $DL_URL == https://github.com/$REPO/releases/download/* ]] || fatal "The release points somewhere unexpected, so nothing was downloaded."
    case "$size" in ''|*[!0-9]*|0) size=30000000 ;; esac
    TOTAL=$size
    INSTALLED_VER=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")
  fi
  IS_UPDATE=0
  if [ -d "$APP" ] || [ "$DEMO" = 1 ]; then
    if [ -n "$INSTALLED_VER" ] && [ "$INSTALLED_VER" != "$LATEST" ]; then IS_UPDATE=1; fi
  fi
  if [ "$IS_UPDATE" = 1 ]; then st_set 0 done "$INSTALLED_VER to $LATEST"; else st_set 0 done "Boundless $LATEST"; fi
}

stage_download() {
  st_set 1 active "starting"; STATUS="Downloading Boundless $LATEST"; STATUS_R="0%"
  PCT=0; SPEED=0; ETA="--:--"; AMP_AUTO=1
  if [ "$DEMO" = 1 ]; then
    DL_T0=$T; sim_start 99999
    MIN_T=$T
    await dl_hook_demo
  else
    DMG="$TMP/Boundless.dmg"; LAST_S=$SECONDS; LAST_SZ=0
    download_job & JOB_PID=$!
    MIN_T=$T
    await dl_hook_real
    if [ "$JOB_RC" -ne 0 ] || [ ! -s "$DMG" ]; then fatal "The download did not finish. Check your connection and try again."; fi
  fi
  PCT=100; mb "$TOTAL"; st_set 1 done "$MBS MB"; STATUS_R="100%"
}

stage_verify() {
  local got want
  st_set 2 active "SHA-256"; STATUS="Verifying the download"; STATUS_R=""
  PCT=100; AMP_AUTO=1
  stage_pause 14
  if [ "$DEMO" = 1 ]; then
    sim_start 24
    await sim_hook
    st_set 2 done "Checksum matches"
    return 0
  fi
  verify_job & JOB_PID=$!
  await
  got=$(cat "$TMP/sha" 2>/dev/null || echo "")
  if [[ $DIGEST =~ ^sha256:[0-9a-f]{64}$ ]]; then
    want=${DIGEST#sha256:}
    [ "$got" = "$want" ] || fatal "The download does not match its published checksum, so nothing was installed."
    st_set 2 done "Checksum matches"
  else
    st_set 2 done "No checksum published"
  fi
}

stage_install() {
  st_set 3 active "starting"; STATUS="Installing Boundless $LATEST"; STATUS_R=""
  PCT=100; AMP_AUTO=1
  stage_pause 12
  if [ "$DEMO" = 1 ]; then
    INST_T0=$T; sim_start 99999
    await inst_hook_demo
  else
    install_job & JOB_PID=$!
    await inst_hook_real
    case "$JOB_RC" in
      0) ;;
      11) fatal "Could not open the disk image." ;;
      12) fatal "The disk image does not contain Boundless.app." ;;
      13) fatal "Could not copy Boundless to $INSTALL_DIR." ;;
      *) fatal "Could not move Boundless into place in $INSTALL_DIR." ;;
    esac
  fi
  short_dir; st_set 3 done "$SHORT"
  if [ "$DEMO" = 1 ]; then st_set 3 done "Demo only"; fi
}

finale() {
  local i
  st_set 4 done "Ready to read"
  if [ "$DEMO" = 1 ]; then STATUS="Demo complete, nothing was installed"
  elif [ "$IS_UPDATE" = 1 ]; then STATUS="Updated to Boundless $LATEST"
  else STATUS="Boundless $LATEST is installed"
  fi
  STATUS_R=""; PCT=100; AMP_AUTO=0
  if [ "$MODE" = plain ]; then return 0; fi
  if [ "$MODE" != anim ]; then AMPD=0; tick; draw; return 0; fi
  for (( i = 0; i < 40; i++ )); do
    if [ "$i" -lt 12 ]; then AMPD=$(( 38 + i * 2 )); WSPD=$(( 9 + i * 2 ))
    elif [ "$i" -lt 30 ]; then AMPD=$(( 62 - (i - 12) * 3 )); WSPD=$(( 33 - (i - 12) )); PULSE=1
    else AMPD=0; WSPD=9; PULSE=0
    fi
    [ "$AMPD" -ge 0 ] || AMPD=0
    tick; draw; nap
  done
  PULSE=0; WSPD=9; AMPD=0
}

reset_stages() {
  local i
  for (( i = 0; i < 5; i++ )); do ST[i]=pending; STD[i]=""; done
}

post_menu() { # reinstall allowed?
  local can_launch=0 can_reinstall=$1
  [ "$INSTALL_DIR" = /Applications ] && [ "$DEMO" != 1 ] && can_launch=1
  while :; do
    MENU=()
    if [ "$can_launch" = 1 ]; then MENU[${#MENU[@]}]="L|Launch Boundless"; fi
    if [ "$can_reinstall" = 1 ]; then MENU[${#MENU[@]}]="R|Reinstall"; fi
    MENU[${#MENU[@]}]="D|Join the Discord"
    MENU[${#MENU[@]}]="N|What's new"
    MENU[${#MENU[@]}]="Q|Quit"
    menu_loop
    case "$CHOICE" in
      L) open "$APP" >/dev/null 2>&1 || true; break ;;
      R) CHOICE=R; return 0 ;;
      D) discord_screen ;;
      N) open_url "https://github.com/$REPO/releases/tag/v$LATEST" ;;
      *) break ;;
    esac
  done
  CHOICE=""
  foot 1 "Open Boundless anytime from Launchpad or Spotlight" "$C_LAV"
  foot 2 "Join the Discord: $DISCORD_URL" "$C_DIM"
  tick; draw
}

run_mac() {
  local osv
  case "$INSTALL_DIR" in ''|/) echo "Invalid install location." >&2; exit 1 ;; esac
  APP="$INSTALL_DIR/Boundless.app"
  if [ "$DEMO" != 1 ]; then
    osv=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1 || echo 0)
    case "$osv" in ''|*[!0-9]*) osv=0 ;; esac
    if [ "$osv" -lt 12 ]; then echo "Boundless requires macOS 12 or later." >&2; exit 1; fi
    mkdir -p "$INSTALL_DIR" 2>/dev/null || true
    if [ ! -w "$INSTALL_DIR" ]; then
      echo "Boundless needs administrator access to install in $INSTALL_DIR."
      sudo -v || exit 1
      SUDO="sudo -n"
    fi
  fi
  TMP=$(mktemp -d)
  if [ "$MODE" != plain ]; then ui_init; ui_begin; fi
  stage_check
  if [ "$IS_UPDATE" = 0 ] && [ -n "$INSTALLED_VER" ] && [ "$DEMO" != 1 ]; then
    # already current: offer to launch or reinstall
    for i in 1 2 3; do st_set "$i" done "Already up to date"; done
    st_set 4 done "Ready to read"
    STATUS="Boundless $LATEST is already installed"; STATUS_R=""; AMP_AUTO=0; AMPD=0; PCT=100
    if [ "$MODE" = plain ]; then say "Boundless $LATEST is already installed. Nothing to do."; return 0; fi
    tick; draw
    post_menu 1
    if [ "$CHOICE" = R ]; then reset_stages; st_set 0 done "Boundless $LATEST"; AMP_AUTO=1; else ui_end; return 0; fi
  fi
  stage_download
  stage_verify
  stage_install
  finale
  if [ "$MODE" = plain ]; then
    if [ "$DEMO" = 1 ]; then say "Demo complete. Nothing was installed."; else say "Done. Boundless $LATEST is installed in $INSTALL_DIR."; fi
    say "Join the Discord: $DISCORD_URL"
    return 0
  fi
  if [ "$HAVE_TTY" = 1 ]; then post_menu 0; else foot 1 "Open Boundless anytime from Launchpad or Spotlight" "$C_LAV"; foot 2 "Join the Discord: $DISCORD_URL" "$C_DIM"; tick; draw; fi
  ui_end
}

# ── main ──────────────────────────────────────────────────────────────────────
if [ "$OS_KIND" != mac ]; then
  show_unsupported
  exit 1
fi

if [ "$DISCORD_ONLY" = 1 ]; then
  discord_screen_only() {
    if [ "$MODE" = plain ]; then discord_screen; return 0; fi
    screen_in
    DISCORD_STANDALONE=1
    discord_screen
    ui_end
  }
  discord_screen_only
  exit 0
fi

run_mac
exit 0
