#!/usr/bin/env bash
# [claude] v4 P4c: a ready-to-run test show, packaged with the app.
#
# Makes dist/tableauX-<version>-test.zip with two folders, each a complete
# "send it and it just works" kit (docs/architecture.md § v4 › Zero setup):
#
#   Test conductor/  tableauX.app, Test show.tableaux, 1 Red/, 2 Blue/
#   Test player/     tableauX.app, 1 Red/, 2 Blue/          (no show = Player)
#
# Copy one folder to each Mac and open the app inside it.
#
# The clips are made for WATCHING SYNC, not for looking nice:
# - each work fills the screen with its own colour, so a change of work (and
#   the black gap) can't be missed;
# - the big number is "seconds.frame" from the start of the work: screens in
#   step show the same number, and a phone photo shows any offset in frames;
# - a white block flashes for the first 3 frames of every second, so screens
#   in step flash together, visible across a room.
# The two works have different lengths (12 s and 8 s), so the playlist's
# shared length and the gap between works are both visible.
#
# Needs ffmpeg, and the app already built: run scripts/make-app.sh first.
# Usage: scripts/make-test-show.sh 0.3.7
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?usage: scripts/make-test-show.sh <version>}"
app="dist/tableauX.app"
[ -d "$app" ] || { echo "build the app first: scripts/make-app.sh ${version}"; exit 1; }
font=/System/Library/Fonts/Supplemental/Arial.ttf
fps=30
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
media="$work/media"

# clip <folder> <work number> <colour name> <colour> <screen> <seconds>
clip() {
  local folder=$1 n=$2 name=$3 colour=$4 screen=$5 secs=$6
  mkdir -p "$media/$folder"
  # The count: whole seconds, then the frame within the second (00–29).
  # Colons inside drawtext expressions are escaped (\:) so ffmpeg's filter
  # parser doesn't read them as option separators.
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=${colour}:s=1920x1080:r=${fps}:d=${secs}" \
    -vf "drawtext=fontfile=${font}:text='WORK ${n} · ${name} · SCREEN ${screen}':x=(w-tw)/2:y=h*0.08:fontsize=h/12:fontcolor=white,\
drawtext=fontfile=${font}:text='%{eif\:floor(t)\:d}.%{eif\:mod(n\,${fps})\:d\:2}':x=(w-tw)/2:y=(h-th)/2:fontsize=h/2.2:fontcolor=white,\
drawbox=x=iw*0.04:y=ih*0.78:w=ih*0.16:h=ih*0.16:color=white:t=fill:enable='lt(mod(n\,${fps})\,3)',\
drawtext=fontfile=${font}:text='tableauX test show  ·  count = seconds.frame (${fps} frames a second)':x=(w-tw)/2:y=h*0.9:fontsize=h/24:fontcolor=white@0.7" \
    -c:v libx264 -pix_fmt yuv420p -preset veryfast -crf 20 \
    "$media/$folder/${screen}.mp4"
}
# Deliberately UNNUMBERED (no "_N"): every Mac gets the same files, and "_N"
# counts screens across the whole tableau, so a player after a 2-display
# conductor would find "_1" and "_2" numbered for the conductor's screens and
# leave them unused. Plain names fill each Mac's own displays in order.

for s in 1 2 3; do
  clip "1 Red"  1 RED  0xB0101A "$s" 12
  clip "2 Blue" 2 BLUE 0x1030A8 "$s" 8
done

# The show (format version 3, docs/architecture.md § v4 › Model). One machine
# named "Test": a one-machine show opens on any Mac, and a conductor adopts
# it as its own when the first player joins.
panels() { printf '[{"audio":false,"file":"%s/1.mp4","scaling":"fit"},{"audio":false,"file":"%s/2.mp4","scaling":"fit"},{"audio":false,"file":"%s/3.mp4","scaling":"fit"}]' "$1" "$1" "$1"; }
cat > "$work/Test show.tableaux" <<EOF
{
  "version": 3,
  "machines": [{"name": "Test", "displays": 3}],
  "works": [
    {"name": "1 Red", "repeat": 1, "shorter": "black", "screens": {"Test": $(panels "1 Red")}},
    {"name": "2 Blue", "repeat": 1, "shorter": "black", "screens": {"Test": $(panels "2 Blue")}}
  ],
  "playlist": {"gap": 3, "loop": true},
  "sync": {"tolerance": 3, "grace": 5},
  "playOnLaunch": false
}
EOF

kit="$work/kit"
for role in conductor player; do
  dir="$kit/Test ${role}"
  mkdir -p "$dir"
  ditto "$app" "$dir/tableauX.app"            # ditto keeps the signature intact
  cp -R "$media/1 Red" "$media/2 Blue" "$dir/"
done
cp "$work/Test show.tableaux" "$kit/Test conductor/"

rm -f "dist/tableauX-${version}-test.zip"
(cd "$kit" && ditto -c -k --sequesterRsrc . "../test.zip")
mv "$work/test.zip" "dist/tableauX-${version}-test.zip"
echo "zipped dist/tableauX-${version}-test.zip ($(du -h "dist/tableauX-${version}-test.zip" | cut -f1))"
