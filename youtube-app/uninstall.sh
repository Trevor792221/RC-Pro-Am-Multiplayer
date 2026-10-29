#!/usr/bin/env bash
# Removes the YouTube app installed by install.sh, including its Firefox profile.
set -euo pipefail

if [ "$(uname -s)" = Darwin ]; then
  rm -rf "$HOME/Applications/YouTube.app" "$HOME/Library/Application Support/YouTubeApp"
else
  DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
  rm -rf "$DATA/youtube-app" \
         "$HOME/snap/firefox/common/youtube-app-profile" \
         "$HOME/.var/app/org.mozilla.firefox/youtube-app-profile"
  rm -f "$DATA/applications/youtube-app.desktop" \
        "$DATA/icons/hicolor/scalable/apps/youtube-app.svg"
fi
echo "YouTube app removed."
