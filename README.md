# tableauX

**[⬇ Download the latest version](../../releases/latest)**: open the page
and click `tableauX-<version>.zip` under Assets.

tableauX plays multiscreen video works across any number of displays. A work
can use the displays on one Mac, or the displays on several Macs, each with
several displays of its own, kept in sync over the network. So a work can be
as large as you have screens for: n displays, on as many Macs as it takes.
Each display plays its own video file, full screen at its native resolution.

What it does:

- **Plays many displays as one work.** A triptych is three files, one per
  display; a twelve-screen wall is twelve. They start together and stay in
  step.
- **Plays a playlist of pieces.** Each piece plays, the screens go black for a
  moment, the next piece starts, and after the last it loops back to the
  first.
- **Runs across several Macs.** One Mac conducts; the others follow it and
  play their own copies of the files. Tried so far: three Macs, five screens.
- **Runs unattended.** It can start the show by itself when the Mac turns on.

It's a Mac app (macOS 13 or later, Apple silicon or Intel).

## Download

Get `tableauX-<version>.zip` from the
[latest release](../../releases/latest), unzip it, and move **tableauX** to
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

## Running one playlist on a triptych

<!-- [claude] 2026-10-22: the technician's sheet for the single-Mac case
     (one Mac mini, three displays, one looping playlist). Nothing here
     needs the network or a second Mac. -->
One Mac mini plays one playlist across three displays in a row, in sync, on
a loop. Setup takes about 20 minutes; after that it runs itself. You need
**tableauX.app**, a **`tableauX` library folder** prepared by the show's
author (videos plus a playlist set to start on its own), the three displays
connected, and an admin login.

### 1. Set up the Mac

1. **Arrange the displays.** System Settings → Displays → Arrange: put the
   three in a row, **left to right as they physically stand**. tableauX
   numbers them 1, 2, 3 from this layout; a wrong order puts videos on the
   wrong screens.
2. **Native resolution on each display** ("Default" for a 4K display).
   Avoid "More Space" and other scaled settings: macOS resamples the
   picture, which is what this app exists to avoid.
3. **Copy the library** into your home folder's **Movies** folder, so the
   path is `Movies/tableauX`. Don't rename it.
4. **Install the app:** drag tableauX into Applications, then open it as in
   [First launch](#first-launch). If macOS asks about finding devices on
   the local network, click **Allow**.

### 2. Start and check it

When tableauX opens, all three displays go black and then start together.
Each work plays, the screens go black for a few seconds, the next work
starts, and after the last it goes back to the first. If the window stays
up instead, check the Show menu names the right show and click **Present**.

- [ ] Each video is on the right display (if two are swapped, fix the
      arrangement in step 1).
- [ ] The three displays are in step: a phone photo of the whole row shows
      the same moment on all three.
- [ ] It moves from work to work on its own and loops after the last.

Keys: **Space** pauses and resumes, **→ / ←** next or previous work,
**Esc** back to the window. Don't change anything in the window: the show
saves itself.

### 3. Make it run unattended

1. **Open at login:** System Settings → General → Login Items → **+** →
   tableauX.
2. **Log in automatically** (if policy allows): System Settings → Users &
   Groups → Automatically log in as → the show account.
3. **Restart after a power cut:** System Settings → Energy → **Start up
   automatically after a power failure**.
4. **Test it:** restart the Mac; the show should play with no one touching
   it.

tableauX keeps the displays awake while it plays. To stop: **Esc**, then
quit (⌘Q), or shut the Mac down.

### 4. If something goes wrong

| What you see | Do this |
|---|---|
| The show stopped and the window came back | A display was unplugged or rearranged. Reconnect it, check the arrangement, click **Present**. |
| One display is black | That screen may have no video in this work. If it's black in every work, check the cable and the arrangement. |
| Videos on the wrong displays | Fix the left-to-right arrangement in System Settings → Displays. |
| The window says it can't find the library | The folder must be `Movies/tableauX`, with that exact name. |
| Stutter, or one display falls behind | Note the time and send the log (below) to the show's author. |

To get the log: press Esc, open Terminal and run

```
log show --last 1h --predicate 'process == "tableauX"' > ~/Desktop/tableauX-log.txt
```

then send `tableauX-log.txt` from the Desktop, with a phone photo if you can.

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
- **Composing ahead**, on a laptop that holds all the files: **Add a Mac…**
  in the Tableau line for each gallery Mac (a name like "Gallery 2" and
  its displays), fill its screens from your library, Preview the whole
  thing, then Show menu › **Make kits for each Mac…** and copy each kit to
  its Mac. Each Mac recognises its part by its files, so the gallery
  Macs' own names don't matter. To conduct from the laptop without it
  showing anything, set its count in the Tableau line to 0; Present then
  gives you remote controls in the window.
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
