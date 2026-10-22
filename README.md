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

The first launch of each new version can take up to half a minute,
especially from an external drive, before anything appears: macOS is
checking the app. Later launches are quick. Once the window is up, a line
at the top says what tableauX is doing (finding the library, measuring
videos); **Skip** lets you get on with it.

## Use

The window is where you compose a show: its works, and each work's screens
drawn as the tableau (click a screen to choose its video, or None to keep
it black; Audio; **Fit**, whole picture with black bars if the shapes
differ, or **Fill**, covering the display). The **Tableau** line sets how
many displays each Mac has in the show, the same for every work. Two
buttons at the top:

- **Preview** plays the show in a window, every screen as a tile.
- **Present** plays it full screen on the real displays. All displays go
  black, then start together. **Space** pauses and resumes, **→ / ←**
  change work, **Esc** comes back to the window.

A show saves itself as you change it, once it has a name (New show…, or
**Save…** for the automatic "All works" show). **Save As…** makes a copy
under a new name. For an unattended installation, tick **Start presenting
when tableauX opens** in the Show menu.

If a display is connected, removed or rearranged during playback, the show
stops and returns to setup.

## The library: works and shows, on one Mac or several

<!-- [claude] v4 P4b–P4d, from build 0.3.10. -->
tableauX keeps a **library**: a folder called **tableauX** beside the app, or
in your home folder, Movies or the Desktop; or the folder the app itself is
in, if that folder has a `Works` or `Shows` folder in it:

```
tableauX/
  Works/                       one folder per work, this Mac's files for it
    Smith/Smith_1.mp4, Smith_2.mp4
    Jones/Jones_1.mov
  Shows/                       show files: playlists of works (conductor only)
    Graduate show.tableaux
    Night screening.tableaux
```

- **A work is one folder**, however many shows it is in. A show is a
  playlist naming some works, with its own settings for each.
- End each file's name with its **screen number**, `_1`, `_2`, `_3`…,
  counted across the whole tableau: a six-screen piece on two three-display
  Macs is `_1`–`_3` on the first Mac and `_4`–`_6` on the second. A missing
  number leaves that screen black; files without a number go on the free
  screens in name order.
- **Switch shows** with the Show menu at the top of setup. **New show…**
  starts with every work; **Remove** and **Add from library** curate it
  (no files move). A library with no show yet plays all its works.
- **Several Macs:** each Mac's library holds its own files in `Works/`; only
  the conductor has `Shows/`. A Mac with show files runs as the
  **Conductor**; one without runs as a **Player**, finds the conductor on
  the network by itself, sends it a list of its works, and plays whichever
  show the conductor has open, switching when it switches. Arrange every
  Mac's screens from the conductor's setup window.
- **Import work…** turns a folder of videos anywhere into a work, linked
  where it is. **Collect show** later brings those files into `Works/`,
  copying only what isn't in the library already. **Export show as a
  library…** (Show menu) copies the show as a library of its own, to
  archive or hand on.
- **Preview** (beside Play) plays the show in one window: every screen of
  every Mac as a tile, one row per Mac, from the files on this Mac. Use it
  to check order, timing and which file is on which screen; Esc closes it.

A `tableauX` folder holding works directly (no `Works/` inside) also
works, as a library of its own. If tableauX finds no library at all, it
makes one in **Movies → tableauX** and tells you. (Opened from Downloads,
it doesn't take Downloads for a library, however many videos are there.)

Each Mac still asks twice the first time: **Open Anyway** (see First launch)
and **Allow** when macOS asks about finding devices on the local network.
If the network blocks discovery, type the conductor's address on the player
instead.

### Test show

`tableauX-<version>-test.zip` (made by `scripts/make-test-show.sh`) holds
two ready libraries: **Test conductor** (with two shows, the same works in
opposite orders, to try switching) and **Test player** (works only). Copy the first to one Mac and the second to the others, and open
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
