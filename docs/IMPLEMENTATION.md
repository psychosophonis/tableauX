# Implementation status

A human-maintained scratchpad. The real source of truth is the test suite;
this file is just a quick map of where things stand.

## Handoff (2026-10-21, from the BCM116 course-site session)

Started in the ImmersiveInter (BCM116 site) session; moved here so the site
work can continue separately. Read `docs/architecture.md` first: it is the spec,
with targets T1–T6.

**Why this exists.** The BCM116 lab has a Mac mini driving three 4K displays
directly. The current playback is a hacky app that shows a 3 × 4K work at 16:9
and then pushes it to 16:3, with visible artefacts (non-uniform resampling).
VLC was abandoned because of how macOS handles the displays. Mat wants: sync in
code, each screen at its own native resolution, simple scaling from 1080p,
audio on/off per panel. Nothing free and current does this (checked:
MultiScreener is from 2009, Intel/PPC, and syncs by nudging playback speed;
VPT 8 needs TripleHead2Go hardware for multiple outputs; QLab's free mode is
reportedly limited to one video output).

Editor limits make the single-wide-file route fragile (found 2026-10-21):
Premiere's maximum sequence is 10,240 × 8,192 per Adobe's docs, though Mat reports
making 11520 × 2160 there; free DaVinci Resolve caps timelines and exports at
3840 × 2160. Per-screen HD files avoid all of this, which is a core reason for
the app.

Mat chose: own repo here, dev-protocol with pedagogical mode on, and a **full
first version** (not a sync spike first).

### Done
- `docs/architecture.md`: the spec (model, sync design, UI, targets).
- `scripts/make-test-media.sh`: sweep-line + frame-number test clips, one per
  panel; the line crosses all panels as one wide screen. Checked visually.
- `proofs/sync-probe.swift`: the falsification probe (build:
  `swiftc -O proofs/sync-probe.swift -o .build/sync-probe`).
- `Sources/PlayerCore/*` + `Tests/PlayerCoreTests/PlayerCoreTests.swift`:
  compile; 15/15 tests pass.
- `Sources/tableauX/AppModel.swift`, `Playback.swift`: compile, and
  playback has run once (2026-10-21, dev MacBook + LG 4K, Mat's two 30 s
  3840 × 2160 ProRes 422 10-bit files): Play → start scheduled in 0.69 s,
  8 s of playback, no resyncs. Short run; not a T2/T4 result.
  Two start bugs found and fixed on the way, both silent:
  1. App quit on Play: hiding the setup window before the panel windows
     existed counted as "last window closed" (app quits then). Now Playback
     hands over: panel windows up, then setup hidden; on stop, setup shown,
     then panel windows closed.
  2. Show stopped itself: hiding Dock/menu bar posts a screen-parameters
     notification, which AppModel took as "displays changed". Now it stops
     only if the sorted display list really differs (spec § UI updated).
  Also fixed: review bug 1 (Playback tracks every window it builds, so a stop
  mid-load closes them all). `start()` logs each stage with elapsed time.
- [claude, 2026-10-21] `App.swift` (SwiftUI `@main`, one `Window` titled
  `AppModel.setupTitle`, activation policy `.regular` so the bare executable
  can take keyboard focus) and `SetupView.swift` (§ UI). Play on launch moved
  from `AppModel.init` to `launched()`, called once when the setup window
  appears, so playback windows, not the setup window, get Space/Esc.
  Checked by launching: setup window appears, app is frontmost, both displays
  on the dev machine listed with real pixel sizes, Play disabled with no file.
- Verify command `swift build && swift test` (in `CLAUDE.md`; the pre-commit
  hook reads it from there); `docs/SPECS.md` maps `Sources/**`, `Tests/**`,
  `Package.swift`, `scripts/**`. Verify passes.

### Probe results so far (M3 Pro MacBook Pro, one display)
- Control (`--control`, last panel at rate 1.001, 60 s): FAILED as it should,
  60.01 ms skew = 0.1 % of 60 s. The probe can see drift.
- 1080p × 3, 10 s: skew 0.00 ms, 0 dropped.
- 1080p × 3, 300 s (300 loops): skew 0.00 ms (T1, T2 pass), but **12 dropped
  frames on every panel, identical counts**. Unresolved. Identical counts point
  to something shared (probably the probe's 2 ms polling loop on the main actor
  stalling, possibly from other work running on the machine at the time) rather
  than decode, but that's a guess. Next: log the frame index and host time of
  each drop; check whether they line up across panels and with loop boundaries;
  rerun with the machine idle. If they're polling misses, move frame pulling to
  a dedicated thread or a CVDisplayLink.
- 4K × 3, 120 s: skew 0.00 ms; "2 dropped" per panel, yet every panel received
  3600/3600 frames. Real drops would leave a panel short, so the counter is
  likely misreading duplicate or late frames as gaps.
- 9 × 4K "overload", 60 s: skew 0.00 ms, **0 dropped**. It was meant to break
  decoding and didn't, because the test clips are mostly black and compress to
  almost nothing.
- **Verdict:** sync (T1, T2) survived every run, and the control shows the probe
  can see drift. Decode (T4) is **untested**: the drop counter isn't trustworthy
  (fix it: log each drop's index and host time, and count frames received against
  expected rather than index gaps), and the clips need real texture. Add noise or
  real footage to `make-test-media.sh` (e.g. a `noise=alls=40:allf=t` filter) so
  the overload run can actually fail.

### Build plan (Mat, 2026-10-21: network before multi-video)
Risk order: the stages that could kill the idea come first.

| Stage | Work | Done when | Status |
|---|---|---|---|
| 0a | `proofs/clock-probe.swift` on Mat's two MacBooks on uni Wi-Fi | T10 (reachable), T11 (steady ≤ 5 ms). Gates 2–4. | **done 2026-10-21: T10 pass, T11 pass (0.28 ms)**; see below |
| 0c | Lab run on the Mac mini (docs/LAB-TEST.md) | T4, T6 | **done 2026-10-21: full checklist run by Mat, T4 and T6 pass** |
| 1 | Clock maths in PlayerCore: `ClockEstimator`, `SyncMath.correction` | unit tests; replay of 0a's real CSV | **done** (10 tests + 3 replay tests, mutation-checked) |
| 1b | Show format with machines (one video per display) | ShowFile tests | **done 2026-10-21**: show v2 (`machines`, `sync`), v1 refused; tolerance + grace in the drift check; see below |
| 2 | Clock service over UDP in the app (the probe as a component) | two Macs hold a steady estimate in the app | built, loopback checks pass; **two-Mac run pending (Mat)** |
| 3a | Players follow the conductor's Play / Space / Esc (show state); each plays its own local part | conductor's Play starts both Macs together | **built 2026-10-21, build 0.1.3; two-Mac run pending (Mat)** |
| 3b | Conductor sends each player its part; conductor setup lists all machines | a 6-screen show set up from one MacBook | |
| 3a ✓ | Two-MacBook run on 0.1.3 | — | **Mat 2026-10-21: "working beautifully"** (by eye; T12 photo and log not yet recorded) |
| P0 | Probe: cycle 3 × 4K items every 10 s for 1 h (load time, memory) | v4 riskiest assumption | survived 1 h on this Mac (load p95 0.19 s, no creep, memory +8.2 MB/h); control fails as designed; Mac mini run with the tech |
| P1 | PlayerCore: v4 model, folder scan + inventory merge (T14), timeline (T15) | tests | **done** (19 tests, mutation-checked); show file v3 moves with the app in P2 |
| P2 | One-Mac playlist playback: gap, auto-advance, →/← | a class playlist plays on one Mac | **built 2026-10-21**: 3-work test playlist ran a full cycle on this Mac's 2 displays, checked by screenshots; →/← and Esc not yet pressed (need a person); see below |
| P2b | Collect show / work for archiving; Import folder (linked in place) | Mat's request, 2026-10-21 | **built 2026-10-21** `[claude]`: `Collect.swift` in PlayerCore (12 tests incl. a collect → import round trip); setup buttons. Not yet run through the dialogs (they need a person) |
| P2c | New displays take a work's left-over files (Mat's 0.3.0 report) | display added after a scan gets the next file | **built 2026-10-21** `[claude]`: `FolderScan.fill` (4 tests), run on display change, open and Scan |
| P3 | Network: TCP channel; inventories → merged playlist → players; state with work index; file check | T16, T17 | |
| P4 | Setup: playlist editor, folder import, per-work settings | a class set up in minutes | |
| P5 | Two-Mac playlist run; 8 h soak on the Mac mini (T18) | release 0.3 | |
| 4 | Two-MacBook sweep test (T12), dropout test (T13) | within 1 frame; no visible desync | release 0.2 |
| later | v2 multi-video | needs the six v2 ▸ decisions, decode-load probe (T9) | **deferred** (Mat, 2026-10-21: playlists first) |

Stage 1 notes (2026-10-21): `ClockEstimator` keeps the fastest exchange of
the last 2 s (min-RTT) and a drift rate fitted over 60 s, so it extrapolates
through a dropout. Mutations checked: trusting the latest sample instead of
the fastest fails 2 tests; ignoring drift fails the dropout test. Nothing in
the app uses this yet.

Stage 0a result (2026-10-21, Mat's two MacBooks, university Wi-Fi, ~9 min at
20/s; recording in `Tests/clock-probe-1792559249.csv`):
- T10 pass: 10,618 of 10,638 replies (0.2% lost).
- Round trip: median 6.2 ms, 95% 41.4 ms, max 1,350 ms (stalls do happen).
- T11 pass: raw offsets 95% within 15.2 ms of the trend; min-RTT filtered,
  0.28 ms. Clocks drift −12 ppm (a 33 ms frame every ~46 min).
- Still unknown: whether the estimate is RIGHT (one-sided bias). T12 tests it.

Stage 1b (2026-10-21): show file version 2 = `machines: [{name, panels}]`
+ `sync: {tolerance (frames), grace (s)}`, default 3 / 5 s (Mat). This Mac
plays the machine with its computer name, or the only machine. The drift
check now resyncs a panel only after it has been out of tolerance for the
grace period (`DriftGate`, a debounce); stalled panels at once. Setup has
tolerance and grace steppers. 41 tests; mutations checked (no reset when a
panel comes back, no reset after a resync, no one-machine fallback: each
fails a test). App launches; setup window and playback with the new
settings not yet checked by eye. Single-machine default loosened from v1's
1 frame / 2 s to 3 frames / 5 s; set 1 / 0 for the old behaviour.

v4 P0/P1 (2026-10-21, `[claude]`):
- `proofs/work-switch-probe.swift`: builds and tears down a work's players
  every 10 s. Control (`--leak`) fails as it must (+195 MB/h vs a 25 MB/h
  limit). Short runs with a 60 Mbit/s 4K clip ×3: load 0.16 s, ~30 MB,
  full frame rate.
- 1 h run on this Mac (M3 Pro, 360 swaps, 60 Mbit/s clip ×3): SURVIVED.
  Load median 0.17 s, p95 0.19 s, max 0.28 s (gap 3 s); no creep (×1.00);
  861–879 frames per 10 s cycle throughout. Memory 28 → 39 MB, slope
  +8.2 MB/h: under the 25 MB/h limit but not flat, and an hour can't tell a
  slow plateau from a slow leak. At that rate 8 h adds ~65 MB, harmless,
  but T18 (8 h on the Mac mini) is the run that decides it. Still to do:
  the probe on the Mac mini with the tech.
- FINDING, for submission guidelines: `testmedia/noise-3840x2160-10s.mp4` is
  679 Mbit/s H.264; two decode at full rate on the M3 Pro, three drop to
  ~3 fps each. Real 4K H.264 is far below that, but a student export at an
  extreme bitrate could do this; the Mac mini's limit is unknown.
- `Playlist.swift`: folder scan, inventory merge, timeline (19 tests). A
  mutant that dropped the gaps from the loop cycle first SURVIVED: the test
  compared against one day, which happens to land in the same place either
  way. Replaced with an explicit expected value; the mutant now fails.

v4 P2 (2026-10-21, `[claude]`): show file version 3 (works, playlist; a
version 2 show opens as one work that loops until stopped); media folder +
Scan; works list in setup; Playback per work on one timer per change.
- PROBE `proofs/empty-range-probe.swift` FALSIFIED the first layout for
  "shorter: black" ([clip][empty] × plays): AVFoundation drops an empty
  range at the END of a composition (6.00 s laid out, 4.00 s built), so the
  item would stop and hold its last frame. Empty ranges between clips
  behaved (no frames, time ran on, a start inside one worked; also on a
  composition with audio). Revised: items end on a clip; the app hides a
  screen whose item ends early (end notification 3 ms after the end).
  Survived on the 1 s test clip and the 10 s 4K clip.
- 87 tests. Mutants caught: a trailing empty range (3 tests), skipping one
  cycle too many (4), version 2 converted to "play once" (1).
- App run, this Mac, 2 displays, test playlist Red (6 s + a 3 s file,
  shorter black) / Green (4 s ×2) / Blue (one file), gap 2 s, loop: every
  work "starts on time", loads 0.04–0.18 s, cycle exactly 25 s, back to Red
  and on; no resyncs. Screenshots once a second matched the plan on both
  displays (the 3 s file's display black from 3 s; black in the gaps; Blue's
  second display black).
- Found and fixed in that run: Play on launch was refused ("still reading
  the file") because lengths now time the playlist; it now waits for them.
- Version 2 show (Stage 3a's) played standalone through its 10 s loop
  point, no resync.
- NOT checked: → / ← and Esc (synthetic keys need Accessibility permission;
  a person has to press them), audio, Scan in the UI (the merge itself is
  tested), conductor/player on loopback (Mat's 0.1.3 was running and holds
  the clock port; not closed). P2 limits network modes to a one-work
  looping show until P3.

Stage 3a (2026-10-21, `[claude]`), after Mat found on 0.1.2 that the player
didn't start with the conductor (Stage 2 only ran the clock): the conductor
publishes `ShowState` (on change ×3, then every 1 s); players reconcile.
Playback works in show time through `ShowClock`. 56 tests. Checks on one Mac
(two copies of the app on loopback, tolerance 1 frame, grace 0, 4K noise clip):
- player started on the conductor's own start ("start scheduled on the
  conductor's start"); ~18 s, no resyncs;
- player launched 5 s late joined 5.24 s into the show, no resyncs.
Not checked: pause/resume and Esc reaching the player (needs keys pressed on
the conductor), and anything across two Macs: that is the next run (T12).
Known: a player starts loading only when it hears "playing", so if its files
take longer than the conductor's 1 s lead it joins a little late (in sync, but
its first moments are black).
A first loopback run was invalid: Mat's open 0.1.2 held the port, and the
cleanup closed that copy too.

Stage 2 (2026-10-21, `[claude]`): `ClockService.swift` (ClockServer /
ClockClient, BSD sockets on dedicated threads, as the probe), `ClockPacket`
and `SteadinessMeter` in PlayerCore (8 tests). Setup: This Mac = Standalone /
Conductor / Player (+ address), stored per Mac; status line; logged every 10 s.
Playback does not use conductor time yet (Stage 3). Checks on one Mac:
- app as Conductor, probe joins over loopback: 371/371 replies, steady 0.01 ms;
- probe serves a fake +7.5 ms / 50 ppm, app as Player: drift read 49.7–51.3
  ppm; offset 8.09 → 8.55 → 9.07 ms at 10 s steps, i.e. 7.5 ms plus 50 ppm
  of elapsed time, as it should be;
- stop/start five times on the same port: binds every time, stops ≤ 0.1 s.
Two bugs found by running it: the clock started twice at launch (the mode's
didSet fires in init after all), so the second bind failed; and stops took
1 s because `shutdown()` doesn't wake a blocked UDP recvfrom on macOS (fixed
with a 0.1 s receive timeout). Untested: macOS Local Network permission for
the app on a real network (loopback is exempt). The two-Mac run tests it.
To run it: build the app (`scripts/make-app.sh`), Conductor on one MacBook,
Player on the other with the first one's address, 10 min; read
`log show --predicate 'process == "tableauX"' --last 15m | grep clock:`.

Stage 1 replay, `[claude]` `ClockReplayTests` (the same recording through
`ClockEstimator`, the app's code, not the probe's filter):
- steady to 0.27 ms (95%), matching the probe;
- drift −12.4 ppm from the last 60 s vs −12.0 ppm over the whole run;
- a 300 s dropout cut from the recording: worst error 0.40 ms on
  extrapolation alone. Mutation: with drift ignored that becomes 3.7 ms and
  the test fails.

### Not started
- v2 (several videos per display, sync groups/offsets/nudge): spec DRAFT in
  docs/architecture.md, awaiting Mat's confirmation of the ▸ decisions.

### Test builds
Each build handed out for testing gets the next patch number, so a report
can name exactly what was run. Playlist builds are 0.3.x (Mat: "move to three");
whether 0.2 (two-Mac sync) is published on its own is still Mat's call.
- 0.1.2 (2026-10-21, commit 5f7ab71): Stage 2, clock service. For the
  two-MacBook clock run. Not published.
- 0.1.3 (2026-10-21): Stage 3a, players follow the conductor. For the
  two-MacBook start test and the sweep-line photo (T12). Not published.
- 0.3.0 (2026-10-21, uncommitted P2 + collect/import): one-Mac playlists,
  Import folder, Collect show / work. For Mat's single-Mac show test.
  Across Macs it still plays only one looping work. Not published.
  Mat 2026-10-21: "all working very well", except a display added after a
  scan stayed black instead of taking the left-over files.
- 0.3.1 (2026-10-21, commit ca9ab4d): 0.3.0 + new displays take left-over
  files (P2c). Not published. On three Macs (one Intel) Play was blocked
  by the P2 network limit although every Mac had the same file.
- 0.3.2 (2026-10-22): the P2 network limit is a warning, not a block, so a
  playlist of identical-length files plays across Macs. Not published.
  Mat 2026-10-22: "all working", a short ProRes test video across 5
  screens on 2 Macs, playlist with work changes (by eye; no log or
  photo recorded). Which 2 of the 3 Macs, and whether the Intel one was
  among them, not recorded.

### Release 0.1.1 (2026-10-21): first public release, as tableauX
github.com/psychosophonis/tableauX. A 0.1.0 under the old name ("Multiscreen
Player", repo /tableau) was published minutes earlier and then deleted at
Mat's request, so 0.1.1 is the first release. App, binary, process, package and
repo are tableauX; show files are `.tableaux` (Open still accepts `.msshow`).
`PlayerCore` and the local folder keep their names.

Work in this release:
- Review bug 2 fixed: `SyncMath.resumedStart` clamps a pause to the start, so
  Space in the first second resumes from frame 0 (tested); Space is ignored
  until the start is scheduled.
- `scripts/make-app.sh`: universal (arm64 + x86_64), ad-hoc signed `.app` and
  zip; checked by unzipping and launching. Needs Open Anyway on first launch.
- `docs/LAB-TEST.md`: tech checklist (T6 sweep-line photos, T4 10-minute run
  with the log via `log show`). T4 in the lab is judged by eye: the app does
  not count dropped frames.
- Esc, Space and multi-display starts exercised by Mat on the dev machine
  (two and three displays, 4K ProRes): all worked.

## Open questions
- ~~Is building a 2000-segment composition fast enough?~~ Answered by
  `proofs/compose-time.swift`: 0.03–0.05 s to build, ready 0.02–0.06 s later
  (textured 4K H.264 and Mat's 4K ProRes). The cap stays at 2000; what's still
  untested is the freeze when a capped item runs out (a 30 s clip × 2000 =
  16.7 h).
- The lab Mac mini's chip and macOS version are unknown (it drives three
  displays, so probably M2 Pro, M4 or later). The package targets macOS 13.
- Display-to-display presentation offset (T6) can only be tested on the array.
