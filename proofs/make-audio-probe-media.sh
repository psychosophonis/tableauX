#!/bin/bash
# Makes the test files for audio-decode-probe.swift (spec § v5). Needs ffmpeg, plus
# macOS's afconvert for Apple's AAC encoder.
#
#   proofs/make-audio-probe-media.sh /tmp/audio-media
#
# The files are made so that the right answer is known in advance, which is what lets
# a measurement count as evidence:
#   clk-*        a click at exactly 1 s, in the containers and rates a student might use
#   dual-*       one signal on both channels, so L-R should be nothing
#   narrow-*     the same signal with a little difference added: real stereo, but only
#                just, the hardest case for telling stereo from dual mono
#   wide, left-only, right-only     the easy cases
#   mus-*        music-like tones as well as noise, since the first batch was all pink
#                noise, which turned out to be the worst case for one encoder
#   *-nopns      ffmpeg's AAC with perceptual noise substitution off, to test the
#                suspected reason noise through that encoder fails
set -u
mkdir -p "${1:-audio-probe-media}" && cd "${1:-audio-probe-media}" || exit 1
ff() { ffmpeg -y -hide_banner -loglevel error "$@"; }

# Click timing.
V=(-f lavfi -i color=c=black:s=320x180:r=30:d=4)
CLK="aevalsrc=if(lt(abs(t-1)\,0.0005)\,0.9\,0):s=48000:d=4"
CLK44="aevalsrc=if(lt(abs(t-1)\,0.0005)\,0.9\,0):s=44100:d=4"
ff "${V[@]}" -f lavfi -i "$CLK" -c:v libx264 -c:a aac -b:a 192k -shortest clk-aac48.mp4
ff "${V[@]}" -f lavfi -i "$CLK" -c:v libx264 -c:a aac -b:a 192k -shortest clk-aac48.mov
ff "${V[@]}" -f lavfi -i "$CLK44" -c:v libx264 -c:a aac -b:a 192k -shortest clk-aac44.mp4
ff "${V[@]}" -f lavfi -i "$CLK" -c:v libx264 -c:a pcm_s24le -shortest clk-pcm48.mov
ff -f lavfi -i "$CLK" -c:a pcm_s24le clk.wav
afconvert -f m4af -d aac -b 192000 clk.wav clk-apple.m4a

# Stereo classes, on pink noise.
M="anoisesrc=d=6:c=pink:r=48000:a=0.3:seed=1"
N2="anoisesrc=d=6:c=pink:r=48000:a=0.3:seed=2"
ff -f lavfi -i "$M" -filter_complex "[0]asplit[a][b];[a][b]join=inputs=2:channel_layout=stereo" -c:a pcm_s24le dual-pcm.wav
ff -i dual-pcm.wav -c:a aac -b:a 128k dual-aac128.m4a
ff -i dual-pcm.wav -c:a aac -aac_pns 0 -b:a 192k dual-aac-nopns.m4a
ff -i dual-pcm.wav -c:a libmp3lame -b:a 128k dual-mp3128.mp3
afconvert -f m4af -d aac -b 192000 dual-pcm.wav dual-apple.m4a
# The same signal with independent noise at about -84 dB on each side, as dither gives.
ff -f lavfi -i "$M" -f lavfi -i "anoisesrc=d=6:c=white:r=48000:a=0.00006:seed=5" -f lavfi -i "anoisesrc=d=6:c=white:r=48000:a=0.00006:seed=6" -filter_complex "[0]asplit[a][b];[a][1]amix=inputs=2:normalize=0[l];[b][2]amix=inputs=2:normalize=0[r];[l][r]join=inputs=2:channel_layout=stereo" -c:a pcm_s24le dual-dither.wav
for pc in 05 01; do
  a=0.$pc
  ff -f lavfi -i "$M" -f lavfi -i "$N2" -filter_complex "[0]asplit[a][b];[1]volume=$a,asplit[s1][s2];[a][s1]amix=inputs=2:normalize=0[l];[s2]volume=-1[ns];[b][ns]amix=inputs=2:normalize=0[r];[l][r]join=inputs=2:channel_layout=stereo" -c:a pcm_s24le narrow-$pc.wav
  ff -i narrow-$pc.wav -c:a aac -b:a 128k narrow-$pc-aac.m4a
done
afconvert -f m4af -d aac -b 192000 narrow-01.wav narrow-01-apple.m4a
ff -f lavfi -i "$M" -f lavfi -i "$N2" -filter_complex "[0][1]join=inputs=2:channel_layout=stereo" -c:a pcm_s24le wide.wav
ff -f lavfi -i "$M" -f lavfi -i "anullsrc=r=48000:cl=mono" -filter_complex "[0][1]join=inputs=2:channel_layout=stereo" -t 6 -c:a pcm_s24le left-only.wav
ff -f lavfi -i "anullsrc=r=48000:cl=mono" -f lavfi -i "$M" -filter_complex "[0][1]join=inputs=2:channel_layout=stereo" -t 6 -c:a pcm_s24le right-only.wav
ff -i left-only.wav -c:a aac -b:a 128k left-only-aac.m4a

# The same classes on a music-like source: harmonic tones under a slow tremolo, quiet noise.
MUS="aevalsrc=0.15*sin(2*PI*220*t)*(1+0.5*sin(2*PI*2*t))+0.1*sin(2*PI*440.7*t)+0.08*sin(2*PI*1320*t)*(1+sin(2*PI*5*t))+0.05*sin(2*PI*3100*t)+0.01*(random(1)-0.5):s=48000:d=6"
SIDE="aevalsrc=0.15*sin(2*PI*331*t)+0.1*sin(2*PI*887*t)+0.05*sin(2*PI*2400*t):s=48000:d=6"
ff -f lavfi -i "$MUS" -filter_complex "[0]asplit[a][b];[a][b]join=inputs=2:channel_layout=stereo" -c:a pcm_s24le mus-dual.wav
for pc in 03 10 30; do
  ff -f lavfi -i "$MUS" -f lavfi -i "$SIDE" -filter_complex "[0]asplit[a][b];[1]volume=0.$pc,asplit[s1][s2];[a][s1]amix=inputs=2:normalize=0[l];[s2]volume=-1[ns];[b][ns]amix=inputs=2:normalize=0[r];[l][r]join=inputs=2:channel_layout=stereo" -c:a pcm_s24le mus-side$pc.wav
done
for f in mus-dual mus-side03 mus-side10 mus-side30; do
  ff -i $f.wav -c:a aac -b:a 192k $f-ffaac.m4a
  ff -i $f.wav -c:a aac -aac_pns 0 -b:a 192k $f-ffaac-nopns.m4a
  afconvert -f m4af -d aac -b 192000 $f.wav $f-apple.m4a
  ff -i $f.wav -c:a libmp3lame -b:a 192k $f.mp3
done
ls | wc -l
