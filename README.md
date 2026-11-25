# StickerSend (`cricut-bt`)

> **Just want to use the app?** Download `StickerSend.dmg` from [Releases](https://github.com/ilichzuniga-git/stickersend/releases) or see [HOW-TO-RUN.md](HOW-TO-RUN.md) for the StickerSend app guide.

A native macOS app (**StickerSend**) and CLI (**cricut-bt**) for laying out sticker sheets and printing/cutting directly to a **Cricut StickerPix Print+Cut** (`CSTP401`) over Bluetooth — without Cricut Design Space.

The point is to replace the vendor app for the print-and-cut path: our own
artwork goes straight to the printer, and Design Space is not involved at all.

## Status

| Piece | State |
| --- | --- |
| Bluetooth discovery (SDP) | **Working** — Serial Port service found, RFCOMM channel read from SDP |
| RFCOMM transport | **Working** — channel opens, frames send and receive |
| App handshake (Diffie–Hellman) | **Working** — printer returns its DH parameters and accepts the session key |
| Encrypted JSON requests | **Working** — `get-prop` replies decode |
| Cut-file generation (PNG → PLT) | **Working** — contours traced, coordinates in cutter units |
| Print sheet (JPEG 1200×2100 + PLT) | **Working** — renders and pairs with the cut file |
| Print + cut job submission | **Working** — job 20 ran end to end on the machine |
| Cut orientation on the sheet | **Working** — job 19 cut every sticker upside down; fixed and confirmed on paper in job 20 |
| StickerSend GUI: library, checks, sheet editor, cut preview | **Working** — verified on screen and through `cricut-bt sheet-layout` |
| Hand-arranged layouts, rotation, outlines, border styles, backgrounds | **Built and self-tested; not yet printed** |
| Print & Cut / Check Printer from the GUI | **Not yet run on the printer** — the GUI calls the same `print` command as jobs 19–20 |

The whole pipeline now runs against real hardware. Job 19 on 2026-11-22 uploaded
489 fragments, printed for 108 s and cut for 29 s, and the printer counted it
as a completed sticker sheet (`finished_5013`), with the cartridge going from 32
prints to 31.

Job 19 also showed up the one thing a machine cannot report back: the cuts were
upside down. The printer completes the job happily either way — a cut file is a
valid closed outline no matter which way round it is — so the only evidence is
the printed sheet. That bug is fixed and pinned by a self-test.

Job 20 on 2026-11-22 re-printed the same four stickers with the fix: 487
fragments, 107.6 s of printing and 29.5 s of cutting, `job-state 9`, the
cutter's contour counter reaching all four outlines, and the cartridge going
from 31 prints to 30. The sheet is at `out/fixed-sheet.jpg` and the cut
overlay at `out/fixed-preview.png`. **Peeled and checked on paper: the cuts
land on the artwork, right way up.**

## How it works

The StickerPix is a **classic Bluetooth** device (RFCOMM / Serial Port), not BLE.

```
        ┌───────────────────┐        SDP query          ┌────────────────────┐
        │  cricut-bt (macOS) │ ───────────────────────►  │  StickerPix Print+Cut │
        │                   │   RFCOMM channel id      │                       │
        │                   │ ◄───────────────────────  │                       │
        │                   │   20-byte frames          │                       │
        └───────────────────┘   AES-ECB encrypted        └────────────────────┘
```

1. **Discovery.** SDP is queried for the Serial Port service (`0x1101`) and its
   RFCOMM channel id. The channel is *not* assumed — the printer advertises a
   different one between sessions.
2. **Handshake.** `hello` → the printer replies with its Diffie–Hellman
   generator, modulus and public value → we send back our public value plus an
   AES confirmation block → the printer answers `ok`. The AES session key is
   the **upper-case hex text** of the shared secret, NUL-padded to 16 bytes.
3. **Requests.** JSON-RPC-ish requests (`get-prop`, `combo-job`, `get-job-info`)
   are serialised, zero-padded and AES-ECB encrypted, then sent on application
   channel `0x01`. File uploads use channel `0x02` with payload type `0x02`.
4. **Job.** A `combo-job` submits a print entry and a cut entry; the printer
   assigns a job id; the PLT and JPEG are uploaded as 892-byte fragments, each
   prefixed with the job id.

### Packet framing

| Offset | Size | Meaning |
| --- | ---: | --- |
| 0 | 1 | start marker `0x7E` |
| 1–2 | 2 | fixed `64 00` |
| 3 | 1 | application channel |
| 4 | 1 | command |
| 5 | 1 | payload type (`0x03` JSON, `0x02` file data) |
| 6–9 | 4 | zero |
| 10–13 | 4 | sequence |
| 14–15 | 2 | fragment count |
| 16–17 | 2 | fragment index |
| 18–19 | 2 | payload length (low 10 bits) + flags |
| 20..n | | payload |
| n+1 | 1 | checksum: sum of bytes 1..n modulo 256 |
| n+2 | 1 | end marker `0x7E` |

Bits 10–12 of the flags hold the encryption indicator (`5` for AES); bit 13
marks a file transfer.

## Usage

```bash
swift build -c release

# What does the printer advertise?
.build/release/cricut-bt discover

# Connect, handshake, and read the printer's properties
.build/release/cricut-bt status

# Turn sticker PNGs into a printable sheet (no printer needed)
.build/release/cricut-bt sheet out.jpg out.plt "sticker.png" ["sticker2.png"]

# Draw the cut file back over the print sheet, to check the two agree
.build/release/cricut-bt preview out.jpg out.plt preview.png

# Build a sheet from a hand-arranged layout (what StickerSend saves)
.build/release/cricut-bt sheet-layout "My Sheet.stickersheet" out.jpg out.plt

# Just the cut file
.build/release/cricut-bt cut "sticker.png" out.plt

# Print and cut
.build/release/cricut-bt print out.jpg out.plt --copies 1
```

Options: `--address <MAC>` (defaults to auto-detecting a paired StickerPix), `--attempts N`,
`--timeout SECONDS`, `--copies N`.

## GUI: StickerSend

```bash
./make-app.sh && open StickerSend.app      # builds both binaries and wraps the app
./make-dmg.sh                              # packages StickerSend.app into StickerSend.dmg
```

User guide: [HOW-TO-RUN.md](HOW-TO-RUN.md). This section is how it works.

StickerSend is a SwiftUI front end. It never talks to the printer itself: it
runs `cricut-bt` as a child process (`sheet-layout`, `preview`, `status`,
`print`) and streams its output, so the print path is the one proven on jobs
19 and 20. `make-app.sh` copies both binaries into `StickerSend.app`, ad-hoc
signs it, and sets `NSBluetoothAlwaysUsageDescription`. Each rebuild changes
the signature, so macOS may ask for Bluetooth permission again. That is why
offline `cricut-bt` commands must never touch IOBluetooth: a hidden permission
prompt once hung a sheet build.

### Library and checks

The library is every PNG in `~/Documents/stickers/Finalized Stickers`, skipping
hidden files and raw `Gemini_Generated…` images. `StickerCheck.swift` runs the
checks from `MINIMAX-STICKER-PLAYBOOK.md`:
- a transparent PNG;
- a white outer border;
- one shape with no holes (each hole is an extra cut loop);
- no stray specks;
- a transparent margin;
- resolution.

Stickers are shown on the playbook's `#3366aa` check colour.

PNGs dragged in from Finder, onto the library or the sheet, are copied into
the folder first and never overwrite anything: identical files are reused, and
name clashes get " 2", " 3"… (`AppModel.copyIntoLibrary`).

### Sheet geometry

The sheet is the 96 × 170 mm design canvas with a 2 mm safe margin. With no
background, it is shown as a checkerboard and printed on white. Every
geometric decision uses the sticker's **real shape**, never its rectangle; the
user rejected box-based behaviour twice.

- **Extent** (`AppModel.extent`): the convex hull of the opaque pixels,
  rotated, grown by the outline width. Edge clamping, free-spot placement and
  arranging all use it, so a rotated frame's transparent corners may hang past
  the safe line.
- **Collisions**: every sticker's distance field (silhouette plus outline) is
  painted onto a 0.25 mm grid. Red marks appear only where two cut areas touch,
  cross, or come within 0.5 mm.
- **Packing** (`Packer.swift`): a top-down bottom-left fill over 0.5 mm
  bit-row masks of each sticker's real cut area plus half of a 1 mm gap. It
  tries 0° and ±90° only (never 180°, which would print upside down), and a
  sideways placement must beat upright by 2 mm.
  - **Auto-Arrange** keeps sizes and shrinks evenly only if needed.
  - **Fill ▸ Biggest Possible** binary-searches one uniform scale.
  - **Fill ▸ Most Copies** places round-robin copies of each distinct sticker
    at its current size.
  - **Undo Arrange** keeps the last 20 layouts.

### Outlines and border styles

Each sticker can have an outline: 0–6 mm, any colour, grown behind the
artwork. The artwork keeps its size and place. **Fill gaps** fills enclosed
holes so the sticker cuts as one shape (playbook §0.3).

`OutlineRenderer` uses an exact Euclidean distance transform on the cutter's
alpha > 128 silhouette. `sheet-layout` renders each outlined sticker into a
temporary PNG and grows its frame about the same centre. **Both the print and
the cut come from that one PNG**, so they cannot disagree. The canvas preview
runs the same code: `Sources/StickerSend/Outline.swift` is a symlink to
`Sources/CricutBT/Outline.swift`.

Styles (`OutlineStyle`): plain, scalloped, lace (scallops plus cut-out
eyelets), pinked (zigzag) and stitched (a printed dashed line). For a
decorated border:
1. A smooth base band is drawn out to `width − a`.
2. Its outer edge is traced, smoothed, and resampled by arc length.
3. The pattern is drawn along it, reaching exactly `width`.

Minimum widths: lace 4 mm, scalloped and stitched 2.5 mm, pinked 2 mm.

### Background

A colour and/or an image, locked behind the stickers. It is aspect-filled
across the whole 1200 × 2100 print raster, so it bleeds slightly past the
design canvas. It is printed but never traced, so only the stickers are cut.

### Sheet files

Saved sheets are `.stickersheet` JSON files in `~/Documents/stickers/Sheets/`.
`cricut-bt sheet-layout` reads the same file:

```json
{ "name": "Cats", "copies": 1,
  "background": { "color": "#ffe6f0", "path": "/abs/background.jpg" },
  "items": [ { "path": "/abs/Tabby Sticker.png", "x": 4, "y": 6, "width": 40, "height": 52,
               "rotation": 15,
               "outline": { "widthMM": 2, "color": "#ffffff", "fillGaps": true, "style": "scalloped" } } ] }
```

- **Units:** `x`, `y`, `width` and `height` are design millimetres with a
  top-left origin, and describe the unrotated frame.
- **Rotation:** clockwise degrees about the frame's centre.
- **Optional fields:** everything except `items` and each item's
  path/x/y/width/height, so older or hand-written sheets still open.
- **Validation:** `sheet-layout` rejects a sticker only if its opaque content
  (`contentBounds`), not its frame, leaves the sheet.
- **Portability:** sticker paths are absolute, so a moved or renamed sticker
  is dropped on open, with a note in the log.
- **Shared code:** only the layout step is new. The mm → raster mapping, the
  JPEG render and contour tracing are shared with `sheet`.

### Self-tests and test hooks

`cricut-bt selftest` pins:
- the protocol, against the mock printer;
- cut orientation;
- that a layout file reproduces the automatic placement exactly;
- that a 90° turn puts the printed pixels and the cut on the same side;
- that transparent corners may hang off the sheet but content may not;
- that a 2 mm outline moves the cut out exactly 2 mm;
- that Fill gaps turns a ring into one cut;
- that each border style stays within its width, scallops and teeth cut as
  one shape, and lace cuts its eyelets.

StickerSend has headless hooks for checking logic without the window:

```bash
.build/release/StickerSend --check *.png                         # playbook checks
.build/release/StickerSend --overlaps sheet.stickersheet         # which cut areas collide
.build/release/StickerSend --clamp-test sheet.stickersheet       # drag sticker 1 past each edge
.build/release/StickerSend --pack-test arrange|biggest|copies in.stickersheet out.stickersheet
.build/release/StickerSend --import-test <scratch dir> <files…>  # drag-and-drop copy rules
```

## Calibration

`SheetProfile` in `Sources/CricutBT/CutFile.swift` holds the coordinate
transforms. There are three coordinate systems:

* **design canvas** — 96 × 170 mm, what the artwork is laid out in;
* **print raster** — the 1200 × 2100 JPEG the printer prints;
* **cutter space** — the blade carriage's own units.

The transforms between them are **empirical measurements of one machine's
registration, not universal constants.** They were fitted from the vendor app's
own output, so if your cuts land off from the print, that profile is the first
thing to re-measure.

### Orientation

The cutter axes run opposite to the design axes, so the design coordinates are
flipped to `(96-x, 170-y)` before the transform is applied. `reverseCutterAxes`
performs that flip.

The two must not both be applied. The coefficients in `SheetProfile` are the
**raw captured ones**, and the flip is the correction on top of them, which
together reproduce the reference `stickerpix-v2` profile:

```text
cutter_X = -40.06691331923889 * y + 6961.794774992448
cutter_Y =  40.14123760037788 * x +   92.97059518186143
```

Using the corrected coefficients *and* flipping the axes cancels the correction
out and lands on the old orientation, which puts every cut 180° away from the
printed artwork. `selftest` pins the correct orientation with an asymmetric
shape, so a regression shows up immediately.

There is a second, subtler axis to get right: **the artwork and the cut have to
agree about which way is up.** The silhouette is traced from the PNG's alpha
channel, and `CGBitmapContext` keeps its rows top-down — memory row 0 is the
image's top row. An earlier version of `SheetBuilder.silhouette` flipped the
rows on the way in ("CoreGraphics draws bottom-up"), which mirrored every
sticker vertically. The cut file stayed a perfectly valid closed outline and
the printer ran the job without complaint, but every cut came out **upside
down**: the head of a portrait sticker was cut where its feet belonged, and the
caption of a sticker was sliced in half.

That is what job 19 showed. The self-test now pins it with a half-opaque test
image: the mask must have the opaque half at the top, and the traced outline
must sit in the upper half of the image.

Run `cricut-bt selftest` after changing anything in the profile.

## Layout

```
Sources/CricutBT/                 the cricut-bt command-line tool
  Crypto.swift            AES-ECB and 64-bit modular arithmetic
  Frame.swift             packet framing and parsing
  ByteChannel.swift       transport protocol (real or mock)
  BluetoothTransport.swift IOBluetooth RFCOMM transport
  PrinterSession.swift    handshake and encrypted JSON requests
  CutFile.swift           SheetProfile, silhouette extraction, contour tracing
  SheetRenderer.swift     print sheet layout, rotation, JPEG rendering, preview
  SheetLayoutFile.swift   .stickersheet reader, outline application, sheet-layout
  Outline.swift           OutlineRenderer and border styles (shared with the GUI)
  PrintSheet.swift        job parameters and upload fragments
  JobRunner.swift         job submission and progress monitoring
  MockPrinter.swift       in-memory printer for the self-test
  SelfTest.swift          selftest
  main.swift              command line

Sources/StickerSend/              the SwiftUI app
  StickerSendApp.swift    app entry, menus, headless test hooks
  AppModel.swift          library, sheet document, geometry, collisions, saving, CLI runs
  SheetDocument.swift     sheet model and .stickersheet format
  StickerCheck.swift      playbook pre-flight checks
  Packer.swift            shape-aware auto-arrange and fill
  CLIRunner.swift         runs cricut-bt and streams its output
  Views.swift             library and inspector columns
  SheetViews.swift        sheet canvas, controls, cut preview, printer, log
  Outline.swift           -> ../CricutBT/Outline.swift

make-app.sh               builds StickerSend.app
HOW-TO-RUN.md             user guide
```

## Notes on the hardware

* The printer's Bluetooth radio stays reachable for pairing even when the
  printer itself is asleep, so SDP can succeed while an RFCOMM open times out.
  If `status` reports timeouts, wake the printer and retry.
* The printer is slow to answer the first frame after a connection; the
  handshake tolerates a long wait rather than giving up.
* Killing a run mid-session can leave the printer refusing new RFCOMM channels
  for a while. `status` retries with a fresh SDP query each attempt.

## Provenance

The wire protocol is documented in the MIT-licensed
[crycut](https://github.com/vavkamil/crycut) project (an unofficial CLI for the
same printer). This project reimplements the protocol for macOS using Apple's
`IOBluetooth` framework instead of Linux BlueZ, and replaces the project and
job layer with a sticker-oriented pipeline. No Cricut code is used.
