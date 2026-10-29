#!/usr/bin/env bash
# Installs "YouTube" as a desktop app on Linux or macOS: a dedicated Firefox
# profile with uBlock Origin, no browser toolbars, and YouTube's app layout.
#
#   ./install.sh                 mobile-app layout (m.youtube.com) in a window
#   ./install.sh --layout tv     TV-app layout (youtube.com/tv), fullscreen
set -euo pipefail

UBO_URL="https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi"
UBO_ID="uBlock0@raymondhill.net"
APP_ID="YouTubeApp"
LAYOUT="mobile"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --layout) LAYOUT="${2:-}"; shift 2 ;;
    --layout=*) LAYOUT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
case "$LAYOUT" in mobile|tv) ;; *) die "--layout must be 'mobile' or 'tv'" ;; esac

SRC="$(cd "$(dirname "$0")" && pwd)"
OS="$(uname -s)"

# --- Find Firefox -----------------------------------------------------------

KIND=native
FIREFOX=()
if [ "$OS" = Darwin ]; then
  for app in "/Applications/Firefox.app" "$HOME/Applications/Firefox.app"; do
    if [ -x "$app/Contents/MacOS/firefox" ]; then
      FIREFOX=("$app/Contents/MacOS/firefox")
      FF_VERSION="$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
      break
    fi
  done
else
  for name in firefox firefox-esr; do
    if path="$(command -v "$name")"; then
      FIREFOX=("$path")
      if [[ "$(readlink -f "$path")" == /snap/* ]] || grep -qs '/snap/' "$path"; then
        KIND=snap
      fi
      break
    fi
  done
  if [ ${#FIREFOX[@]} -eq 0 ] && command -v flatpak >/dev/null &&
     flatpak info org.mozilla.firefox >/dev/null 2>&1; then
    KIND=flatpak
    FIREFOX=(flatpak run org.mozilla.firefox)
  fi
fi
[ ${#FIREFOX[@]} -gt 0 ] || die "Firefox not found. Install Firefox first."

if [ -z "${FF_VERSION:-}" ]; then
  FF_VERSION="$("${FIREFOX[@]}" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)*' | head -n1 || true)"
fi
FF_MAJOR="${FF_VERSION%%.*}"
[[ "$FF_MAJOR" =~ ^[0-9]+$ ]] || FF_MAJOR=140
echo "Using Firefox $FF_MAJOR (${KIND}): ${FIREFOX[*]}"

# --- Paths ------------------------------------------------------------------

if [ "$OS" = Darwin ]; then
  APP_HOME="$HOME/Library/Application Support/$APP_ID"
  PROFILE="$APP_HOME/profile"
else
  APP_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/youtube-app"
  # Snap and Flatpak Firefox can only open profiles inside their own sandbox.
  case "$KIND" in
    snap)    PROFILE="$HOME/snap/firefox/common/youtube-app-profile" ;;
    flatpak) PROFILE="$HOME/.var/app/org.mozilla.firefox/youtube-app-profile" ;;
    *)       PROFILE="$APP_HOME/profile" ;;
  esac
fi

# --- Layout -----------------------------------------------------------------

if [ "$LAYOUT" = tv ]; then
  URL="https://www.youtube.com/tv"
  UA="Mozilla/5.0 (PS4; Leanback Shell) Gecko/20100101 Firefox/65.0 LeanbackShell/01.00.01.75 Sony PS4/ (PS4, , no, CH)"
  EXTRA_ARGS="--kiosk"
else
  URL="https://m.youtube.com/"
  UA="Mozilla/5.0 (Android 14; Mobile; rv:$FF_MAJOR.0) Gecko/$FF_MAJOR.0 Firefox/$FF_MAJOR.0"
  EXTRA_ARGS=""
fi

# --- Profile ----------------------------------------------------------------

mkdir -p "$APP_HOME" "$PROFILE/chrome" "$PROFILE/extensions"

sed -e "s|__UA__|$UA|" -e "s|__URL__|$URL|" "$SRC/profile/user.js" > "$PROFILE/user.js"
cp "$SRC/profile/chrome/userChrome.css" "$SRC/profile/chrome/userContent.css" "$PROFILE/chrome/"
# Only seed the window size once, so later resizing is remembered.
[ -e "$PROFILE/xulstore.json" ] || cp "$SRC/profile/xulstore.json" "$PROFILE/"

echo "Downloading uBlock Origin..."
xpi="$PROFILE/extensions/$UBO_ID.xpi"
if command -v curl >/dev/null; then
  curl -fsSL -o "$xpi.part" "$UBO_URL"
elif command -v wget >/dev/null; then
  wget -qO "$xpi.part" "$UBO_URL"
else
  die "need curl or wget to download uBlock Origin"
fi
mv "$xpi.part" "$xpi"

# --- Launcher ---------------------------------------------------------------

LAUNCHER="$APP_HOME/youtube-app"
{
  echo '#!/bin/sh'
  printf 'exec'
  printf ' %q' "${FIREFOX[@]}" --profile "$PROFILE" --name "$APP_ID" --class "$APP_ID"
  [ -n "$EXTRA_ARGS" ] && printf ' %s' "$EXTRA_ARGS"
  printf ' %q\n' "$URL"
} > "$LAUNCHER"
chmod +x "$LAUNCHER"
cp "$SRC/icon.svg" "$SRC/icon.png" "$APP_HOME/"

if [ "$OS" = Darwin ]; then
  BUNDLE="$HOME/Applications/YouTube.app"
  rm -rf "$BUNDLE"
  mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
  printf '#!/bin/sh\nexec %q\n' "$LAUNCHER" > "$BUNDLE/Contents/MacOS/YouTube"
  chmod +x "$BUNDLE/Contents/MacOS/YouTube"
  iconset="$(mktemp -d)/icon.iconset"
  mkdir -p "$iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$SRC/icon.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null 2>&1 || true
  done
  iconutil -c icns "$iconset" -o "$BUNDLE/Contents/Resources/icon.icns" 2>/dev/null || true
  cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>YouTube</string>
  <key>CFBundleDisplayName</key><string>YouTube</string>
  <key>CFBundleIdentifier</key><string>local.youtube-app</string>
  <key>CFBundleExecutable</key><string>YouTube</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
EOF
  echo "Installed: $BUNDLE (open it from Launchpad or ~/Applications)"
else
  APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
  mkdir -p "$APPS" "$ICONS"
  cp "$SRC/icon.svg" "$ICONS/youtube-app.svg"
  cat > "$APPS/youtube-app.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=YouTube
Comment=YouTube in Firefox with uBlock Origin
Exec="$LAUNCHER"
Icon=youtube-app
Terminal=false
Categories=AudioVideo;Video;Player;
StartupWMClass=$APP_ID
EOF
  command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" >/dev/null 2>&1 || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q "${ICONS%/scalable/apps}" >/dev/null 2>&1 || true
  echo "Installed: \"YouTube\" in your app menu (or run $LAUNCHER)"
fi
