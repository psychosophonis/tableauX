# tableauX

A macOS app that plays one video per display, in sync, at each display's own
resolution. Built for gallery and lab screen arrays (first use: the BCM116 lab,
a Mac mini driving three 4K displays), where the usual trick of stretching one
huge video across a virtual display resamples the picture and leaves artefacts.

- One video per display, numbered left to right from macOS's display
  arrangement.
- Sync: every display's player follows the Mac's own clock and starts at the
  same scheduled instant; a check once a second pulls back any display that
  drifts more than a frame.
- Seamless looping, Fit or Fill per display, audio on/off per display.
- Shows save to `.tableaux` files and can play automatically when the app
  opens. (Shows saved as `.msshow` by the earlier "Multiscreen Player" builds
  still open.)

## Download

Get the latest `tableauX-<version>.zip` from the
[Releases page](../../releases), unzip it, and move **tableauX** to
Applications. It runs on Apple silicon and Intel Macs, macOS 13 or later.

### First launch

The app isn't notarised by Apple, so macOS blocks it the first time:

1. Double-click it; macOS says it can't be opened. Click **Done**.
2. Open **System Settings → Privacy & Security**, scroll down, and click
   **Open Anyway** next to "tableauX was blocked".
3. Confirm. After this it opens normally.

## Use

1. In the setup window, **Choose…** a video for each display (or leave one
   empty to keep it black). Pick **Fit** (whole picture, black bars if the
   shapes differ) or **Fill** (covers the display, crops the overflow).
   Each row shows the scale factor: **2×** for an HD file on a 4K display is a
   clean doubling; anything else means the picture is interpolated.
2. Press **Play**. All displays go black, then start together.
3. During playback: **Space** pauses and resumes, **Esc** stops and returns
   to setup.
4. **Save…** keeps the arrangement; tick **Play on launch** to have it start
   by itself when the app opens (for unattended installations).

If a display is connected, removed or rearranged during playback, the show
stops and returns to setup.

## A show on several Macs, with no setup on each Mac

<!-- [claude] v4 P4b, from build 0.3.6. -->
Put the app and the videos in one folder (called **tableauX** if it isn't
the folder the app is in), one folder per work inside it, holding that
Mac's files for the work. End each file's name with its **screen number**,
`_1`, `_2`, `_3`…, counted across the whole tableau: a six-screen piece on
two three-display Macs is `_1`–`_3` on the first Mac and `_4`–`_6` on the
second. A missing number leaves that screen black. Files without a number
go on the free screens in name order.

```
tableauX/
  tableauX.app
  Class show.tableaux     ← only in the conductor's folder
  Smith/Smith_1.mp4, Smith_2.mp4
  Jones/Jones_1.mov
```

Copy a folder like this to each Mac (Collect show… on each Mac makes one)
and open the app. It finds its videos in the folder it is in (or a
`tableauX` folder in the home folder, Movies or the Desktop) and works out
its role. A folder **with** a show file runs as the **Conductor**; one
without runs as a **Player**, finds the conductor on the network by itself,
sends it a list of its videos, and plays its part. Arrange every Mac's
screens from the conductor's setup window.

Each Mac still asks twice the first time: **Open Anyway** (see First launch)
and **Allow** when macOS asks about finding devices on the local network.
If the network blocks discovery, type the conductor's address on the player
instead.

### Test show

`tableauX-<version>-test.zip` (made by `scripts/make-test-show.sh`) holds
two ready folders: **Test conductor** (with a show file) and **Test player**
(without). Copy the first to one Mac and the second to the others, and open
the app in each. Two works, red then blue, each a numbered count
(`seconds.frame`, 30 frames a second) with a white block that flashes on
every whole second: screens in step show the same number and flash
together, and a phone photo shows any offset in frames.

## Updates

Each new version is a new release on the [Releases page](../../releases).
Download it and replace the app in Applications.

## Testing on the lab array

See [docs/LAB-TEST.md](docs/LAB-TEST.md): a 30-minute checklist for the two
things only the real array can show (whether the displays are in step, and
whether the Mac mini plays three 4K videos smoothly). Test clips are attached to
each release.

## For developers

Swift package, macOS 13+. `swift run` to run; `swift build && swift test` to
verify; `scripts/make-app.sh <version>` to build the `.app` and zip. The spec is
[docs/architecture.md](docs/architecture.md); status and open questions are in
[docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md). Developed with a
PLAN → PROVE → IMPLEMENT → VERIFY loop (falsification probes live in
`proofs/`).
