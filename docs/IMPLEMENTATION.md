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
| P3a | State carries the work index: → / ← on the conductor, players follow | T17 | **built 2026-10-22** `[claude]` (build 0.3.3): ShowState 48 bytes (1 new test); not yet run across Macs |
| P3b | TCP link: inventories → conductor's playlist + lengths → players; file check | T16, T17 | **built 2026-10-22** `[claude]` (build 0.3.4): 10 new tests; loopback checks both ways (see notes); not yet run across Macs |
| P4a | Conductor sets every Mac's screens from their reported files | Mat: "work entirely on the conductor" | **built 2026-10-22** `[claude]` (build 0.3.5); loopback screenshot found and fixed a bug (one-machine show lost the conductor's part when a player joined; 2 new tests) |
| P4b | Zero setup: `tableauX` folder (beside the app first), role from the folder, Bonjour discovery | Mat: send the app + a folder and it "just works" | **built 2026-10-22** `[claude]` (build 0.3.6): 6 new tests; run on this Mac (see notes); Bonjour on the uni network and translocation on a fresh Mac untested |
| P4c | Test show packaged with the app (Mat: "for me, and for testing") | `scripts/make-test-show.sh` | **built 2026-10-22** `[claude]`: `dist/tableauX-0.3.6-test.zip` (10 MB): "Test conductor" + "Test player" folders; 2 works (red 12 s, blue 8 s) × 3 screens, count = seconds.frame, white flash each second. Conductor kit opened on this Mac: role and show from its folder, Play enabled |
| P4d | Library: Works/ pool + Shows/ playlists; show menu; New show (all works); Add from library; conductor switches, players follow | Mat: many shows in one app, works movable between shows | **built 2026-10-22** `[claude]` (build 0.3.10): 5 new tests; kit run (see notes) |
| P4e | Preview: the whole tableau in one window, a row per Mac | Mat: "test my shows on a single screen" | **built 2026-10-22** `[claude]` (build 0.3.12): 2 new tests; preview run of a 2-Mac (2 + 3 screens) show and a real-show regression run (see notes) |
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
  photo recorded). One of the 2 Macs was a late-model Intel Mac: the first
  run of tableauX on Intel. Logs to follow; no long video tested yet.
  Long sync clips made for the next run: `testmedia/long/` (5 × 600 s 1080p
  sweep, `scripts/make-test-media.sh testmedia/long 1920 1080 600 5`).
- 0.3.3 (2026-10-22): P3a, → / ← across Macs. States are 48 bytes, so it
  doesn't mix with 0.3.2 or older. Not published.
- 0.3.4 (2026-10-22): P3b, one playlist from the conductor. Not published.
  Loopback checks on this Mac, the app against a script standing in for
  the other Mac:
  - app as Conductor, fake player: player added as a machine after the
    conductor, its folder became a work with files in name order, length =
    its longest file (40 s);
  - app as Player, fake conductor started 3 s later: the player connected
    on a retry, sent hello and an inventory with measured lengths (6, 3,
    4, 4, 5 s, matching the files), took the 4-work playlist, and reported
    the one missing file.
  Not checked: two real Macs; Play driven by a shared playlist (needs the
  run); a 0.3.3 Mac mixed in (should show a build warning only once both
  run 0.3.4, since 0.3.3 has no link).
  The 8 h P0 probe was running during these builds and runs (09:22–).
- 0.3.5 (2026-10-22): + P4a, any Mac's screens set from the conductor, and
  the one-machine-show adoption fix. Not published. Loopback (app as
  conductor, fake player): picker shows the player; the player's reported
  problem blocks Play, named. Not checked: choosing a player's file in the
  menu by hand (needs a person), two real Macs.
- 0.3.6 (2026-10-22): + P4b zero setup. Not published. Run on this Mac: the
  built app in a `tableauX` folder with three works and no show, settings
  wiped, a script as conductor announced by `dns-sd -R`:
  - opened from Finder: found its own folder, made itself a Player, but sat
    at "looking for a conductor" for 15 s: most likely waiting for the
    Local Network permission (an app opened from Finder needs its own);
  - the same app run from Terminal (Terminal's permission): found its
    folder, role Player, found "Fake Conductor" by Bonjour, connected,
    clock on 192.168.1.46, sent its inventory, took the playlist, reported
    the missing file; rediscovered it after it closed.
  To check on real Macs: discovery after clicking Allow; Bonjour on the
  uni network; translocation on a fresh Mac.
- 0.3.7 (2026-10-22): fix from Mat's run. The app in
  /Volumes/Espirit/testshow (works, no show file) opened the test kit's show
  from the Desktop instead (every file "missing"; Scan merged work1–3 into
  it). Now a found folder with no show file starts a fresh show from its
  works. 1 new test.
- 0.3.8 (2026-10-22): "_N" = tableau screen N (Mat). Scan, conductor merge,
  new displays and Import honour it; Collect names copies for their screens
  when a scan wouldn't restore them. 10 new tests (133); 3 old Collect
  expectations changed on purpose (they now number). Offset mutant caught.
- 0.3.9 (2026-10-22): fix from Mat's run of 0.3.8. Layout
  testshow/{tableauX.app, tableauX/{work1..3}}: no folder was found (the
  search didn't look for tableauX beside the app), so the test kit's show
  reopened. Now a tableauX folder beside the app is searched second.
- 0.3.10 (2026-10-22): P4d library. Kit now in the library layout
  (Works/ + Shows/ with two shows over the same works). Run: the kit
  conductor found its library (works in Works/), became Conductor, opened
  a show; a fake player reporting an extra work "Lee" left the saved show
  at its 2 works (Lee offered in Add from library) and got screens for the
  work it shares. Not run: switching shows by hand (needs a click), New
  show, Collect into the library layout.
- 0.3.11 (2026-10-22): a fresh Mac gets a library made for it,
  ~/Movies/tableauX/{Works,Shows} (Mat), and starts Standalone. Run with a
  stand-in home folder and no settings: created, Standalone, setup says
  where to put works. Also: Mat's 30 s first launch from Espirit was macOS
  checking a new ad-hoc-signed app on an external drive (the app's code
  didn't start for 29.7 s; the log shows AMFI "adhoc signed"); later
  launches of the same copy opened in under 1 s. Each new build repeats it
  once; notarisation would remove it.
- 0.3.12 (2026-10-22): P4e preview. Run (`--preview`) of a show for two
  Macs (2 + 3 displays) from the test kit's files: 5 tiles in two rows,
  all showing the same count (7.00) with the flash lit together, Mac B
  display 2 black as set, "1 Red starts on time". Regression: a real show
  (Play on launch, test kit) played full screen through the new surface
  code, "1 Red starts on time". Not run: → / ← and the close button in the
  preview by hand.
- 0.3.13 (2026-10-22): fix from Mat: the connected display count no longer
  overwrites the show's designed count. Run on this Mac with 1 display
  connected and the 3-display test show: setup kept "Displays in this
  show: 3" with displays 2–3 "not connected here", and the preview played
  3 tiles in step. 1 new test (a report of fewer displays keeps the design).
- 0.3.14 (2026-10-22): from Mat's run of 0.3.13 on Espirit (1 display,
  works with _1–_3): the new all-works show still STARTED at the connected
  count (1), leaving _2/_3 unused. Now a new show (and a player joining)
  is sized by what its works need. Run against a link to Mat's works
  folder with 1 display: 3 works, preview of 3 screens. 2 new tests.
- 0.3.15 (2026-10-22): Compose / Present (Mat's words): Preview and the
  [Compose | Present] switch in the top bar, "Present (1 of 3 displays)"
  when short of displays, "Open in Present mode" for playOnLaunch.
  Screenshot checked. The check run's window took keyboard focus while Mat
  was typing elsewhere and his keystrokes renamed a work in that (unsaved,
  temporary) show; fixed: nothing is focused when the window opens.
- 0.3.16 (2026-10-22): autosave for named shows; Save… → Save As… (Mat was
  asked to name a show New show… had already saved). Not run by hand yet
  (needs edits in the window): to check, edit a named show, wait 2 s,
  switch shows and back.
- 0.3.17 (2026-10-22): interface step 1: tableau map, status line,
  automatic rescan (no Scan button), one note for "fewer displays than
  designed". Builds and passes 144 tests. Looked at (with Mat's OK) on a
  link to his works folder: map, status line and note as intended.
- 0.3.18 (2026-10-22): from Mat's triptych show (a 3-screen and a 2-screen
  work): the per-Mac display count moved out of the work's map into a
  "Tableau" row (it is the show's, for every work); the playlist reads
  "2 of 3 screens". Mat's TestNewShow had displays 2 with both works'
  third screens kept: setting it back to 3 restores them.
- 0.3.19 (2026-10-22): Mat's review. Preview / Present buttons (no
  Compose switch); Collect gathers into this library, copying only files
  outside Works/ (Collect.gather, 4 tests); the old copy-elsewhere is
  "Export show as a library…" in the Show menu, with "Start presenting
  when tableauX opens" and "Open a show from elsewhere…"; New work; Import
  work…. 148 tests. Not looked at in a window yet.
- 0.3.20 (2026-10-22): launch indicator with Skip; the library search runs
  after the window is up; startup timings logged. P0 8 h probe at 5 h 20
  min: memory 38 → 46 → 54 → 59 → 67 MB at hours 1–5, i.e. a steady
  ~7–8 MB/h, not levelling off: a slow leak in the work-switch cycle
  (360 swaps/h, far more than a real playlist's ~10–20/h). Final at 17:25.
- 0.3.21 (2026-10-22): fix from Mat's M5: opened from Downloads, the app
  took Downloads as its library (its own folder counted if it held any
  folder of videos): every video folder became a work, one of 16 screens.
  The app's own folder now needs a Works/ or Shows/ folder or a show file.
  1 new test (the Downloads case); nothing on the M5 was saved or moved.
- 0.3.22 (2026-10-22): a player edits its own screens (Mat), sent to the
  conductor as setScreen and recorded there; linked files outside the
  player's library are reported under their full path for lengths and the
  file check, and kept out of the pool. 2 new tests (151). Not run across
  Macs yet: part of the Wi-Fi run.
- 0.3.23 (2026-10-22): networked preview (Mat): the conductor's Preview
  opens each player's own preview, in step. ShowState preview flag (1 new
  test, 152). Not run across Macs yet. Mat reported 0.3.22 "working well"
  in use (details to come with the Wi-Fi run).
- 0.3.24 (2026-10-22): compose ahead, step 1 of 4: Macs by label, Add a
  Mac… / remove, their screens filled from this library and counted for
  work lengths. 2 new tests (154). Not looked at in a window.

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
