# How to run StickerSend

StickerSend is the Mac app for laying out stickers on a sheet and sending them
to the **Cricut StickerPix Print+Cut** over Bluetooth. You don't need Design Space.

---

## 1. Open the app

Open **Terminal** and run:

```bash
cd ~/Documents/stickers/cricut-bt
./make-app.sh
open StickerSend.app
```

`make-app.sh` builds everything and creates `StickerSend.app` in that folder.
After that, you can just double-click **StickerSend.app** in Finder. You only
need to run `make-app.sh` again when the code changes.

> **First time only:** if Terminal says `swift: command not found`, install
> Apple's developer tools with `xcode-select --install`, then try again.

> **Bluetooth permission:** macOS may ask whether StickerSend can use
> Bluetooth. Click **Allow**, because the app needs it to talk to the printer.
> You may be asked again after each rebuild.

---

## 2. The window

| Left | Center | Right |
|---|---|---|
| **Library.** Every PNG in your chosen sticker folder, with warning badges and quick `+` / copy-count buttons. | **The sheet canvas.** Arrange stickers directly, use the floating Auto-Arrange / Fill / Background bar, or switch to **Cut Preview** in the toolbar. | **Contextual Inspector.** Adapts automatically between **Selected** (size, rotation, outline), **Sheet** (stickers on sheet, background, layout), and **Check** (dark-blue `#3366aa` border preview + pre-flight checks). |

The top toolbar holds the **Sheets** menu, **Save**, **Arrange / Cut Preview** toggle, **StickerPix** Bluetooth popover, **Print & Cut** popover, and an Inspector toggle button.

**Status badges** (from the MiniMax sticker playbook):

- ✅ **Ready.** Fine to print.
- ℹ️ **Note.** Usually just a resolution comment; fine to print.
- ⚠️ **Check.** It will print, but look at the warning. Examples: the border isn't white, or the margin is small.
- ⛔ **Fix first.** It will cut badly. Examples: holes that become extra cuts, or artwork touching the edge of the image. An **outline with Fill gaps** often fixes this (see step 4).

---

## 3. Make a sheet

1. **Add stickers.** Any of these work:
   - Tick the checkbox next to a sticker in the left list. It drops into the
     first free spot on the sheet.
   - **Drag a sticker from the left list onto the sheet.** It lands exactly
     where you let go.
   - **Drag PNGs from Finder onto the sheet.** They're copied into
     `Finalized Stickers` and placed where you drop them. Several at once
     fan out from that point.
   - **Drag PNGs from Finder onto the left list.** They're copied into the
     folder without being added to the sheet.

   The sheet or list shows a blue outline while you drag over it. Nothing is
   ever overwritten: a different file with the same name is saved as
   "Name 2.png", and dropping the same file again reuses it. Only PNGs are
   accepted. Give a JPG the sticker treatment first.
2. **Move.** Drag a sticker on the sheet.
3. **Resize.** Drag the round handle at its bottom-right corner, or use
   the **Size** slider. The proportions stay locked.
4. **Rotate.** Drag the blue ↻ handle above it. Hold **⇧ Shift** to snap to
   15° steps. You can also use the **Rotation** slider, or **⌘[** / **⌘]** to turn 90°.
5. **Tidy up.** **Auto-Arrange** nests the stickers by their real shapes (a
   round sticker can tuck beside a tall one) at their current sizes, and
   shrinks everything evenly only if they don't fit.
6. **Fill the sheet.** Click **Fill** next to Auto-Arrange:
   - **Biggest Possible:** scales the stickers on the sheet up together, as
     large as they'll go while all still fitting.
   - **Most Copies:** fills the sheet with as many copies of each different
     sticker as fit, at their current size, taking turns between them. Set
     the sizes first, for example with the Size slider.

   Both keep at least 1 mm between cut lines, and turn a sticker sideways
   only when that clearly saves space (never upside down). Made a mess?
   **Undo Arrange** (⌥⌘Z) goes back to the layout before.

The **dashed line** is the safe area. A sticker stops when its artwork or
border reaches it. The blue selection box may poke past the line on a rotated
sticker; that's fine, because only the box's empty corners are outside. A
**checkerboard** means no background is set. That sheet prints on plain
white paper.

**Red marks** on the sheet mean two stickers' cut lines touch or cross there,
so the blade would cut into both. Move them apart until the marks go away.

---

## 4. Outlines (thicker border, or a coloured one)

Select a sticker, then look at **Outline** in the left panel:

- **Slider:** adds 0 to 6 mm of border around the sticker. The blade cuts
  along the new outer edge.
- **Colour swatch:** any colour. White is the default and the most forgiving.
- **Style:** a preset border shape. The blade cuts the pattern exactly as it prints:

  | Style | Looks like | Notes |
  |---|---|---|
  | Plain | Smooth, even border | |
  | Scalloped | Wavy, bumpy edge | Cuts as one piece |
  | Lace | Scallops plus a ring of oval eyelet holes, like a paper doily | Each eyelet is its own small cut, so **weed the holes** after cutting. Needs at least 4 mm |
  | Pinked | Zigzag, like pinking shears | Cuts as one piece |
  | Stitched | Printed dashed "stitch" line inside a plain border | The stitch is printed, not cut |

  Picking a style widens a border that's too narrow for it (for example, Lace
  goes to 5 mm).
- **Fill gaps:** fills holes inside the sticker so it cuts as **one piece**.
  The app suggests this when a sticker has several cut loops.
- **Apply Outline to All:** copies this sticker's outline settings to every sticker on the sheet.

---

## 5. Background (optional)

In the **Background** box (🔒 locked behind the stickers):

- **Colour:** a solid colour printed across the whole sheet.
- **Choose Image…:** a picture printed edge to edge behind the stickers.

The background is **printed but never cut**. Only the stickers are cut out.
Use **Clear** or **Remove** to go back to no background.

---

## 6. Check the cut, then print

1. Click **Build Sheet & Cut Preview** (**⌘B**). The view switches to **Cut
   Preview**. The **magenta line** is where the blade will go. Check that each
   magenta line sits on its sticker's border, the right way up.
2. Make sure the printer is **on and awake**. Optionally click **Check
   Printer** to confirm it connects.
3. Set **Copies** (1–36).
4. Click **Print & Cut** and confirm. Each copy uses one print from the
   cartridge. Progress (upload, printing, cutting) appears under the button.

> **Not yet tried on the printer:** printing straight from the app,
> rotated stickers, outlines and border styles (especially Lace's small
> eyelet holes), and background images. The underlying print path is the one
> that has printed real sheets. For your first run, print a small test sheet
> and check the cuts before printing several copies.

**Don't quit the app while a job is running.** Interrupting it can make the
printer refuse connections for a while.

To see the exact files sent to the printer, click **Show Files**. They're in
`~/Library/Application Support/StickerSend/`.

---

## 7. Save and reopen sheets

- **Save:** ⌘S, or the save button (↓ in a tray) at the top of the sheet. The first save asks for a name.
- **Save As:** ⇧⌘S.
- **Open:** ⌘O, or pick one from the **Sheets** menu.
- **New:** ⌘N.

Sheets are saved in `~/Documents/stickers/Sheets/` as `.stickersheet` files.
They remember positions, sizes, rotation, outlines, background and copies. A
dot next to the sheet name means there are unsaved changes, and **closing the
app loses them**, so save first.

If you rename or move a sticker PNG later, it's dropped from saved sheets that
use it. A note appears in the log at the bottom of the window.

**Restarting or quitting StickerSend loses unsaved changes**, including
updates when the app is rebuilt, so save first.

---

## Keyboard shortcuts

| Action | Keys |
|---|---|
| New / Open / Save / Save As | ⌘N / ⌘O / ⌘S / ⇧⌘S |
| Build sheet & cut preview | ⌘B |
| Duplicate selected sticker | ⌘D |
| Remove selected sticker | ⌘⌫ |
| Rotate 90° left / right | ⌘[ / ⌘] |
| Auto-Arrange | ⌥⌘A |
| Undo last arrange / fill | ⌥⌘Z |
| Rescan the sticker folder | ⌘R |
| Choose a different sticker folder | ⇧⌘O |

---

## Troubleshooting

| Problem | Fix |
|---|---|
| A new sticker doesn't appear | Press **⌘R** to rescan, or just drag the PNG onto the app. It must be a `.png`. |
| "Check Printer" times out | Wake the printer (press its button) and try again. Its Bluetooth answers even while it's asleep, but it won't start a session until it's awake. |
| Printer refuses to connect after an interrupted job | Wait a minute, or power-cycle the printer. |
| Cuts land off the printed artwork | Stop, and don't print more. The printer calibration (`SheetProfile` in `Sources/CricutBT/CutFile.swift`) needs re-measuring. |
| Window too big for the screen | Click the green button in the window's top-left corner to fit it to the screen. |
| App seems stuck building | A hidden macOS permission prompt may be waiting. Check for it, click **Allow**, and try again. |

---

## Command line (optional)

Everything the app does is also available in Terminal:

```bash
cd ~/Documents/stickers/cricut-bt
.build/release/cricut-bt status                                   # connect and show printer info
.build/release/cricut-bt sheet-layout "My Sheet.stickersheet" out.jpg out.plt
.build/release/cricut-bt preview out.jpg out.plt preview.png      # draw the cut over the print
.build/release/cricut-bt print out.jpg out.plt --copies 1
.build/release/cricut-bt selftest                                 # run the built-in checks
.build/release/StickerSend --check ../"Finalized Stickers"/*.png  # sticker checks, no window
```

For how it works inside (Bluetooth protocol, calibration, file format), see
[README.md](README.md).
