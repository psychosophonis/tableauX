# Architecture specification

This is a NORMATIVE document: the implementation MUST match what is written
here. Update it BEFORE you change behaviour, then make the code follow.

## Purpose

tableauX: a macOS app that plays one video file per display, in sync, for a gallery or
lab screen array (BCM116: a Mac mini driving three 4K displays). It replaces
"one huge file stretched across a virtual display", which resamples the image
and produces artefacts.

Non-goals (v1): network sync between computers (planned: see "v3"
below), projection warping or edge blending, routing audio to particular
output devices, playlists (see "v4"), editing.

## Targets (measurable)

| # | Target | How it is checked |
|---|--------|-------------------|
| T1 | Panels start within 1 frame (33 ms at 30 fps) of each other | `proofs/sync-probe.swift`, timebase skew at start |
| T2 | Equal-length panels stay within 1 frame across 100+ loops | `proofs/sync-probe.swift`, max skew over the run |
| T3 | A panel more than `sync.tolerance` frames out is pulled back within `sync.grace` + 2 s (default 3 frames, 5 s; with 1 frame, 0 s this is v1's "1 frame, 2 s") | `SyncMathTests` (decision); lab run (behaviour) |
| T4 | 3 × 4K H.264 at 30 fps decodes with no dropped frames on Apple silicon | `proofs/sync-probe.swift --4k` here; lab run on the Mac mini |
| T5 | Each panel's pixels map to its display with no stretching (aspect kept) | `PlacementTests` |
| T6 | Display-to-display presentation offset is invisible on a sweep-line test | Lab only: `scripts/make-test-media.sh` clips on the array. Nothing on a one-display Mac can test this. |

## Model

### Display order
Displays are numbered 1..N left to right by their position in macOS's display
arrangement (frame origin x, then y for ties). Panel *n* plays on display *n*.

### Show file (`.tableaux`, JSON; Open also accepts the earlier `.msshow`)

```
Show {
  version: 2
  machines: [Machine]        // at least one; one per Mac the show plays on (v3)
  sync: Sync
  playOnLaunch: bool         // reopen this show and play when the app starts
}
Machine {
  name: string               // the Mac's computer name (System Settings › General › About)
  panels: [Panel]            // index = display number on that Mac - 1
}
Sync {
  tolerance: int             // frames, ≥ 1; default 3 (see § Sync › Drift check)
  grace: number              // seconds, ≥ 0; default 5
}
Panel {
  file: string | null        // absolute path; null = panel stays black
  audio: bool                // false = muted
  scaling: "fit" | "fill"    // fit: whole frame visible, letterboxed; fill: crop to cover
}
```

<!-- [claude] Version 2 replaced version 1 on 2026-10-21 (v3 Stage 1b). Mat:
no real shows exist yet, so version 1 files are refused, not converted. -->

Which machine this Mac plays: the one whose `name` is this Mac's computer
name; if none matches and the show has exactly one machine, that one (a show
made on another Mac still opens and plays); otherwise none, and setup says the
show has no part for this Mac and refuses Play. A new show has one machine,
named after this Mac.

Errors: a version other than 2 → refuse to open; no machines, tolerance < 1
or grace < 0 → refuse to open; missing file → panel shown as missing in setup,
playback refused until fixed or cleared.

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
  item timebase. A panel is OUT when |actual − expected| > `sync.tolerance`
  frames (of that panel's video). A panel that has been out at every check for
  `sync.grace` seconds, or has stalled (rate 0), is re-synced with
  `setRate(1, time: expected(h1), atHostTime: h1)` for `h1 = now + 0.5 s`. A
  check that finds it back in tolerance restarts the grace period. Grace exists
  because a seek is a visible jump, and a passing error (a network blip, v3)
  may not be worth one. `tolerance 1, grace 0` is the v1 rule exactly.
- Pause/resume pauses and restarts all panels together from a shared host time.
- Panels of different lengths loop independently on their own durations (they
  drift in phase on purpose). Setup warns when lengths differ by > 1 frame.

## UI

- Setup window: one row per detected display (number, name, resolution), each
  with Choose file / Clear, Audio on/off, Fit/Fill, and the file's resolution
  and duration. Buttons: Open, Save, Play. Checkbox: Play on launch. Fields:
  Sync tolerance (frames) and Grace (seconds).
- Playback: a borderless window covering each display above the menu bar,
  black background, cursor hidden, display sleep prevented.
  Keys: Space pause/resume, Esc stop and return to setup.
- Displays added, removed, moved or resized during playback: stop and return
  to setup. The trigger is a change in the sorted display list (id, position,
  pixel size), not every screen-parameter notification: hiding the Dock and
  menu bar for playback posts one too, and must not stop the show.

## v2 DRAFT: several videos per display, sync control

<!-- [claude] DEFERRED 2026-10-21 (Mat): playlists of students' multiscreen
works (v4) come first; several videos on one screen now looks like a stretch
feature with few uses. Kept for reference, not scheduled. -->

<!-- [claude] Drafted 2026-10-21 from Mat's choices: free rectangles; sync
groups, per-video offsets, free-running videos and live nudge; per-video audio.
NOT normative until Mat confirms it. The sections above stay the contract until
then; on confirmation this replaces Model › Show file, extends Sync and UI, and
the decisions marked ▸ are Claude's proposals. -->

### Model
```
Show {
  version: next              // [claude] was 2; v3's machines format took 2
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
- A file of the previous version opens in this one: each panel becomes one
  full-display video in group "main" with offset 0. Saving writes the new
  version. (Older readers refuse it, by the existing version rule.) [claude]
  Written before v3; machines (v3) must carry through to this format.

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

## v3: several machines, one show

<!-- [claude] Drafted 2026-10-21 from Mat's ask: extend the single-machine
sync to several Macs, server/client, as MultiScreener (2009) did well enough
over university Wi-Fi; then: one app with client/server modes, every machine
playing its own displays (e.g. 6 screens off two MacBook Pros). Claude's
proposals in it were confirmed by Mat on 2026-10-21, so this section is
normative. Builds on v1; v2 is still a draft and v3 does not depend on it. -->

### Idea
Today every panel on one Mac follows that Mac's host clock. Across Macs there
is no shared clock, so v3 builds one: a **conductor** (the server) owns the
reference clock and the show; each **player** (client) keeps an estimate of
`conductor time = host time + offset`, and does everything else exactly as
now, in conductor time. Start, pause and resume become "at conductor time T",
the same scheduled-start trick as v1, so one message reaches every machine
well before T and network delay doesn't affect the start.

### Clock
- NTP-style exchange over UDP: the player sends its time, the conductor
  replies with its own; from the round trip the player estimates the offset.
  Wi-Fi delay is noisy, but the noise only ever ADDS delay, so the samples
  with the SHORTEST round trip are the accurate ones: keep a window of recent
  samples and use the minimum-round-trip one (Cristian's algorithm with
  min-RTT filtering). Re-estimate continuously, several times a second.
- Two Macs' clocks also run at slightly different rates (parts per million:
  measured −12 ppm between Mat's MacBooks, a frame every ~46 min), so the
  offset is tracked over time, not measured once.
- Correction: players use the same drift check as one Mac (§ Sync), with the
  show's tolerance and grace, against conductor time. Mat (2026-10-21): the
  default tolerance of 3 frames is enough for most works, and frame accuracy
  is not needed all the time.
- Slew (deferred): a player a little off could play at a rate just off 1.0
  until it's back (MultiScreener's approach) instead of seeking. Built and
  tested in `SyncMath.correction` (under ¼ frame nothing; up to 1 frame slew
  over 2 s, capped at ±0.5%; over, seek), but not used by the app: with a
  tolerance of whole frames, a seek after the grace period is enough. Kept for
  a work that needs sub-frame smoothness.
- Sample rate matters: `proofs/clock-probe.swift` with simulated one-sided
  noise of 0–50 ms kept the filtered estimate within 1.1 ms at 20 exchanges/s
  but not at 2/s (11.7 ms, fail). Players exchange at 20/s (UDP packets of
  32 bytes: negligible load).
- Wire (Stage 2) [claude, filled in from the probe; Mat to confirm]: UDP port
  47800 on the conductor. A request and its reply are the same 32 bytes, four
  little-endian UInt64: sequence number, t1, t2, t3, each in nanoseconds of
  that Mac's host clock (`CLOCK_UPTIME_RAW`, the clock AVPlayer's host time
  follows). The player fills seq and t1; the conductor fills t2 on arrival and
  t3 on reply. This is the probe's packet, so the probe and the app can stand
  in for each other in tests. The conductor answers anyone who asks.
- What setup shows [claude]: Conductor, "answering clock requests" with this
  Mac's addresses and how many players asked in the last 10 s. Player, the
  conductor's address, replies per second, the offset, its steadiness (95%
  spread around the drift trend over the last 60 s, the measure of T11) and
  the drift; or "no replies" after 5 s (T10 failing). The player also writes
  this to the system log every 10 s, so a long run can be read back with
  `log show`.

API (PlayerCore, Stage 1, tested in `NetworkClockTests`):
```
ClockSample(t1:t2:t3:t4:).offset / .roundTrip
ClockEstimator(window: 2, trendWindow: 60).add(_:) / .filtered / .drift / .conductorTime(host:)
SyncMath.signedError(actual:expected:duration:) -> Double     // wrap-aware, signed
SyncMath.correction(error:frame:) -> .none | .slew(rate:) | .resync
ClockPacket(seq:t1:t2:t3:).bytes / ClockPacket(bytes:)          // Stage 2: the wire format
SteadinessMeter(window: 60).add(time:offset:) / .p95Spread      // Stage 2: T11's measure, live
ShowState(version:phase:start:pausedAt:index:).bytes / ShowState(bytes:) // Stage 3a; index v4 P3a (48 bytes)
StateFollower().accept(_:now:) -> Bool                          // Stage 3a: stale states ignored
SyncMath.scheduledStart(start:now:lead:) -> Double              // Stage 3a: start or join late
FolderScan.videos(_:) / .assign(folder:files:displays:)         // v4 P1: natural sort, overflow (T14)
FolderScan.fill(_:folder:files:displays:firstScreen:) -> (panels, leftOver)  // v4: new displays take unused files; append-only
FolderScan.screenNumber(_:) -> Int? ; .assign(…, firstScreen:)          // "_N" = tableau screen N (Mat, 2026-10-22)
SharedShow.firstScreen(_:of:) -> Int                                    // a Mac's display 1 as a tableau screen number
PlaylistMerge.merge(_:with:) / .length(of:in:)                  // v4 P1: works joined by folder name (T14)
Timeline(entries:settings:).position(at:anchor:start:)          // v4 P1: pure timeline (T15)
Timeline.screenPosition(elapsed:workLength:fileDuration:shorter:)
Timeline.segment(at:anchor:start:) -> Segment {position, begins, ends?} // v4 P2: edges, for one timer per change
Timeline.next(after:) / previous(before:) / playable(from:) -> Int?     // v4 P2: skip empty works; wrap only when looping
ItemLayout.pieces(fileDuration:workLength:repeat:shorter:cover:maxPieces:) -> [.clip | .empty(s)]  // v4 P2: never ends empty
ShowFile.decode: version 3; version 2 → one work (§ v4 › Model)          // v4 P2
Collect.plan(works:machine:resolve:takenFolders:) -> Plan {copies, works}  // v4: § Collecting and importing
Collect.uniqueName(_:taken:) / .folderName(_:)                          // case-insensitive clash → "name 2.ext"
FolderImport.works(root:rootFiles:subfolders:machine:displays:existing:) -> Result {works, skipped, leftOver}
FolderScan.folder(of:work:) -> String?                                  // a work's one folder, or nil if set by hand
LinkMessage .hello / .inventory / .report / .show (Codable)              // v4 P3b link messages
LinkFraming.frame(_:) / Reader().feed(_:) throws -> [LinkMessage]       // 4-byte length + JSON, max 16 MB
SharedShow.merge(_:with:conductor:) / .lengths(_:own:inventories:)      // conductor folds a player in; adopts a one-machine show
ShowFolder.pick(chosen:appFolder:home:listing:) -> String?              // v4 P4b: which folder is the media folder
ShowFolder.isShowFolder(files:subfolders:) / .shows(in:) / .showToOpen(last:folder:folderShows:)
```

### Show state (Stage 3a) [claude, 2026-10-21; Mat asked for 3a, details to confirm]
- The conductor sends STATE, not commands: `ShowState {version, phase:
  stopped | playing | paused, start, pausedAt}`, where `start` (v1's `h0`)
  and `pausedAt` are in SHOW TIME, i.e. the conductor's host clock. It is
  sent on every change (three times over 0.3 s) and again every second, to
  every player heard from in the last 10 s, from the clock socket.
- Why state: a player that misses packets, joins late or restarts converges
  on the next one. A lost "Play" command would be lost for good, and UDP
  does lose packets (0.2% on the uni Wi-Fi run).
- Wire: 40 bytes, five little-endian UInt64: a magic word (`TBXSTATE` in
  ASCII), version, phase (0 stopped, 1 playing, 2 paused), start ns,
  pausedAt ns. The clock packet stays 32 bytes, so the size tells them apart
  and the probe still works.
- [claude] **v4 P3a:** 48 bytes, a sixth word `index`: the timeline's anchor
  work, so `start` reads "work `index` starts at `start`" (§ v4 › Timing).
  A 40-byte state from an older build is refused: every Mac in a show must
  run the same build. A player follows a new anchor while playing (→ / ←
  on the conductor) by going black and loading that work for after the gap;
  a new start after a pause is a resume, shifted as before. The conductor
  can't skip while paused, so the two can't be confused.
- `version` is the conductor's host time of the change (it only grows). A
  player ignores a state older than the last one it accepted (UDP can
  reorder), unless it has accepted nothing for 5 s, which means the conductor
  restarted.
- A player RECONCILES: it compares the latest state with what it is doing
  and changes only what differs, so receiving the same state again does
  nothing. Playing → load its part and start in show time; paused → pause;
  stopped → stop and return to setup. A player that joins during a pause
  waits for the resume.
- Starting late: if `start` has already passed when a player is ready (slow
  file load, late join), it starts 0.5 s later at the position the show has
  reached, so it joins in sync rather than from the beginning.
- Keys on a player: Esc stops that player and leaves it stopped until the
  conductor's state next changes; Space does nothing (the conductor decides).
- Playback works in show time everywhere: on a conductor or standalone Mac
  show time is host time; on a player it is the clock estimate. The drift
  check (§ Sync) compares panels against show time, with the show's
  tolerance and grace.
- TEMPORARY (3a): each player plays its own part from a show file saved on
  that Mac (§ Show file › which machine). Sending each player its part from
  the conductor's show (§ Show and media) is 3b.

### One app, three modes (Mat's decision, 2026-10-21)
- The same app runs everywhere, in one of three modes, chosen in setup:
  - **Standalone**: as v1 (and v2); no network.
  - **Conductor** (server): holds the show and the reference clock, AND plays
    on all of its own displays.
  - **Player** (client): joins a conductor and plays on all of its own
    displays.
- Every machine, in any mode, drives all of its displays exactly as a single
  machine does now. A show spans machines. Example: two MacBook Pros with
  three screens each make a six-screen work, one of them in Conductor mode.
- How many displays a machine can drive is the hardware's limit, not the
  app's: it depends on the chip (on recent MacBook Pros, Pro chips drive fewer
  external displays than Max chips). Check Apple's specs for the machines used.
- [claude] The mode belongs to the MACHINE, not the show: it is stored on each
  Mac (with a Player's conductor address) and kept across launches. The same
  show file can then be opened on a conductor or played standalone. Until
  Stage 3, a Conductor or Player only runs the clock; playback still follows
  the local clock.
- [claude] macOS asks before an app may use the local network (Local Network
  privacy), and the conductor may meet the firewall's prompt for incoming
  connections. Both must be allowed. The bundle declares
  `NSLocalNetworkUsageDescription` so the prompt says why.

### Show and media
- The show file lives on the conductor. It names displays as (machine name,
  display number), numbered per machine left to right as now; the conductor
  sends each player its part.
- Setup in Conductor mode lists every connected machine's displays, grouped by
  machine, so the whole work is set up from one screen. Player mode shows the
  machine's name and "waiting for conductor".
- Each machine plays files from its own disk; video is never streamed (4K
  over Wi-Fi isn't reliable). Before Play, the conductor checks every
  machine has every file it needs (name, size, and a hash) and blocks Play
  otherwise, as missing files do now.
- Discovery by Bonjour on the local network, with a typed-in address as
  fallback: university Wi-Fi often blocks Bonjour, and some networks stop
  devices reaching each other at all ("client isolation").
- If a player loses the conductor, it keeps playing on its last clock
  estimate and rejoins when it can; the show doesn't stop.

### Targets
| # | Target | How it is checked |
|---|--------|-------------------|
| T10 | Two Macs can reach each other over the target network | `ping` / probe handshake on the real Wi-Fi: first, because nothing else matters if this fails |
| T11 | Player's clock-offset estimate steady to within 5 ms (95% of samples) | probe on two Macs on the target network. This measures steadiness only: with no third clock to compare against, a steady but WRONG estimate would pass. Accuracy is T12's job. |
| T12 | Panels on different Macs within `sync.tolerance` (Mat, 2026-10-21: default 3 frames, 100 ms at 30 fps); also run once at 1 frame to learn what a tight work can expect | `make-test-media.sh` clips across two Macs, photographed (as T6) |
| T13 | During and after a 30 s network dropout, panels on different Macs are back within `sync.tolerance` within `sync.grace` + 2 s (default 5 s + 2 s); brief errors in between are acceptable | sweep-line test with Wi-Fi switched off and on mid-run |

### Riskiest assumption, and its cheapest test
That the target network gives clock estimates good to a few milliseconds.
A simulation can't answer this, because the answer depends on that network's
real delays. The cheapest real test is a probe on two MacBooks on the
university Wi-Fi: first check they can reach each other (T10), then log the
offset estimate over 10 minutes (T11). Only if that holds is the rest worth
building.

Result (2026-10-21, two MacBooks on the university Wi-Fi, ~9 min): T10 pass
(0.2% packets lost); T11 pass, filtered estimate steady to 0.28 ms (raw
samples 15.2 ms); clock drift −12 ppm. Replayed through `ClockEstimator` in
`ClockReplayTests`: 0.27 ms, and 0.40 ms worst across a simulated 300 s
dropout. Steadiness is shown; accuracy (T12) is not yet.

## v4: playlists of works (release 0.3)

<!-- [claude] Drafted 2026-10-21 from Mat: classes of students submit
multiscreen works to be played in succession, some with audio, some without;
a single piece must still be able to loop; "mature playlisting and show
coordination and management", ahead of v2. Mat's decisions so far are marked
(Mat). Claude's proposals were confirmed by Mat on 2026-10-21 ("yes"),
including the 1–5 example below, so this section is normative. Playlists are
release 0.3 (Mat: "move to three"). Builds on v3. -->

### Terms
- A **work** is what a show is in v1–v3: one file per screen, across all the
  Macs, with audio per screen. One student's piece.
- A **playlist** is an ordered list of works. The show file holds one
  playlist. A single looping piece is a playlist of one work set to loop.
- **Screens are numbered across the Macs**: the first Mac's displays 1..n,
  then the next Mac's, in the order the show lists the Macs. A six-file work
  spans two three-screen Macs.

### Getting works in (Mat)
- **No copying between Macs (Mat):** each Mac holds only the files for its
  own screens, in its own **media folder** (the class folder; a setting
  per Mac, like the mode).
- **Folder scan (default):** each Mac scans its own media folder. Each
  subfolder is one work, in name order. Inside it, that Mac's video files are
  sorted by name, numbers compared as numbers (2 before 10), and assigned to
  that Mac's displays 1, 2, 3, … More files than the Mac has displays: the
  first ones are used and the work shows a warning listing those left out.
- **Files can name their screen: "_N" (Mat, 2026-10-22).** A video whose
  name ends `_<digits>` before the extension (`Comp 4_5.mov`) goes on
  screen N, **counted across the tableau** in the show's machine order (a
  6-screen work on two 3-display Macs: `_1`–`_3` on the first, `_4`–`_6`
  on the second). [claude] Details: a number for a screen not on this Mac,
  or a second file with the same number, is left over (warned); unnumbered
  files fill the displays still empty, in name order, so a folder with no
  numbers works as before; a missing number leaves that screen black.
  Applies to Scan, the conductor's merge, new displays, and Import.
- **The folder name joins a work across Macs (Mat):** `Smith` with 2 files on
  the conductor and 3 on a player is one work of 5 screens: conductor
  displays 1–2, player displays 1–3. A Mac with no folder of that name shows
  black for that work. (A file can only play on the Mac it is stored on, so
  each Mac's files always land on that Mac's displays.)
- **Audio defaults to off** on every screen (Mat), switchable per screen.
- **Manual (Mat):** any screen of any work can be set by hand. The
  conductor's setup lists every Mac's media folder contents, so a player's
  screen is chosen from the files that player reported, without visiting it.
- Works can be reordered and skipped; a rescan adds new folders without
  disturbing works already set up.
- **New displays take the left-over files (Mat, 2026-10-21):** when a Mac
  has more displays than a work has screens set (a display plugged in, or
  a show opened on a Mac with more), the new displays take the unused
  videos of that work's folder, in name order. [claude] Screens already
  set, black ones included, are untouched; displays still without a file
  stay unset, so a file added later fills them at the next scan. A work
  whose files on this Mac come from several folders was set by hand and is
  left alone.

### Zero setup (Mat, 2026-10-22)
Aim (Mat): "minimise any step that requires going back to a client… send a
copy of tableauX and a folder to the client and have it, as much as
possible, just work."
- **The folder is called `tableauX` (Mat).** The media folder, first match:
  a folder chosen with Choose… (saved; a deliberate choice wins); **the
  folder the app is in (Mat)**, if it holds a show file or a folder of
  videos; then `~/tableauX`, `~/Movies/tableauX`, `~/Desktop/tableauX`
  [claude: home and Movies first, as macOS asks before an app reads the
  Desktop]. A folder found by looking is looked for again at each launch.
- [claude] App Translocation: a quarantined app opened where it was
  unzipped runs from a hidden copy; the original path comes from
  Security.framework's SecTranslocateCreateOriginalPathForURL, looked up at
  run time. If that fails, the app's folder is skipped.
- **The folder decides the role (Mat):** a show file in it = Conductor;
  works but no show = Player; no folder = Standalone. A role chosen in
  setup overrides it from then on; a role saved by an earlier build counts
  as chosen.
- [claude] The show opened at launch: the last one if it is in the media
  folder, else the newest show file there. Failing both, the last show from
  elsewhere only if the folder was chosen by hand (or none was found);
  otherwise a fresh show. (0.3.6 reopened the last show against a folder it
  had merely found, pairing it with the wrong files: Mat's run, 0.3.7 fix.)
  A conductor or standalone show with no works scans the folder.
- [claude] **Discovery:** the conductor announces `_tableaux._tcp` (Bonjour)
  under its computer name. A player with no typed address looks for it,
  joins if exactly one answers (several: lists them and asks for an
  address), and points its clock at that conductor's IPv4 address. A typed
  address wins. Info.plist declares the service (NSBonjourServices).
- Left for a person on each Mac, once: Gatekeeper's Open Anyway (removed
  only by notarisation, Mat's call) and the Local Network Allow (always
  asked; discovery waits for it).
- **Untested assumptions, with their cheapest tests:** Bonjour on the
  university network (`dns-sd -R test _tableaux._tcp local 47801` on one
  Mac, `dns-sd -B _tableaux._tcp` on another); translocation resolved on a
  fresh Mac (download a zip of the folder, unzip, open, Open Anyway).

### Collecting and importing (Mat, 2026-10-21)
- **Files stay where they are (Mat):** in the media folder, or linked by
  full path. Nothing is copied unless a person asks to collect.
- **Import a folder (Mat: link in place):** a folder chosen from anywhere
  adds works without copying; panels hold full paths to the files where
  they are. [claude] The folder's own videos are one work named after it;
  each subfolder with videos is another, in name order; screens assigned by
  the folder-scan rule. A name the playlist already has is skipped and
  reported, as a rescan never disturbs a work.
- **Collect, per show and per work, for archiving (Mat):** copies the files
  into one folder; the originals are untouched. **Each Mac collects its own
  files (Mat)**, so nothing is copied between Macs; for a show across
  Macs, collect on each and put the folders together.
- [claude] **An archive has the layout of a media folder:** one subfolder
  per work, named after it, holding that Mac's files for it. Collect show
  adds `<show>.tableaux` with this Mac's paths rewritten relative to the
  archive (other Macs' paths unchanged); it plays with the media folder
  pointed at the archive. Collect work makes just the work's folder, which
  Import reads back as the work.
- [claude] Details: a file on two screens of one work is copied once; a
  name clash (ignoring case, as a Mac's disk does) becomes "name 2.ext"; a
  work name with "/" or ":" gets "-" in its folder name, and a folder
  already at the destination gets " 2". Missing files are skipped and
  listed; free space is checked before copying; Play is blocked while a
  collect runs.
- [claude] **Screens round-trip (since "_N", 2026-10-22):** a collected
  work keeps its file names when a scan of them would restore its screens;
  otherwise each file is named for its screen ("intro.mov" on screen 2 →
  "intro_2.mov"; a name already ending in its own number is kept), so
  importing the archive restores an order set by hand and black screens
  between files. (Before this, they survived only in the show file.)

### Playing (Mat: auto-advance with manual override; black gap)
- Each work has a **repeat**: once, N times, or until moved on (a single
  piece on a loop). Default: once.
- When a work's repeats are done, all screens go **black together for the
  gap** (default 3 s, set per playlist), the next work loads during it, and
  starts in sync. The playlist loops to the first work after the last.
- **Manual override** on the conductor: Next, Previous, jump to a chosen work,
  plus v1's Space (pause) and Esc (stop). Keys: → next, ← previous; jump
  from setup.
- **Screens of different lengths (Mat: an option):** per work, "shorter
  screens go black when done" (default) or "shorter screens loop until the
  longest ends". The work lasts as long as its longest file either way.

### Timing
- The playlist's timeline is a PURE FUNCTION of the playlist, the files'
  durations and a start time: from those, any Mac can say which work is on and
  how far in, at any show time. So automatic advances need no message: every
  Mac changes work at the same show time, the way v3 Macs already share a
  start. Only a person's action (Next, jump, pause) changes the state, which
  is then sent as in v3 › Show state, extended with the work index and that
  work's start.
- Durations are measured on the conductor and sent with the playlist, so
  every Mac uses the same numbers even if a file's metadata reads slightly
  differently on another Mac.
- A "until moved on" work has no end: the timeline stops there until Next.

### Media on several Macs
- Video is never streamed (v3), and nothing is copied between Macs (Mat).
- **Inventory:** each player sends the conductor what its scan found (per
  folder: file names, sizes, durations, frame rates, audio or not). The
  conductor merges every Mac's inventory into one playlist and sends it back
  to the players with each work's length, so every Mac computes the same
  timeline.
- These messages go over a **TCP connection** from each player to the
  conductor, beside the UDP clock. They are too big for one UDP packet and
  must not be lost; the clock stays on UDP, where a late packet is worse than
  a lost one.
- Before Play the conductor checks that every Mac still has what it reported
  (name, size and modification date; no hashing of whole video files),
  and lists anything missing, per Mac.
- A Mac that joins or rescans later sends a new inventory; the conductor
  updates the playlist and resends it.
- [claude] **As built (P3b, 2026-10-22), for Mat to confirm:**
  - TCP port 47801 on the conductor (the clock is UDP 47800). Each message
    is a 4-byte big-endian length then JSON; over 16 MB is refused and the
    connection closed; a frame that doesn't decode is skipped.
  - Messages: player → `hello {machine, build}`, `inventory`, `report
    {machine, blocking}`; conductor → `show {show, lengths}`.
  - A player reconnects every 2 s while the link is down, and on each
    connection sends everything again. It rescans every 5 s and resends
    its inventory if a name, size or date changed: that is the "still has
    what it reported" check, done by the player rather than on request.
  - The conductor adds a player's machine the first time it hears from it,
    at the end of the list (the screen numbering), and saves it with the
    show. Its folders fold in by PlaylistMerge, then new displays take
    left-over files.
  - A player plays the conductor's playlist, not its own show file; its
    setup shows it read-only. Its Scan sends a fresh inventory.
  - A one-machine show saved under another Mac's name is ADOPTED by the
    conductor when the first player joins (its lone machine and screens
    are renamed to the conductor), unless that machine is the joining
    player's. Without this the conductor lost its own part the moment a
    player joined (found in the P4a loopback run).
  - **P4a, Manual (Mat, 2026-10-22: "work entirely on the conductor once
    the clients have reported"):** the conductor's setup has "Screens on:
    This Mac | each other Mac". Another Mac's displays each get a file menu
    of everything it reported (any folder), audio and Fit/Fill; edits reach
    it with the next playlist. Each Mac's last inventory is kept when it
    disconnects, so its files stay choosable and the work lengths don't
    change under the others.
  - **For Mat to decide:** a work's name is also its folder name, which
    joins it across Macs and across rescans. Renaming a work on the
    conductor breaks that: the next inventory with the old folder name adds
    it again as a new work. Fixing it needs a display name separate from
    the folder name in the show file.
  - Play on the conductor is blocked by a player's missing or unreadable
    files, by a player that hasn't checked its files yet, and by a player
    on another build. A Mac in the show that isn't connected is a warning:
    its screens stay black.

### Model
```
Show {                                  // the conductor's file
  version: 3
  machines: [{ name, displays: int }]   // order = screen numbering in setup
  works: [Work]                         // playlist order
  playlist: { gap: seconds, loop: bool }
  sync: Sync                            // as v3
  playOnLaunch: bool
}
Work {
  name: string                          // = the folder name on every Mac
  screens: { machineName: [Panel] }     // per Mac, index = that Mac's display - 1
  repeat: int ≥ 1 | "untilNext"        // 1 = once; [claude] stored readably: 1, 3, "untilNext"
  shorter: "black" | "loop"
}
Panel { file: string | null, audio: bool, scaling }   // file relative to that Mac's media folder
```
A version 2 show opens as a one-work playlist.

<!-- [claude] 2026-10-21, P2. Details the spec left open, decided in code;
for Mat to confirm or change. -->
- **[claude] Departure, flagged:** a panel's file may also be an ABSOLUTE
  path (starting with `/`). A version 2 show holds absolute paths, and a
  file chosen by hand from outside the media folder needs one. Files chosen
  inside the media folder are stored relative.
- **[claude] Version 2 conversion:** one work named "Show", repeat
  `untilNext`, shorter `loop`: exactly how v1–v3 played (until stopped, each
  panel looping on its own length). Machines get `displays` = their panel
  count.
- **[claude] One item per screen per work:** each screen's player item is
  laid out so its time is the time into the work (`ItemLayout`): `loop` =
  the file end to end; `black` = the file, then empty time up to the work's
  length, per play. An empty range at the END of an item is dropped by
  AVFoundation (`proofs/empty-range-probe.swift`), so items end on a clip and
  the app hides a screen whose item ends before its work.
- **[claude] → / ←:** black at once, the chosen work after the gap. In a gap,
  "current" is the work about to start.
- **[claude] P2 limit (lifted by P3b, 0.3.4):** until P3 sends one set of lengths to every Mac,
  each Mac times works by its own files, so a playlist across Macs keeps
  in step only if every Mac has every work with files of the same lengths.
  Setup warns of this (0.3.2; 0.3.0–0.3.1 blocked it, which stopped Mat
  playing identical files on three Macs). → / ← work across Macs from
  P3a (0.3.3), carried by the state's work index.

### Targets
| # | Target | How it is checked |
|---|--------|-------------------|
| T14 | Folder scan assigns files to screens as specified (sort, overflow, black), and inventories from several Macs merge into works by folder name | PlayerCore tests |
| T15 | The timeline gives the same work and position on every Mac for any show time | PlayerCore tests (pure function) |
| T16 | Every screen on every Mac starts each work within `sync.tolerance`, with no screen late out of the gap | two-Mac run, sweep-line works in a playlist, photographed at a change |
| T17 | Next / Previous / jump take effect on every Mac within gap + 1 s | two-Mac run |
| T18 | A 20-work playlist runs unattended for 8 h: no stop, no growing memory, no work starting late | soak run on the Mac mini, log of each change |

### Riskiest assumption, and its cheapest test
That the Mac mini can tear down one work's three 4K players and build the
next one's, over and over, inside the gap, for hours, without load times
creeping up or memory growing. v1 built players once per show; nothing yet
shows that doing it every few minutes is clean. The cheapest test is a probe
on one Mac (then the Mac mini): cycle three 4K items every 10 s for an hour,
logging each load time and the process's memory. It needs no playlist code.

## API Contracts (PlayerCore library)

```
DisplayOrder.sorted([DisplayInfo]) -> [DisplayInfo]
Placement.rect(video: CGSize, in: CGRect, scaling: Scaling) -> CGRect
SyncMath.expected(host: Double, start: Double, duration: Double) -> Double
SyncMath.needsCorrection(actual:expected:duration:frame:tolerance:) -> Bool   // wrap-aware; tolerance in frames
SyncMath.repeats(duration: Double, cover: Double) -> Int
DriftGate(grace:).check(out: Bool, now: Double) -> Bool                 // true = resync now
ShowFile.decode(Data) throws -> Show ; ShowFile.encode(Show) -> Data
Show.machineIndex(named: String) -> Int?                                // § Show file › which machine
```
(Playlist API, v4: see the API list under § v3 › Clock, with the other later stages.)

## Verification

```
swift build && swift test
```

Tests: `DisplayOrderTests`, `PlacementTests`, `SyncMathTests`, `ShowFileTests`,
`NetworkClockTests`, `ClockReplayTests` (the real Wi-Fi recording),
`FolderScanTests`, `PlaylistMergeTests`, `TimelineTests`, `ItemLayoutTests`,
`CollectTests`, `FolderImportTests`, `FillTests`, `LinkFramingTests`,
`SharedShowTests`, `ShowFolderTests`, `ScreenNumberTests` (v4).
Probes: also `proofs/clock-probe.swift` (T10, T11), `proofs/work-switch-probe.swift` (v4 riskiest assumption).
Probes: `proofs/sync-probe.swift` (T1, T2, T4 on this machine).
Lab checklist (T4 on the Mac mini, T6): `docs/LAB-TEST.md`.
