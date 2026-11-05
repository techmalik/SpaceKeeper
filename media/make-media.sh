#!/bin/bash
# Turns a raw `screencapture -v` recording of demo.sh into the captioned MP4, GIF and README screenshot.
#   media/make-media.sh raw.mov
# The cut points below match the recording made on 2026-11-05; re-check them (contact sheet) after a new take.
set -euo pipefail
RAW="$1"
OUT="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
BG="0xB5B6BD"            # Space Gray wallpaper, used for the side padding

# Kept pieces of the raw take (seconds) and the caption shown over each run of them.
#   a 4.0–7.0 + 9.0–10.2   ⌃⌥⌘2, window lands on Desktop 2, back on Desktop 1
#   b 10.8–15.0            hover Safari in the Dock
#   c 16.0–20.3            click Safari on Desktop 2 (no window there) → new window here
#   d 20.3–24.2            click again → minimize, click again → restore
CUTS=("4.0 7.0" "9.0 10.2" "10.8 15.0" "16.0 24.2")
CAPTIONS=(
  "0.0 4.2 ⌃⌥⌘2 sends the window to Desktop 2"
  "4.2 8.4 Dock previews show only this desktop’s windows"
  "8.4 12.7 No Safari here? Clicking it opens a window right here"
  "12.7 16.6 Click the front app’s icon to minimize, again to restore"
)
SHOT_AT=13.0             # raw-take time of the Dock preview frame

# Caption pills as transparent 1920x1080 PNGs.
python3 - "$WORK" "${CAPTIONS[@]}" <<'EOF'
import sys
from PIL import Image, ImageDraw, ImageFont
work, caps = sys.argv[1], sys.argv[2:]
font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 46)
try: font.set_variation_by_name("Semibold")
except Exception: pass
for i, c in enumerate(caps):
    text = c.split(" ", 2)[2]
    im = Image.new("RGBA", (1920, 1080), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    l, t, r, b = d.textbbox((0, 0), text, font=font)
    w, h = r - l, b - t
    px, py, y = 40, 22, 30
    x = (1920 - w) // 2
    d.rounded_rectangle((x - px, y, x + w + px, y + h + 2 * py), radius=(h + 2 * py) // 2, fill=(22, 22, 26, 220))
    d.text((x - l, y + py - t), text, font=font, fill=(255, 255, 255, 255))
    im.save(f"{work}/cap{i}.png")
EOF

# Cut, join, scale to 1080 high, pad to 1920x1080, overlay captions with short fades.
fc=""; n=0
for c in "${CUTS[@]}"; do
  set -- $c
  fc+="[0:v]trim=$1:$2,setpts=PTS-STARTPTS[s$n];"; n=$((n+1))
done
for ((i=0;i<n;i++)); do fc+="[s$i]"; done
fc+="concat=n=$n:v=1:a=0,fps=30,scale=-2:1080:flags=lanczos,pad=1920:1080:(ow-iw)/2:0:color=$BG[base];"
inputs=(); last="base"
for i in "${!CAPTIONS[@]}"; do
  set -- ${CAPTIONS[$i]}
  st=$1; en=$2; d=$(echo "$en - $st" | bc)
  inputs+=(-loop 1 -t "$d" -i "$WORK/cap$i.png")
  fc+="[$((i+1)):v]format=rgba,fade=in:st=0:d=0.25:alpha=1,fade=out:st=$(echo "$d - 0.25" | bc):d=0.25:alpha=1,setpts=PTS+$st/TB[c$i];"
  fc+="[$last][c$i]overlay=0:0:eof_action=pass[o$i];"; last="o$i"
done
fc="${fc%;}"

ffmpeg -v error -y -i "$RAW" "${inputs[@]}" -filter_complex "$fc" -map "[$last]" -an \
  -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -r 30 -movflags +faststart "$OUT/spacekeeper-demo.mp4"

# GIF: 800 px wide, 12 fps, palette from the whole clip.
ffmpeg -v error -y -i "$OUT/spacekeeper-demo.mp4" \
  -vf "fps=12,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 "$OUT/spacekeeper-demo.gif"

# README screenshot: the Dock preview frame, full Retina resolution, no caption.
ffmpeg -v error -y -ss "$SHOT_AT" -i "$RAW" -frames:v 1 "$OUT/screenshot.png"

rm -rf "$WORK"
ls -la "$OUT"/spacekeeper-demo.mp4 "$OUT"/spacekeeper-demo.gif "$OUT"/screenshot.png
