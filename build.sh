#!/usr/bin/env bash
# Rebuilds Vader Fireplace end to end: download -> encode -> assets -> APK -> (optional) install.
# Usage: ./build.sh [TV_IP[:PORT]]
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
RAW=app/src/main/res/raw/vader_fire.mp4
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
# (The audio pieces come from separately trimmed inputs: ffmpeg 6.1's
#  acrossfade outputs nothing when both pieces are atrim'd from one input.)
ffmpeg -y -v error -stats -i work/source.mp4 \
  -ss $((S+X)) -t $L -i work/source.mp4 \
  -ss $S -t $X -i work/source.mp4 -filter_complex "\
[0:v]trim=start_frame=$((S*30)):end_frame=$(((S+L)*30)),setpts=PTS-STARTPTS,\
$CROP,scale=1920:1080:flags=lanczos,setsar=1,fps=30,format=yuv420p[v];\
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
cp app/build/outputs/apk/release/app-release.apk VaderFireplace.apk
echo "Built $(pwd)/VaderFireplace.apk"

# 6. Optional install
if [ -n "$TV_IP" ]; then
  adb connect "$TV_IP"
  adb -s "$TV_IP" install -r VaderFireplace.apk
  adb -s "$TV_IP" shell am start -n com.crash101g.vaderfire/.MainActivity
fi
