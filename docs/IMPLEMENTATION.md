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
| 2 | Clock service over UDP in the app (the probe as a component) | two Macs hold a steady estimate in the app | |
| 3 | Modes: Standalone / Conductor / Player; messages; conductor setup lists all machines | a 6-screen show set up from one MacBook | v3 decisions confirmed (Mat, 2026-10-21) |
| 4 | Two-MacBook sweep test (T12), dropout test (T13) | within 1 frame; no visible desync | release 0.2 |
| later | v2 multi-video | needs the six v2 ▸ decisions, decode-load probe (T9) | spec draft |

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
