# Lab test: Multiscreen Player on the BCM116 Mac mini

Two things can only be tested on the real three-display array. This sheet is
for whoever runs them. It takes about 30 minutes. Please send the results
(the filled-in table, the photos and the log) back to Mat.

What's being tested, and why it can't be tested anywhere else:

| Target (docs/architecture.md) | Question | Why only here |
|---|---|---|
| T6 | Do the three displays show the same frame at the same moment? | Each display refreshes on its own schedule; a laptop has one display. |
| T4 | Does the Mac mini play three 4K videos smoothly? | Decoding speed depends on this machine's chip. |

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

Download `MultiscreenPlayer-<version>.zip` and `sweep-test-clips-3840x2160.zip`
from the GitHub release page and unzip both. Move **Multiscreen Player** to
Applications. The first time it opens, see README.md → "First launch".

## 3. Test T6: are the displays in step?

The sweep clips show a white line that runs across all three displays as if
they were one wide screen, plus a frame number on each.

1. Open Multiscreen Player. Choose `panel1…` for display 1, `panel2…` for
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
   log show --last 15m --predicate 'process == "MultiscreenPlayer"' > ~/Desktop/multiscreen-log.txt
   ```

   Send `multiscreen-log.txt` from the Desktop. The lines to look for:
   `start +…` (how long starting took) and `panel resynced` (a display drifted
   more than one frame and was pulled back; a few is fine, many is not).

| | |
|---|---|
| Ran 10 minutes without visible stutter? | |
| Any display visibly behind? | |
| Number of `panel resynced` lines | |

What this can't tell us: the app doesn't count dropped frames itself (only the
desk probe does), so smoothness here is judged by eye.
