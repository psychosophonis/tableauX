# Lab test: tableauX on the BCM116 Mac mini

Some things can only be tested on real hardware: the three-display array for
the picture (§ 3-4), and an audio interface for the sound (§ 5-6). This sheet is
for whoever runs them. The picture tests take about 30 minutes; the sound drift
test takes another 30, most of it waiting. Please send the results (the filled-in
tables, the photos and the logs) back to Mat.

What's being tested, and why it can't be tested anywhere else:

| Target (docs/architecture.md) | Question | Why only here |
|---|---|---|
| T6 | Do the three displays show the same frame at the same moment? | Each display refreshes on its own schedule; a laptop has one display. |
| T4 | Does the Mac mini play three 4K videos smoothly? | Decoding speed depends on this machine's chip. |
| T22 | Does the sound stay with the picture? | Needs an interface and speakers; a virtual device has no picture to check against. |
| T23 | Does the sound hold to the host clock over hours? | A real interface runs on its OWN crystal, which drifts against the Mac's. A virtual device shares the Mac's clock and reads 0.00 ppm, so it cannot answer this. |

## 0. Record the machine

| | |
|---|---|
| Mac mini model and chip (Apple menu → About This Mac) | |
| macOS version | |
| Each display: model, connection (HDMI / Thunderbolt / USB-C) | |
| Each display's resolution setting (System Settings → Displays) | |

The app needs **macOS 13 or later**.

## 1. Set up the displays

1. System Settings → Displays → Arrange: put the three displays in a row,
   **left to right as they physically stand**. The app numbers them 1, 2, 3
   from this arrangement.
2. Set each display to its **native resolution** (for a 4K display, "Default"
   or 3840 × 2160 / "looks like 1920 × 1080"). Avoid "More Space" or other
   scaled settings: in those, macOS resamples the picture, which is the
   artefact this app exists to avoid. Note the setting in the table above.

## 2. Install

Download `tableauX-<version>.zip` and `sweep-test-clips-3840x2160.zip`
from the GitHub release page and unzip both. Move **tableauX** to
Applications. The first time it opens, see README.md → "First launch".

## 3. Test T6: are the displays in step?

The sweep clips show a white line that runs across all three displays as if
they were one wide screen, plus a frame number on each.

1. Open tableauX. Choose `panel1…` for display 1, `panel2…` for
   display 2 and `panel3…` for display 3. Fit, audio off.
2. Press **Play**.
3. **Watch the gaps between displays.** In sync, the line leaves one display
   and enters the next cleanly. If a display is late, the line jumps backwards
   or appears twice at that gap.
4. **Take 5 photos of the whole array** with a phone (fast shutter: most
   phones' default is fine in a dim room). In each photo, read the three frame
   numbers.

| Photo | Display 1 frame | Display 2 frame | Display 3 frame |
|---|---|---|---|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |

Equal numbers (or differing by 1, when a photo catches a frame change) =
pass. A steady difference of 2 or more on one display = that display is late.

5. Press **Space** (pauses all three), Space again (resumes), then **Esc**
   (back to setup). Note anything odd.

## 4. Test T4: three 4K videos for 10 minutes

Use Mat's real 4K exports (he'll say which files), one per display.

1. Choose a file for each display, press **Play**, and let it run **10
   minutes**.
2. Watch for stutters, freezes, or one display falling behind the others.
3. Press **Esc**, then open **Terminal** and run:

   ```
   log show --last 15m --predicate 'process == "tableauX"' > ~/Desktop/tableauX-log.txt
   ```

   Send `tableauX-log.txt` from the Desktop. The lines to look for:
   `start +…` (how long starting took) and `panel resynced` (a display drifted
   more than one frame and was pulled back; a few is fine, many is not).

| | |
|---|---|
| Ran 10 minutes without visible stutter? | |
| Any display visibly behind? | |
| Number of `panel resynced` lines | |

What this can't tell us: the app doesn't count dropped frames itself (only the
desk probe does), so smoothness here is judged by eye.

## 5. Test T22: does the sound stay with the picture?

Needs the audio interface and its speakers. **Turn the monitors down before the
first play**: tableauX uses the Mac's default output *at full level*, and
**Interface** under Sound says which device it picked.

A work's sound lives in an `audio` folder inside the work's folder, on the Mac
that plays it. Each file goes to the output its name ends in:

```
Works/Smith/
  Smith_1.mov
  audio/
    front_1.wav      output 1
    rear_5.wav       output 5
```

If the interface reserves its first outputs — a Behringer's 1-2 are its master
stereo pair — set **New sound starts at output N** before adding files, and new
sound is allocated above that floor.

1. Open a work that has both video and an `audio` folder. Check the **Sound**
   table: every source listed, on the outputs you expect.
2. Press **Preview**, then **Present**. Listen for the sound starting with the
   picture, and watch anything with a visible hit in it (a cut, a clap, a door).
3. Let it loop **at least three times**. The question is not whether it starts
   together but whether it is still together on the third pass.

| | |
|---|---|
| Interface, and how many outputs | |
| Sound started with the picture? | |
| Still together after three loops? | |
| Anything audible on an output that should be silent? | |

What this can't tell us: "together" here is judged by ear, which catches tens of
milliseconds at best. § 6 measures the drift properly.

## 6. Test T23: does the sound hold over hours?

This is the **biggest open question in the sound work**, and it needs one cable.
A real interface clocks itself on its own crystal; the Mac's video clock runs on
another. If they drift apart, a work that starts in sync ends out of sync, and
nothing in the app has yet shown whether AVPlayer corrects for it.

The test is a **LOOPBACK**: the app plays a signal out of one output, the same
interface records it back in, and the test measures where the signal actually
landed against where the host clock said it should. Drift shows up as a slope in
that error, in parts per million — 1 ppm is one sample in a million, about
3.6 ms per hour at 48 kHz.

1. Patch **one cable from output 1 to input 1** on the interface — an output and
   the input of the *same number*, since that is the pairing the test assumes.
2. `TABLEAUX_LOOPBACK_DEVICE` takes **any part of the device's name** as Audio
   MIDI Setup shows it, not its UID: `"UMC"` finds a Behringer UMC. A name that
   matches nothing fails with `no device matching <name>`, without listing what
   it did find, so check the spelling in Audio MIDI Setup first.
3. `TABLEAUX_LOOPBACK_OUTPUTS` must name the outputs actually patched — it
   defaults to `1,2,5,9`, which is right for a 16-channel virtual device and
   wrong for one cable. In Terminal, in the project folder:

   ```
   TABLEAUX_LOOPBACK_DEVICE="UMC" \
   TABLEAUX_LOOPBACK_OUTPUTS=1 \
   TABLEAUX_LOOPBACK_SECONDS=1800 \
   caffeinate -i swift test --filter AudioLoopback
   ```

   `caffeinate -i` stops the Mac sleeping mid-run; **leave the lid open**, since
   closing it on some Macs sleeps the machine regardless. Without the
   environment variables the test SKIPS rather than fails, which is why the
   suite passes on a laptop with nothing patched.
4. Keep the printed output. The signal is a tone per output with a **click on
   every whole second**, and the test prints how late the first and last clicks
   were, in milliseconds, and the slope between them in ppm.

| | |
|---|---|
| Device, and its clock source (internal / word clock / ADAT) | |
| Minutes run | |
| Drift, ppm | |
| Did the app resync, or was the error allowed to grow? | |

A real interface reading 0.00 ppm would mean AVPlayer is tracking the host
clock. Anything over about 1 ppm means a long work needs correcting, and the
measurement says how much.

**30 minutes is a first look, not the target.** T23 asks for 8 hours, because
that is a gallery day. A half-hour run is enough to measure a slope and tell a
drifting clock from a tracked one; it is not enough to say a day-long work holds,
and a slope measured over 30 minutes assumes the drift is steady, which is
exactly what a long run would test. Run it long once the short run says there is
something to follow.

If a variable here stops working, the test's own header comment
(`Tests/PlayerCoreTests/AudioLoopbackTests.swift`) is the one that governs: it
sits beside the code that reads them, so it is what gets updated first.

