#!/usr/bin/env bash
# Generates sync test clips: one file per panel, all the same length.
#
# Each clip shows a white vertical line that sweeps across ALL panels as if they
# were one wide screen: it leaves the right edge of panel 1 on the same frame it
# enters the left edge of panel 2. If the panels are in sync, the line crosses
# each gap cleanly; if one panel is late, the line jumps or doubles at that gap.
# Each frame also carries its frame number, so a photo of the array shows the
# offset between panels directly, in frames.
#
# Usage: scripts/make-test-media.sh [outdir] [width] [height] [seconds] [panels]
#   scripts/make-test-media.sh testmedia 1920 1080 10 3   # lab sweep test
#   scripts/make-test-media.sh testmedia 3840 2160 10 3   # 4K decode load test
set -euo pipefail

out=${1:-testmedia}
w=${2:-1920}
h=${3:-1080}
secs=${4:-10}
panels=${5:-3}
fps=30
font=/System/Library/Fonts/Supplemental/Arial.ttf
line=$(( w / 96 > 4 ? w / 96 : 4 ))   # line thickness scales with resolution
mkdir -p "$out"

for (( i = 0; i < panels; i++ )); do
  # Global sweep position g runs 0 → panels·w over the clip, so one full sweep
  # per loop. This panel draws the line at g − i·w; off-panel values draw nothing.
  x="mod(t/${secs},1)*${panels}*${w}-${i}*${w}"
  # The line is a white source overlaid at x; overlay re-evaluates x every frame
  # (eval=frame), which drawbox does not.
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=black:s=${w}x${h}:r=${fps}:d=${secs}" \
    -f lavfi -i "color=c=white:s=${line}x${h}:r=${fps}:d=${secs}" \
    -filter_complex "[0][1]overlay=x='${x}':y=0:eval=frame,\
drawtext=fontfile=${font}:text='PANEL $((i + 1))   frame %{frame_num}':\
x=(w-tw)/2:y=h*0.8:fontsize=h/14:fontcolor=gray" \
    -c:v libx264 -pix_fmt yuv420p -preset veryfast -crf 23 \
    "$out/panel$((i + 1))-${w}x${h}-${secs}s.mp4"
  echo "wrote $out/panel$((i + 1))-${w}x${h}-${secs}s.mp4"
done
