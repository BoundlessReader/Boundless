#!/bin/bash
# Boundless macOS installer and updater
# Usage: bash <(curl -fsSL "https://raw.githubusercontent.com/BoundlessReader/Boundless/main/install.sh")
#
# Downloads the latest release from github.com/BoundlessReader/Boundless,
# checks it against the SHA-256 GitHub publishes for the file, and replaces
# Boundless.app in /Applications. Set BOUNDLESS_INSTALL_DIR to install
# somewhere else.
set -euo pipefail

REPO="BoundlessReader/Boundless"
INSTALL_DIR="${BOUNDLESS_INSTALL_DIR:-/Applications}"

# ── colors & styles ───────────────────────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
RESET='\033[0m'

ok()   { printf "  ${GREEN}✓${RESET}  %b\n" "$1"; }
info() { printf "  ${CYAN}→${RESET}  %b\n" "$1"; }
warn() { printf "  ${YELLOW}!${RESET}  %b\n" "$1"; }
fail() { _spin_stop; printf "\n  ${RED}✗${RESET}  %s\n\n" "$1" >&2; exit 1; }

spin_pid=""

_spin_start() {
  local label="$1"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  while true; do
    for f in "${frames[@]}"; do
      printf "\r  ${CYAN}%s${RESET}  %s   " "$f" "$label"
      sleep 0.08
    done
  done &
  spin_pid=$!
}

_spin_stop() {
  if [ -n "$spin_pid" ]; then
    kill "$spin_pid" 2>/dev/null || true
    wait "$spin_pid" 2>/dev/null || true
    spin_pid=""
    printf "\r\033[K"  # clear the spinner line
  fi
}

TMP=""
MOUNT=""

_cleanup() {
  _spin_stop
  if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  fi
  if [ -n "$TMP" ]; then
    rm -rf "$TMP"
  fi
}
trap _cleanup EXIT

# Reads one answer from the terminal; anything but a terminal gets the default.
ask() {
  local prompt="$1" default="$2" reply=""
  printf "\n  %s " "$prompt" >&2
  if [ -t 0 ]; then
    read -r reply || reply=""
  else
    printf "\n" >&2
  fi
  echo "${reply:-$default}"
}

# Prints the value of one field of the first release asset whose name ends
# with the given suffix. Field is "url" or "digest". Empty if none matches.
asset_field() {
  osascript -l JavaScript - "$1" "$2" "$3" <<'JS' 2>/dev/null || true
function run(argv) {
  var release = JSON.parse(argv[0]);
  var assets = release.assets || [];
  for (var i = 0; i < assets.length; i++) {
    var name = assets[i].name || "";
    if (name.slice(-argv[1].length) === argv[1]) {
      return argv[2] === "digest" ? (assets[i].digest || "") : assets[i].browser_download_url;
    }
  }
  return "";
}
JS
}

release_field() {
  osascript -l JavaScript - "$1" "$2" <<'JS' 2>/dev/null || true
function run(argv) {
  return String(JSON.parse(argv[0])[argv[1]] || "");
}
JS
}

# ── header ────────────────────────────────────────────────────────────────────
printf "\n"
printf "  ${WHITE}${BOLD}Boundless${RESET}\n"
printf "  ${DIM}manga · comics · novels${RESET}\n"
printf "\n"

[ "$(uname -s)" = "Darwin" ] || fail "This installer is for macOS."

# ── detect arch ───────────────────────────────────────────────────────────────
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  ASSET_SUFFIX="-macos-apple-silicon.dmg"
  ARCH_LABEL="Apple Silicon"
else
  ASSET_SUFFIX="-macos-intel.dmg"
  ARCH_LABEL="Intel"
fi
ok "Detected: $ARCH_LABEL ($ARCH)"

# ── check macOS version ───────────────────────────────────────────────────────
OS_VER=$(sw_vers -productVersion)
OS_MAJOR=$(echo "$OS_VER" | cut -d. -f1)
if [ "$OS_MAJOR" -lt 12 ]; then
  fail "Boundless requires macOS 12 or later. You have $OS_VER."
fi

# ── fetch latest release info ─────────────────────────────────────────────────
_spin_start "Checking for latest release..."
RELEASE_JSON=$(curl -fsSL \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null) \
  || fail "Could not reach GitHub. Check your internet connection."
_spin_stop

TAG=$(release_field "$RELEASE_JSON" tag_name)
LATEST="${TAG#release-}"
LATEST="${LATEST#v}"
[ -n "$LATEST" ] || fail "Could not read the latest version from GitHub."

DOWNLOAD_URL=$(asset_field "$RELEASE_JSON" "$ASSET_SUFFIX" url)
DIGEST=$(asset_field "$RELEASE_JSON" "$ASSET_SUFFIX" digest)
if [ -z "$DOWNLOAD_URL" ]; then
  # Older releases only shipped one disk image for both chips.
  DOWNLOAD_URL=$(asset_field "$RELEASE_JSON" "-macos.dmg" url)
  DIGEST=$(asset_field "$RELEASE_JSON" "-macos.dmg" digest)
fi
[ -n "$DOWNLOAD_URL" ] || fail "Release $LATEST has no Mac download. See https://github.com/$REPO/releases/latest"

# ── check existing install ────────────────────────────────────────────────────
APP="$INSTALL_DIR/Boundless.app"
IS_UPDATE=false
INSTALLED_VER=""

if [ -d "$APP" ]; then
  INSTALLED_VER=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")
  if [ "$INSTALLED_VER" = "$LATEST" ]; then
    warn "Boundless $LATEST is already installed."
    REPLY=$(ask "Reinstall anyway? [y/N]" "n")
    [[ "$REPLY" =~ ^[Yy]$ ]] || { printf "\n  Nothing to do.\n\n"; exit 0; }
  else
    IS_UPDATE=true
    ok "Update: ${INSTALLED_VER:-unknown}  →  ${BOLD}$LATEST${RESET}"
  fi
else
  ok "Latest version: ${BOLD}$LATEST${RESET}"
fi

# ── check disk space (rough: need ~300 MB free) ───────────────────────────────
mkdir -p "$INSTALL_DIR" 2>/dev/null || true
FREE_KB=$(df -k "$INSTALL_DIR" | awk 'NR==2 {print $4}')
if [ "$FREE_KB" -lt 307200 ]; then
  fail "Not enough disk space. At least 300 MB free is required."
fi

# ── download ──────────────────────────────────────────────────────────────────
TMP=$(mktemp -d)
DMG="$TMP/Boundless.dmg"
MOUNT="$TMP/dmg"

printf "\n"
printf "  ${DIM}Downloading Boundless %s...${RESET}\n" "$LATEST"
# curl --progress-bar writes to stderr; indent it so it lines up with the rest
curl -fL --progress-bar -o "$DMG" "$DOWNLOAD_URL" 2>&1 | sed 's/^/  /' \
  || fail "Download failed."
[ -s "$DMG" ] || fail "Download failed."
ok "Downloaded"

# ── verify the download ───────────────────────────────────────────────────────
case "$DIGEST" in
  sha256:*)
    WANT="${DIGEST#sha256:}"
    GOT=$(shasum -a 256 "$DMG" | awk '{print $1}')
    [ "$GOT" = "$WANT" ] || fail "The download does not match its published checksum. Nothing was installed."
    ok "Checksum verified"
    ;;
  *)
    warn "GitHub published no checksum for this file, skipping the check."
    ;;
esac

# ── quit running instance if present ─────────────────────────────────────────
WAS_RUNNING=false
if [ "$INSTALL_DIR" = "/Applications" ] && pgrep -xq "Boundless" 2>/dev/null; then
  WAS_RUNNING=true
  _spin_start "Quitting Boundless..."
  osascript -e 'tell application "Boundless" to quit' 2>/dev/null || true
  # Wait up to 5 s for it to exit
  for _ in $(seq 1 25); do
    pgrep -xq "Boundless" || break
    sleep 0.2
  done
  # Force-quit if still alive
  pkill -x "Boundless" 2>/dev/null || true
  _spin_stop
  ok "Boundless quit"
fi

# ── mount DMG ─────────────────────────────────────────────────────────────────
mkdir -p "$MOUNT"
_spin_start "Mounting disk image..."
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet \
  || fail "Could not open the disk image."
_spin_stop
[ -d "$MOUNT/Boundless.app" ] || fail "The disk image does not contain Boundless.app."
ok "Disk image mounted"

# ── install ───────────────────────────────────────────────────────────────────
# Copy next to the old app first, then swap, so a failed copy never leaves
# the Mac without a working Boundless.
STAGED="$INSTALL_DIR/.Boundless.app.new"
SUDO=""
if [ ! -w "$INSTALL_DIR" ]; then
  warn "Elevated permissions needed for $INSTALL_DIR."
  SUDO="sudo"
fi
_spin_start "Installing to $INSTALL_DIR..."
$SUDO rm -rf "$STAGED"
if ! $SUDO ditto "$MOUNT/Boundless.app" "$STAGED"; then
  $SUDO rm -rf "$STAGED"
  fail "Could not copy Boundless.app to $INSTALL_DIR."
fi
$SUDO rm -rf "$APP"
$SUDO mv "$STAGED" "$APP"
_spin_stop
ok "Installed to $INSTALL_DIR"

# ── detach & clean up ─────────────────────────────────────────────────────────
hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
MOUNT=""

# ── done ──────────────────────────────────────────────────────────────────────
printf "\n"
if $IS_UPDATE; then
  printf "  ${GREEN}${BOLD}Updated to Boundless %s.${RESET}\n" "$LATEST"
else
  printf "  ${GREEN}${BOLD}Boundless %s installed.${RESET}\n" "$LATEST"
fi

# Re-launch if it was running before, otherwise ask
if $WAS_RUNNING; then
  open "$APP"
else
  REPLY=$(ask "Launch Boundless now? [Y/n]" "y")
  if [[ ! "$REPLY" =~ ^[Nn]$ ]] && [ "$INSTALL_DIR" = "/Applications" ]; then
    open "$APP"
  fi
fi
printf "\n"
