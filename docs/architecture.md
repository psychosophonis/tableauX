# Architecture specification

This is a NORMATIVE document: the implementation MUST match what is written
here. Update it BEFORE you change behaviour, then make the code follow.

## Purpose

A macOS app that plays one video file per display, in sync, for a gallery or
lab screen array (BCM116: a Mac mini driving three 4K displays). It replaces
"one huge file stretched across a virtual display", which resamples the image
and produces artefacts.

Non-goals (v1): network sync between computers, projection warping or edge
blending, routing audio to particular output devices, playlists, editing.

## Targets (measurable)

| # | Target | How it is checked |
|---|--------|-------------------|
| T1 | Panels start within 1 frame (33 ms at 30 fps) of each other | `proofs/sync-probe.swift`, timebase skew at start |
| T2 | Equal-length panels stay within 1 frame across 100+ loops | `proofs/sync-probe.swift`, max skew over the run |
| T3 | A panel more than 1 frame out is pulled back within 2 s | `SyncMathTests` (decision); lab run (behaviour) |
| T4 | 3 × 4K H.264 at 30 fps decodes with no dropped frames on Apple silicon | `proofs/sync-probe.swift --4k` here; lab run on the Mac mini |
| T5 | Each panel's pixels map to its display with no stretching (aspect kept) | `PlacementTests` |
| T6 | Display-to-display presentation offset is invisible on a sweep-line test | Lab only: `scripts/make-test-media.sh` clips on the array. Nothing on a one-display Mac can test this. |

## Model

### Display order
Displays are numbered 1..N left to right by their position in macOS's display
arrangement (frame origin x, then y for ties). Panel *n* plays on display *n*.

### Show file (`.msshow`, JSON)

```
Show {
  version: 1
  panels: [Panel]            // index = display number - 1
  playOnLaunch: bool         // reopen this show and play when the app starts
}
Panel {
  file: string | null        // absolute path; null = panel stays black
  audio: bool                // false = muted
  scaling: "fit" | "fill"    // fit: whole frame visible, letterboxed; fill: crop to cover
}
```

Errors: unknown version → refuse to open; missing file → panel shown as
missing in setup, playback refused until fixed or cleared.

### Scaling
The video is scaled uniformly (same factor on both axes) to the display's
point size. `fit` = min(sw/vw, sh/vh); `fill` = max(...), centred and cropped.
A 1920 × 1080 file on a 3840 × 2160 display is exactly 2×.

## Sync

- One `AVPlayer` per panel. Every player's master clock is the host clock.
- Each item is an `AVMutableComposition` made of the file repeated end to end
  (enough repeats for ≥ 24 h), so looping is gapless and item time is
  continuous: at host time `h`, every panel's expected item time is
  `(h − h0) mod duration`, where `h0` is the shared start host time.
- Start: preroll every player, then call `setRate(1, time: .zero, atHostTime: h0)`
  on each with the same `h0 = now + 1 s`.
- Drift check every 1 s: read each panel's time at a common host time via its
  item timebase; if |actual − expected| > 1 frame, re-sync that panel with
  `setRate(1, time: expected(h1), atHostTime: h1)` for `h1 = now + 0.5 s`.
- Pause/resume pauses and restarts all panels together from a shared host time.
- Panels of different lengths loop independently on their own durations (they
  drift in phase on purpose). Setup warns when lengths differ by > 1 frame.

## UI

- Setup window: one row per detected display (number, name, resolution), each
  with Choose file / Clear, Audio on/off, Fit/Fill, and the file's resolution
  and duration. Buttons: Open, Save, Play. Checkbox: Play on launch.
- Playback: a borderless window covering each display above the menu bar,
  black background, cursor hidden, display sleep prevented.
  Keys: Space pause/resume, Esc stop and return to setup.
- Displays added, removed, moved or resized during playback: stop and return
  to setup. The trigger is a change in the sorted display list (id, position,
  pixel size), not every screen-parameter notification: hiding the Dock and
  menu bar for playback posts one too, and must not stop the show.

## v2 DRAFT: several videos per display, sync control

<!-- [claude] Drafted 2026-10-21 from Mat's choices: free rectangles; sync
groups, per-video offsets, free-running videos and live nudge; per-video audio.
NOT normative until Mat confirms it. The sections above stay the contract until
then; on confirmation this replaces Model › Show file, extends Sync and UI, and
the decisions marked ▸ are Claude's proposals. -->

### Model
```
Show {
  version: 2
  displays: [DisplayLayout]  // index = display number - 1
  groups: [Group]            // at least one; "main" by default
  playOnLaunch: bool
}
DisplayLayout { videos: [Video] }   // empty = display stays black; later videos draw on top
Video {
  file: string | null
  rect: { x, y, w, h }       // ▸ display PIXELS, origin top-left; default = whole display
  scaling: "fit" | "fill"    // within rect, as § Scaling
  audio: bool
  group: string | null       // a Group id; null = free-running
  offset: number             // seconds; + = this video runs that much behind its group
}
Group { id: string, name: string }
```
- ▸ Pixels, not fractions of the screen, because exact pixels are the point of
  the app: a 1920 × 1080 video in a 1920 × 1080 rect is exactly 1×. The cost: a
  show is tied to the displays' resolutions, so setup warns when a rect runs
  off its display, and blocks a rect of zero size.
- A v1 file opens as v2: each panel becomes one full-display video in group
  "main" with offset 0. Saving writes v2. (v1 readers refuse v2 files, by the
  existing version rule.)

### Sync
- One player per video, all on the host clock, as now.
- Each group has its own start `h0_g` and pause state. A grouped video's
  expected item time is `(h − h0_g − offset) mod itemDuration`; the drift check
  holds it there, so an offset is held exactly, not just applied at start.
- ▸ Offsets are rounded to whole frames of that video when used.
- Free-running video: started with everything else, loops on its own, never
  checked or resynced. Pause-all pauses it too.
- Videos in different groups are not compared with each other at all.

### UI
- Setup: per display, a list of videos (Add / Remove / Up / Down for stacking),
  each with file, rect (x, y, w, h fields plus "Full display"), Fit/Fill,
  Audio, Group (picker incl. "Free-running"), Offset. ▸ A scaled preview of the
  display showing the rectangles; dragging in it is a later addition.
- Playback keys (▸ proposed):
  - Space: pause/resume everything. 1–9: pause/resume group 1–9 only.
  - Tab: select the next video (outlined for 2 s).
    ←/→: nudge the selected video's offset by one frame; Shift: 10 frames.
  - Esc: stop and return to setup.
- ▸ Nudged offsets are written back into the show, so setup shows them after
  Esc and Save keeps them.

### Targets
| # | Target | How it is checked |
|---|--------|-------------------|
| T7 | A video with offset *d* stays within 1 frame of its group's time minus *d* | `SyncMathTests` (arithmetic); probe run (behaviour) |
| T8 | A nudge takes effect within 0.5 s and is then held | lab or desk run, frame-numbered clips |
| T9 | Decode budget: the heaviest intended layout plays with no dropped frames on the Mac mini | lab run; ▸ Mat to name the heaviest layout (e.g. 3 displays × 4 HD videos) |

## API Contracts (PlayerCore library)

```
DisplayOrder.sorted([DisplayInfo]) -> [DisplayInfo]
Placement.rect(video: CGSize, in: CGRect, scaling: Scaling) -> CGRect
SyncMath.expected(host: Double, start: Double, duration: Double) -> Double
SyncMath.needsCorrection(actual:expected:duration:frame:) -> Bool   // wrap-aware
SyncMath.repeats(duration: Double, cover: Double) -> Int
ShowFile.decode(Data) throws -> Show ; ShowFile.encode(Show) -> Data
```

## Verification

```
swift build && swift test
```

Tests: `DisplayOrderTests`, `PlacementTests`, `SyncMathTests`, `ShowFileTests`.
Probes: `proofs/sync-probe.swift` (T1, T2, T4 on this machine).
Lab checklist (T4 on the Mac mini, T6): `docs/LAB-TEST.md`.
