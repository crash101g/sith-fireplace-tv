#!/usr/bin/env bash
# Rebuilds Sith Fireplace TV end to end: download -> encode -> assets -> APK -> (optional) install.
# Usage: ./build.sh [TV_IP[:PORT]]
#        SCREENSAVER=1 ./build.sh TV_IP[:PORT]   # also make it the TV's screensaver
#        PREP_UPSCALE=1 ./build.sh   # make work/upscale_input.mkv for colab/upscale.ipynb
# If work/sith_upscaled.mp4 (the AI-upscaled loop from Colab) exists, it is used
# as the picture instead of the plain crop+scale.
set -euo pipefail
cd "$(dirname "$0")"

URL="https://www.youtube.com/watch?v=CRbiqM6kif8"
# The source repeats its picture exactly every 60 s (1800 frames) after a ~24 s
# intro, so one cycle looped forever looks identical to the original.
# Its audio does NOT repeat, so it is made seamless with a crossfade.
LOOP_START=60     # seconds into the source (any point after the intro works)
LOOP_LEN=60       # one video cycle
XFADE=2           # audio crossfade length at the loop point
CRF=26            # HEVC quality (lower = better/larger; 23 gave a 21.5 MB APK)
RAW=app/src/main/res/raw/sith_fire.mp4
UP_IN=work/upscale_input.mkv    # small lossless loop to upload to Colab
UP_OUT=work/sith_upscaled.mp4   # AI-upscaled loop downloaded back from Colab
SDK="${ANDROID_HOME:-$HOME/Android/Sdk}"
TV_IP="${1:-}"   # IP or IP:PORT (defaults to port 5555)
[ -n "$TV_IP" ] && [[ "$TV_IP" != *:* ]] && TV_IP="$TV_IP:5555"

mkdir -p work app/src/main/res/raw app/src/main/res/drawable-xhdpi app/src/main/res/mipmap-xxxhdpi

# 1. Tools
if ! command -v yt-dlp >/dev/null; then pipx install yt-dlp; export PATH="$HOME/.local/bin:$PATH"; fi
command -v ffmpeg >/dev/null || { echo "ffmpeg is required (sudo apt install ffmpeg)"; exit 1; }
[ -d "$SDK" ] || { echo "Android SDK not found at $SDK"; exit 1; }
echo "sdk.dir=$SDK" > local.properties

# 2. Download only the start (the source is 8 hours long)
if [ ! -f work/source.mp4 ]; then
  yt-dlp -f "bv*[height<=1080]+ba/b[height<=1080]" --download-sections "*0-$((LOOP_START + LOOP_LEN + XFADE + 10))" \
    --merge-output-format mp4 -o "work/source.%(ext)s" "$URL"
fi

# 3. Encode one seamless 60 s loop as HEVC.
#    The source is letterboxed (1920x804 picture at y=138); crop a 16:9 centre
#    so the video fills the whole screen with no black bars.
#    Video: exactly one cycle, frames [LOOP_START, LOOP_START+LOOP_LEN).
#    Audio: src[S+X, S+L+X) with its last X s crossfaded (equal power) into
#    src[S, S+X), so the end flows straight back into the start.
CROP="crop=1422:800:249:140"
S=$LOOP_START; L=$LOOP_LEN; X=$XFADE
TRIM="trim=start_frame=$((S*30)):end_frame=$(((S+L)*30)),setpts=PTS-STARTPTS"

# 3a. Optional: prepare the input for AI upscaling (colab/upscale.ipynb).
#     The crop is halved to 712x400 first: Real-ESRGAN x4plus is 4x faster on it
#     and looks almost the same once its 4x output is brought down to 1080p.
if [ "${PREP_UPSCALE:-0}" = 1 ]; then
  ffmpeg -y -v error -stats -i work/source.mp4 -an \
    -vf "$TRIM,$CROP,scale=712:400:flags=area,setsar=1,format=yuv444p" \
    -c:v libx264 -preset veryslow -qp 0 "$UP_IN"
  echo "Upload $(pwd)/$UP_IN to Google Drive: My Drive/sith_upscale/"
  echo "Then run colab/upscale.ipynb and download sith_upscaled.mp4 to $(pwd)/$UP_OUT"
  exit 0
fi

if [ -f "$UP_OUT" ]; then
  [ "$(ffprobe -v error -select_streams v -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$UP_OUT")" = $((L*30)) ] \
    || { echo "ERROR: $UP_OUT should have $((L*30)) frames"; exit 1; }
  echo "Using AI-upscaled picture from $UP_OUT"
  VIN="$UP_OUT"; VF="setpts=PTS-STARTPTS"
else
  VIN=work/source.mp4; VF="$TRIM,$CROP,scale=1920:1080:flags=lanczos"
fi
# (The audio pieces come from separately trimmed inputs: ffmpeg 6.1's
#  acrossfade outputs nothing when both pieces are atrim'd from one input.)
ffmpeg -y -v error -stats -i "$VIN" \
  -ss $((S+X)) -t $L -i work/source.mp4 \
  -ss $S -t $X -i work/source.mp4 -filter_complex "\
[0:v]$VF,setsar=1,fps=30,format=yuv420p[v];\
[1:a]asetpts=PTS-STARTPTS[a1];[2:a]asetpts=PTS-STARTPTS[a2];\
[a1][a2]acrossfade=d=$X:c1=qsin:c2=qsin[a]" \
  -map "[v]" -map "[a]" \
  -c:v libx265 -preset slow -crf $CRF -profile:v main -tag:v hvc1 \
  -x265-params "level-idc=41:log-level=error" \
  -c:a aac -b:a 160k -ac 2 -movflags +faststart "$RAW"
[ "$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$RAW")" = audio ] \
  || { echo "ERROR: encoded clip has no audio track"; exit 1; }

# 4. Banner (320x180) and icon from a frame of the clip
ffmpeg -y -v error -ss 20 -i "$RAW" -frames:v 1 work/frame.png
ffmpeg -y -v error -i work/frame.png -vf "scale=320:180" app/src/main/res/drawable-xhdpi/banner.png
ffmpeg -y -v error -i work/frame.png -vf "crop=ih:ih,scale=192:192" app/src/main/res/mipmap-xxxhdpi/ic_launcher.png

# 5. Build
./gradlew assembleRelease --console=plain
cp app/build/outputs/apk/release/app-release.apk SithFireplace.apk
echo "Built $(pwd)/SithFireplace.apk"

# 6. Optional install
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
