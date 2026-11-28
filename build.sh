#!/usr/bin/env bash
# Rebuilds Sith Fireplace end to end:
#   download -> one seamless 60 s loop -> SithFireplace.mp4 (for Pop!_OS) + APK (for Google TV) -> (optional) install
# Usage: ./build.sh [TV_IP[:PORT]]
#        SCREENSAVER=1 ./build.sh TV_IP[:PORT]   # also make it the TV's screensaver
#        NO_APK=1 ./build.sh                     # only make the local Linux video
#        LOOP_START=120 ./build.sh               # take the minute from a different spot
set -euo pipefail
cd "$(dirname "$0")"

URL="${URL:-https://www.youtube.com/watch?v=mSX3OyW9Rao}"
LOOP_START="${LOOP_START:-60}"   # seconds into the source where the 1-minute clip starts (skips any intro)
LOOP_LEN="${LOOP_LEN:-60}"       # length of the loop: 1 minute
XFADE="${XFADE:-2}"              # picture + sound crossfade at the loop point, so the repeat has no seam
CRF="${CRF:-26}"                 # HEVC quality (lower = better/larger)
RAW=app/src/main/res/raw/sith_fire.mp4
LOCAL=SithFireplace.mp4          # the same loop, for playing on the PC (./play-local.sh)
SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
TV_IP="${1:-}"   # IP or IP:PORT (defaults to port 5555)
[ -n "$TV_IP" ] && [[ "$TV_IP" != *:* ]] && TV_IP="$TV_IP:5555"

mkdir -p work app/src/main/res/raw app/src/main/res/drawable-xhdpi app/src/main/res/mipmap-xxxhdpi

# 1. Tools
if ! command -v yt-dlp >/dev/null; then pipx install yt-dlp; export PATH="$HOME/.local/bin:$PATH"; fi
command -v ffmpeg >/dev/null || { echo "ffmpeg is required (sudo apt install ffmpeg)"; exit 1; }
if [ "${NO_APK:-0}" != 1 ]; then
  [ -d "$SDK" ] || { echo "Android SDK not found at $SDK (or run NO_APK=1 ./build.sh for the PC video only)"; exit 1; }
  echo "sdk.dir=$SDK" > local.properties
fi

# 2. Download only the part we need. A different URL invalidates the cached download.
NEED=$((LOOP_START + LOOP_LEN + XFADE + 5))
if [ ! -f work/source.mp4 ] || [ "$(cat work/source.url 2>/dev/null)" != "$URL|$NEED" ]; then
  rm -f work/source.*
  DUR=$(yt-dlp --print duration "$URL" 2>/dev/null | head -1 | cut -d. -f1 || true)
  if [[ "$DUR" =~ ^[0-9]+$ ]] && [ "$DUR" -lt "$NEED" ]; then
    LOOP_START=0
    NEED=$((LOOP_LEN + XFADE + 1))
    echo "Source is only ${DUR}s; taking the loop from the start."
  fi
  yt-dlp -f "bv*[height<=1080]+ba/b[height<=1080]" --download-sections "*0-$NEED" \
    --force-keyframes-at-cuts --merge-output-format mp4 -o "work/source.%(ext)s" "$URL"
  echo "$URL|$NEED" > work/source.url
fi
SRC=work/source.mp4

# 3. Find the picture area (cropdetect skips any letterbox/pillarbox bars), then take the
#    largest centred 16:9 window inside it so the fire fills the whole TV.
read -r CW CH CX CY < <(ffmpeg -v info -ss "$LOOP_START" -t 20 -i "$SRC" -vf "cropdetect=limit=24:round=2:reset=0" -an -f null - 2>&1 \
  | grep -o 'crop=[0-9:]*' | tail -1 | sed 's/crop=//; s/:/ /g')
if [ "${CW:-0}" -ge $((CH * 16 / 9)) ]; then NW=$((CH * 16 / 9 / 2 * 2)); NH=$CH; else NW=$CW; NH=$((CW * 9 / 16 / 2 * 2)); fi
NX=$((CX + (CW - NW) / 2)); NY=$((CY + (CH - NH) / 2))
CROP="crop=$NW:$NH:$NX:$NY"
echo "Picture area ${CW}x${CH}+${CX}+${CY} -> $CROP"

# 4. Encode one seamless 1-minute loop.
#    B = src[S+X, S+L+X)  is the body of the loop.
#    A = src[S,   S+X)    is crossfaded over B's last X seconds (picture and sound),
#    so the clip ends exactly on the frame it starts with and the repeat is invisible.
S=$LOOP_START; L=$LOOP_LEN; X=$XFADE
HAS_AUDIO=$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$SRC" | head -1)
VPREP="$CROP,scale=1920:1080:flags=lanczos,setsar=1,fps=30,format=yuv420p,setpts=PTS-STARTPTS"
FILTER="[0:v]$VPREP[vb];[1:v]$VPREP[va];[vb][va]xfade=transition=fade:duration=$X:offset=$((L - X)),format=yuv420p[v]"
MAPS=(-map "[v]")
if [ "$HAS_AUDIO" = audio ]; then
  FILTER="$FILTER;[0:a]aresample=48000,asetpts=PTS-STARTPTS[a1];[1:a]aresample=48000,asetpts=PTS-STARTPTS[a2];[a1][a2]acrossfade=d=$X:c1=qsin:c2=qsin[a]"
  MAPS+=(-map "[a]" -c:a aac -b:a 160k -ac 2)
fi
# (Two separately trimmed inputs: ffmpeg 6.1's acrossfade outputs nothing when both
#  pieces are atrim'd from one input.)
ffmpeg -y -v error -stats \
  -ss $((S + X)) -t "$L" -i "$SRC" \
  -ss "$S" -t "$X" -i "$SRC" \
  -filter_complex "$FILTER" "${MAPS[@]}" \
  -c:v libx265 -preset slow -crf "$CRF" -profile:v main -tag:v hvc1 \
  -x265-params "level-idc=41:log-level=error" -t "$L" \
  -movflags +faststart "$RAW"
[ "$HAS_AUDIO" != audio ] || [ "$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$RAW")" = audio ] \
  || { echo "ERROR: encoded clip has no audio track"; exit 1; }
cp "$RAW" "$LOCAL"
echo "Loop: $(pwd)/$LOCAL ($(du -h "$LOCAL" | cut -f1)). Play it on this PC with ./play-local.sh"

[ "${NO_APK:-0}" = 1 ] && exit 0

# 5. Banner (320x180) and icon from a frame of the clip
ffmpeg -y -v error -ss 20 -i "$RAW" -frames:v 1 work/frame.png
ffmpeg -y -v error -i work/frame.png -vf "scale=320:180" app/src/main/res/drawable-xhdpi/banner.png
ffmpeg -y -v error -i work/frame.png -vf "crop=ih:ih,scale=192:192" app/src/main/res/mipmap-xxxhdpi/ic_launcher.png

# 6. Build
./gradlew assembleRelease --console=plain
cp app/build/outputs/apk/release/app-release.apk SithFireplace.apk
echo "Built $(pwd)/SithFireplace.apk ($(du -h SithFireplace.apk | cut -f1))"

# 7. Optional install
if [ -n "$TV_IP" ]; then
  adb connect "$TV_IP"
  adb -s "$TV_IP" install -r SithFireplace.apk
  if [ "${SCREENSAVER:-0}" = 1 ]; then
    # Google TV's Settings only lists Google's Ambient Mode, so pick the dream via adb.
    adb -s "$TV_IP" shell settings put secure screensaver_enabled 1
    adb -s "$TV_IP" shell settings put secure screensaver_components com.crash101g.sithfire/.SithDreamService
    echo "Screensaver set. Revert with: adb shell settings delete secure screensaver_components"
  else
    adb -s "$TV_IP" shell am start -n com.crash101g.sithfire/.MainActivity
  fi
fi
