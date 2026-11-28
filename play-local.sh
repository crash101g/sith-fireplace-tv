#!/usr/bin/env bash
# Plays the Fireplace loop full screen on Linux (Pop!_OS, Ubuntu, ...), forever.
# Usage: ./play-local.sh             # play (Esc or q to quit)
#        ./play-local.sh --mute      # no crackle
#        ./play-local.sh --install   # add "Fireplace" to the app launcher
#        ./play-local.sh --uninstall # remove it again
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
VIDEO="$DIR/Fireplace.mp4"
DESKTOP="$HOME/.local/share/applications/fireplace.desktop"
ICON="$DIR/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png"

case "${1:-}" in
  --install)
    mkdir -p "$(dirname "$DESKTOP")"
    cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Fireplace
Comment=Full-screen looping Sith fireplace
Exec="$DIR/play-local.sh"
Icon=$( [ -f "$ICON" ] && echo "$ICON" || echo video-x-generic )
Terminal=false
Categories=AudioVideo;Video;
EOF
    chmod +x "$DESKTOP"
    update-desktop-database "$(dirname "$DESKTOP")" 2>/dev/null || true
    echo "Added 'Fireplace' to your app launcher."; exit 0 ;;
  --uninstall) rm -f "$DESKTOP"; echo "Removed launcher."; exit 0 ;;
esac

[ -f "$VIDEO" ] || { echo "No $VIDEO yet. Run: NO_APK=1 ./build.sh"; exit 1; }
MUTE=0; [ "${1:-}" = --mute ] && MUTE=1

# Keep the screen from blanking while the fire is on (GNOME/COSMIC honour this inhibit).
INHIBIT=(); command -v systemd-inhibit >/dev/null && \
  INHIBIT=(systemd-inhibit --what=idle:sleep --who="Fireplace" --why="Fireplace playing")

if command -v mpv >/dev/null; then
  # The clip ends on the frame it starts with; mpv's file loop replays it seamlessly.
  A=(); [ $MUTE = 1 ] && A=(--mute=yes)
  exec "${INHIBIT[@]}" mpv --fs --loop-file=inf --no-osc --osd-level=0 --cursor-autohide=always \
       --stop-screensaver=yes --title="Fireplace" "${A[@]}" "$VIDEO"
elif command -v vlc >/dev/null; then
  A=(); [ $MUTE = 1 ] && A=(--no-audio)
  exec "${INHIBIT[@]}" vlc --fullscreen --loop --no-video-title-show --qt-minimal-view "${A[@]}" "$VIDEO"
elif command -v ffplay >/dev/null; then
  A=(); [ $MUTE = 1 ] && A=(-an)
  exec "${INHIBIT[@]}" ffplay -fs -loop 0 -autoexit -loglevel error -window_title "Fireplace" "${A[@]}" "$VIDEO"
else
  echo "Install a player first: sudo apt install mpv"; exit 1
fi
