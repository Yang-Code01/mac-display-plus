# Notes on the macOS display stack

Things that took longer to find than they should have. Each entry is a failure
mode that *looks like* a different problem, plus the measurement that identified
it. Numbers come from these machines:

| | |
|---|---|
| Built-in | MacBook Air, 1440 × 900 points @ 2x (2880 × 1800 pixels) |
| External | AOC 2490W1, 21.5", native 1920 × 1080, via USB-C → HDMI active adapter |
| OS | macOS 27.2 (26B123), Apple Silicon |

Every claim below was produced by a `--flag` in this repository; the flag is
named next to each.

---

## 1. `io_object_t` truncates `IOAVService`

`IOAVServiceCreateWithService` returns a **24-byte heap object**, not a mach
port. Declaring it as `io_object_t` (32 bits) truncates the pointer:

```
declared io_object_t   -> 0x0000000000672da0
actual object          -> 0x0000600001a2b4c0
```

Then `IOAVServiceWriteI2C` reads `[x0, #0x14]` on a truncated pointer and
segfaults. The disassembly of `IOAVServiceWriteI2C+68` is what settles it.
Declare the return as `UnsafeMutableRawPointer` instead.

Also: doing I2C against the built-in display's `DCPAVServiceProxy` segfaults
too. Only touch services whose `Location` is `"External"`.

---

## 2. `CGDisplayMode` cannot cross a function scope

`CGDisplayMode` is not toll-free bridged. Its handle is owned by the `CFArray`
returned from `CGDisplayCopyAllDisplayModes`, and once that array dies, the mode
handle is still readable — every property access works — but applying it returns
`kCGErrorIllegalArgument (1001)`.

Both of these fail:

```swift
func modes() -> [CGDisplayMode] { /* array freed on return */ }
let mode = unsafeBitCast(element, to: CGDisplayMode.self)  // no
```

Look up and apply the mode inside the **same** function scope. This is why
`Model/DisplayModeInfo.swift` is a pure value type with no `CGDisplayMode`
inside it, and why `DisplayManager` re-resolves the mode index every time it
applies one.

---

## 3. The panel was sized once, at open time — so a mode change pushed it offscreen

The resolution slider lives *inside* the panel, which means the screen geometry
can change while the panel is open. Caching the panel height at open time means
a resolution change moves the panel under the menu bar or off the bottom.

Fixes, all of them necessary:

- Recompute size and position from the **current** anchoring screen every time,
  never cache
- Clamp **both axes** (`clampedOrigin`); clamping only the bottom-left lets an
  oversized panel punch through the top
- Hard-cap content height at `min(height, visible.height - 2 * inset)` and hand
  the overflow to a `ScrollView`
- `masksToBounds = true` on the content view so no intermediate layout state
  draws outside the rounded corners
- Observe `NSApplication.didChangeScreenParametersNotification` plus the app's
  own mode-change notification, debounce 120 ms, re-lay out

The geometry is a pure function, so synthetic screen sizes can be tested without
a display: `--geometry-test` passes all 7 cases, from 640 × 480 up to a short
ultrawide. The live path is `--overflow-test`, which shrinks the real screen and
restores it:

```
opened   inside   panel=300x556 at (570,308) visible=1440x795
shrunk   inside   panel=300x461 at (362,271) visible=1024x663
restored inside   panel=300x461 at (570,403) visible=1440x795
```

The panel deliberately does not grow back when the screen gets bigger again:
rebuilding it would lose the expanded/collapsed state, and it is already fully
visible.

---

## 4. Every mode change blanks the display; only the *count* is reducible

Changing the mode means the panel has to resync to the timing generator's new
timing, and HDMI renegotiates the link — one extra round on an active converter.
That blanking is physical. Software cannot remove it.

What software can do is stop doing it five times per slider drag. The old slider
called `CGDisplaySetDisplayMode` on every step. Now:

- while dragging, only the preview value and label change — the display is not
  touched
- `onEditingChanged(false)` commits exactly once
- if the target resolves to the current mode, skip — don't blank the screen for
  a no-op
- during a switch, the resolution row says "switching — the screen will blank
  briefly while the display resyncs", with a 2.5 s backstop so it can never get
  stuck

`--drag-test` sweeps 25 positions:

```
start        1600 × 900 · 1x
swept        25 positions, mode changes = 0
preview      1920 × 1080 · 1x
released     target=840 × 525 · 2x total mode changes = 1
restored     1600 × 900 · 1x applied=true
```

Removing blanking entirely requires never touching the physical mode — keep the
panel on a fixed timing and scale the desktop in a virtual framebuffer. That
needs CoreDisplay's private scaling interfaces (see §8.1 for the partial version
this project does implement, and §9 for why mirroring into a virtual display is
not a substitute).

---

## 5. "The image is stretched" means a non-native aspect ratio was chosen

A 16:9 panel reports 75 modes, and they include:

| Aspect | Modes |
|---|---|
| 4:3 | 640×480, 800×600, 1024×768 |
| 5:4 | 1280×1024 |
| 16:10 | 1280×800, 720×450, 840×525 |
| **16:9** | 640×360, 960×540, 1280×720, 1600×900, **1920×1080** |

A display fed a signal whose aspect ratio does not match its panel does not add
letterboxing — it stretches to fill. Circles become ellipses. Listing every mode
means "set a high resolution" silently changes the shape of everything on screen.

Filter by native aspect ratio, with 1 % tolerance:

```swift
abs(mode.aspect - native.aspect) / native.aspect < 0.01
```

External panel keeps 11 point sizes; built-in keeps 13. A filtered-out request is
refused explicitly rather than quietly substituted:

```
$ display++ --set-mode 2 1280x1024
display 2 does not offer 1280x1024. Available: ...
```

---

## 6. Half the mode table cannot be applied

Auditing this 1920 × 1080 panel row by row, trying every refresh-rate and pixel
variant in each row (`--audit-modes 2`):

```
row                   variants  result
400 × 300 · 2x        5         ALL REFUSED
512 × 384 · 2x        4         ALL REFUSED
640 × 480 · 1x        4         ALL REFUSED
800 × 600 · 1x        5         800 × 600 · 1x @50
840 × 525 · 2x        1         840 × 525 · 2x @60
1920 × 1080 · 1x      2         1920 × 1080 · 1x @50
...
29 rows, 12 entirely dead
```

CoreGraphics reports all of them with the valid bit set in `ioFlags`. If the
resolver picks one variant per row and that variant happens to be refused, the
whole row becomes "clicking does nothing".

So `applyRow` tries every variant of the row — current refresh rate first, then
descending — and only blacklists the row if all of them fail. The panel then says
"this display does not accept that resolution" instead of looking broken.

---

## 7. HiDPI is a backing-pixel dimension, not a desktop-size dimension

The same physical resolution has two different HiDPI pairings on a panel, and
they mean completely different things:

| Pairing | Example | Effect |
|---|---|---|
| Same point size | `1600×900 1x ↔ 1600×900 2x` | layout unchanged, pixels doubled (true HiDPI) |
| Same pixel count | `1600×900 1x ↔ 800×450 2x` | sharpness unchanged, layout halved (this is just a resolution change) |

Grouping by pixel count hides the first kind entirely — "HiDPI unavailable".
Grouping by point size misses the second kind — "some sizes are locked". Collect
both, prefer the same point size.

`--hidpi-matrix 2` marks which point sizes can actually toggle:

```
  桌面尺寸        1x 背板   2x 背板   可切 HiDPI
  960x540        960      1920      ✓
  1024x576       1024     2048      ✓
  1600x900       1600     —         —
  1920x1080      1920     —         —

  2 / 9 个桌面尺寸可切 HiDPI
```

This panel *can* do HiDPI — just not at 1600 × 900, which would need a
3200 × 1800 backing store while the mode table tops out at 1920 × 1080.
`1024 × 576 · 2x` has a 2048 × 1152 backing store, slightly over the panel's
native size, and the panel's scaler accepts it.

The early implementation required a same-size 2x mode and silently did nothing
when one did not exist, so the switch looked broken. A later version "fixed"
that with a "nearest pixel count" fallback, which on this panel turned
`1920 × 1080 1x` into `960 × 540 2x` — same pixel count, half the points, so
everything on screen doubled. That reads as a scaling bug, and it has been
removed. No same-size pairing means the control is greyed out with `no 2x pair`
in the row.

### 7.1 Transaction success ≠ mode applied

Some modes complete the transaction and then revert on the next display
reconfiguration. Trusting the return value produces `toggled=true flipped=false`.
Every apply now re-reads `CGDisplayCopyDisplayMode` and fails the row if the
point size or pixel size does not match; the row is then blacklisted.

---

## 8. The HiDPI toggle: change the backing store, not the timing

Key observation: **switching between modes with identical output timing needs no
physical link retraining.** So the toggle picks the mode with the same timing and
a different backing scale.

Built-in display (`--test-hidpi 1`):

```
before       1440 × 900 · 2x @60Hz pix=2880
toggled      1440 × 900 · 1x @60Hz pix=1440 ok=true
toggled back 1440 × 900 · 2x ok=true
```

Two dimensions that must be kept separate in the UI, or the control reads as
"change resolution":

| Place | Wrong | Right |
|---|---|---|
| Resolution row | `1600 × 900 · 1x` → `· 2x` after toggling | always `1600 × 900` |
| Resolution slider | 1x and 2x are separate stops, toggling moves it | steps by point size only; toggling leaves it alone |
| HiDPI row | `→ 1600 × 900 · 2x` (looks like a target resolution) | `sharper (2x)` / `on` |

### 8.1 Flexible scaling: making 1600 × 900 run at 2x

This panel will not offer `1600 × 900 · 2x` — that needs a 3200 × 1800 backing
store and the table stops at 1920 × 1080. But the window server *can* synthesise
that mode, if there is first a virtual display declaring it and the panel is
currently mirroring onto that virtual display (`--flex-hidpi 2 1600x900`):

```
create virtual 1600×900 hiDPI     created=true id=30
mirror panel -> virtual           active2=0   (panel blanks briefly)
panel's mode list while mirroring 1600×900 pix=3200   <- synthesised
single transaction: unmirror + bind that mode
                                  clear=0 bind=0 complete=0
result                            1600×900 · 2x pix=3200 active=1 online=1
```

Three details that must be followed exactly:

1. **Mirror first, then wait for the mode.** Creating the virtual display is not
   enough: without mirroring, the panel's mode list does not change at all.
2. **Unmirroring and binding must happen in one transaction.** Unmirroring alone
   returns `kCGErrorIllegalArgument (1001)` and the synthesised mode is
   destroyed with it; binding afterwards is refused (`1000`).
3. **The virtual display must stay alive.** Destroy it and the synthesised mode
   disappears and the panel drops back to 1x.

Two side effects also need handling: while mirroring, the virtual display shows
up as a third screen and the panel gets re-anchored to `x = -1600`; so after a
successful bind, mirror the virtual display back onto the panel (it then has no
desktop of its own, and `NSScreen` returns to two), and write the arrangement
from before entry back. And release flexible scaling before changing resolution,
or that virtual display's size no longer matches.

Cost: one blank, 3–4 seconds end to end. Built-in displays use the native pairing
and are instantaneous.

### 8.2 Never fall back to "same pixel count"

This fallback crept back in once: on a panel at `1600 × 900 · 1x` the candidate
list offered `800 × 450 · 2x`, synthesised by macOS from a 4:3 low-resolution
mode. `ioFlags` marks it valid; every attempt returns
`kCGErrorIllegalArgument (1001)`. The switch looked usable, read
`→ 800 × 450 · 2x`, and broke the row permanently on first click. `hiDPICandidates`
now returns same-point-size pairings only.

---

## 9. Virtual displays exist and are cheap — and still cannot remove blanking

`CGVirtualDisplay` works on macOS 27 with no entitlement and no helper. The
object's lifetime is the display's lifetime (`--probe-virtual`):

```
initWithDescriptor -> object
displayID = 6
applySettings -> YES
t=500ms  online=3: 1(1440x900,builtin) 2(1920x1080) 6(1920x1080)
after release, t=400ms  online=2
```

But mirroring the panel onto it does not avoid a mode change: macOS requires
identical timing within a mirror set, so the *physical* display is dragged onto
the virtual display's mode. Same mode change, same blank.

```
mirror 2 -> virtual: begin=0 mirror=0 complete=0
after mirror: display2=1280x720  virtual=1280x720
```

Resizing the virtual display is not fast either — `applySettings` rebuilds its
mode table: 1600 × 900 in 233 ms, 1280 × 720 in 480 ms.

The only design that avoids blanking is a compositor: the virtual desktop is
rendered into a fullscreen layer and presented on a physical display that never
changes mode. That costs a capture/composite/present latency, turns protected
video into a black rectangle, and forces HDR and colour to be redone, and caps
the refresh rate to the pipeline. Trading all of that to avoid one blank during
a deliberate resolution change is not a good trade, so it is not implemented.

---

## 10. Mode changes scramble the arrangement — origins must live in the same transaction

Symptom: every resolution change on the external display moved things around, and
never moved them back.

```
before     *1:(0,0 1440x900)   2:(840,-576 1024x576)
changed to 1280 × 720 · 1x     ok=true
after      *1:(0,0 1440x900)   2:(840,-720 1280x720)   <- y changed
next time  2:(1440,-720 …)                              <- x jumped too, and stayed
```

Two causes.

**Setting an origin in its own transaction is silently discarded.**
`CGConfigureDisplayOrigin` returns `complete=0` (success) and the display does
not move:

```
before  display2 origin = (1440.0, -720.0)
  -> (840,-720)  configure=0 complete=0  now=(1440,-720)
  -> (100,-720)  configure=0 complete=0  now=(1440,-720)
```

The same origin, written in the same transaction as the mode, takes effect.

**Pinning the origin of the display that is changing size pushes it away.** Once
it grows, the old origin usually overlaps a neighbour; the window server cannot
accept overlap, so it slides the display sideways — worse than not pinning.

Current rules:

- displays whose mode did not change: origin **must** be pinned as-is
- the display whose mode is changing: pin **only** if it does not overlap;
  otherwise let the window server slide it along the shared edge

Result over three cycles (`--arrangement-test 2`): x is constant at −347, y only
slides along the shared edge, and every cycle returns to exactly the same
position — no cumulative drift.

Separately, the window server accumulates saved configurations in
`~/Library/Preferences/ByHost/com.apple.windowserver.displays.<UUID>.plist`
under `DisplaySets.Configs` — one new entry per
`CGCompleteDisplayConfiguration(..., .permanently)`, never updating the old
ones. This machine had 13 sets for the same pair of displays with different
arrangements, which is one source of "the arrangement changed by itself". That
file is only read at login, so writing the mode and the complete arrangement in
a single commit keeps every set self-consistent.

---

## 11. "The panel opened on the wrong screen" — it followed the status item

The panel appeared on the external display, far from where it was expected. The
log shows why:

```
place: screen=2490W1 visible=(-1920,360 1920x1050)
       button=(-1045,1411 41x29) windowScreen=2490W1 panelSize=(300x640)
```

The status item *was* on the external display's menu bar. The real problem was
that the external display had been set to `960 × 540 @2x`: the menu bar is only
960 pt wide, and once the icons fill it, the new one is pushed out of the visible
area — hence "I can't see it at the top".

Positioning was still hardened: `NSStatusBarButton.window.screen` is unreliable
when each display has its own Space (every display has its own menu bar window),
so hit-test the button's rect against screens and hang the panel off
`visibleFrame.maxY` rather than the button's y.

---

## 12. `CGDisplaySetDisplayMode` does not persist, and poisons the next transaction

It is session-scoped: the mode holds while the process lives and reverts when it
exits. For a menu bar app that reads as "it doesn't remember my resolution".

What actually writes the user's display configuration is the transaction:

```swift
CGBeginDisplayConfiguration(&config)
CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
CGCompleteDisplayConfiguration(config, .permanently)
```

Worse: calling `CGDisplaySetDisplayMode` once and then completing a transaction
makes the transaction fail with `kCGErrorIllegalArgument (1001)`. That failure
looks like a permission problem, an API misuse, or a monitor refusing the mode.
It is just leftover state. `apply` no longer uses the one-shot call at all, and
retries the transaction once on failure.

---

## 13. macOS lists modes it then refuses to apply

`kCGDisplayShowDuplicateLowResolutionModes` synthesises HiDPI variants of 4:3
LoDPI modes. On the built-in display, 6 of its 20 modes are of this kind: the
valid bit is set in `ioFlags` and every application attempt returns 1001. Refused
modes are now remembered per row key and removed from both the slider and the
list.

---

## 14. The external DDC conclusion is the cable, not the code

The code path is complete and the display never answers. The reason is the
physical link (`--probe`):

```
Transport = {"Upstream"="DP", "Downstream"="HDMI"}
```

A USB-C (DP alt mode) input converted to HDMI output by an active chip. These
chips do not forward DDC/CI to the HDMI DDC line. EDID usually still passes
through, which is exactly what makes this confusing:

```
EDID channel (chip 0x50)  00 ff ff ff ff ff ff 00 05 e3 90 24 ...   <- I2C is fine
DDC/CI (chip 0x37)        constant 6e 80 be                        <- 0 of 15 replies
```

15 combinations were tried: write data address (`0x51` / `0x00` / `0x50`) ×
payload start (full frame / from length byte / from source address) × read offset
(`0x00` / `0x51`) × read length (11 / 12) × delay (50–250 ms). All fail. Quitting
every other DDC-using app to rule out bus contention changes nothing.

`6e 80 be` is DDC/CI's *empty frame*, and it is constant: changing what was
written does not change it, so it is the DCP's fixed answer for "nobody on the
bus", not the monitor talking.

Ways around it: use a USB-C → DisplayPort cable (native DP alt mode carries the
DDC sideband), check the monitor OSD for a `DDC/CI` switch, or use a converter
that documents DDC passthrough.

---

## 15. Brightness has three paths, and the panel says which one you got

| Path | Condition | Effect |
|---|---|---|
| `native` | `DisplayServices` can control it | real backlight, black stays black |
| `ddc` | DDC/CI answers | the monitor's own backlight |
| `software` | neither | gamma table scales the signal; **backlight unchanged, blacks go grey** |

In the software path the row title becomes `Brightness (software)` with an orange
note underneath. Users can see the difference, so the UI must say it.

`--software-test 2` verifies the gamma table really changed and really restores:

```
setLevel applied   yes
table delta while dimmed  0.4400
table delta after clear   0.0000
```

On exit the app always calls `CGDisplayRestoreColorSyncSettings()`, so it cannot
leave a screen dimmed.
