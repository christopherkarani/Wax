#!/usr/bin/env python3
"""Generate the North Harbor demo corpus: 10 photos, 10 videos, 10 files."""

from __future__ import annotations

import json
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
IMAGE_DIR = ROOT / "images"
VIDEO_DIR = ROOT / "videos"
FILE_DIR = ROOT / "files"
TRANSCRIPT_DIR = ROOT / "transcripts"

FONT_DIR = Path("/System/Library/Fonts")
SUPP = FONT_DIR / "Supplemental"


def font(path: Path, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(path), size=size, index=index)


def f_georgia(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    name = "Georgia Bold.ttf" if bold else "Georgia.ttf"
    return font(SUPP / name, size)


def f_courier(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    name = "Courier New Bold.ttf" if bold else "Courier New.ttf"
    return font(SUPP / name, size)


def f_helvetica(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return font(FONT_DIR / "HelveticaNeue.ttc", size, index=1 if bold else 0)


def f_menlo(size: int) -> ImageFont.FreeTypeFont:
    return font(FONT_DIR / "Menlo.ttc", size)


def f_marker(size: int) -> ImageFont.FreeTypeFont:
    return font(FONT_DIR / "MarkerFelt.ttc", size)


def f_note(size: int) -> ImageFont.FreeTypeFont:
    return font(FONT_DIR / "Noteworthy.ttc", size)


def f_sf(size: int) -> ImageFont.FreeTypeFont:
    return font(FONT_DIR / "SFNS.ttf", size)


@dataclass(frozen=True)
class PhotoSpec:
    filename: str
    title: str
    tokens: tuple[str, ...]
    renderer: str


@dataclass(frozen=True)
class FileSpec:
    filename: str
    kind: str
    title: str
    tokens: tuple[str, ...]
    body: str


@dataclass(frozen=True)
class VideoSpec:
    filename: str
    title: str
    spoken: str
    tokens: tuple[str, ...]
    card_color: tuple[int, int, int]
    still: str


@dataclass(frozen=True)
class DemoBeat:
    surface: str
    query: str
    why: str
    expect: tuple[str, ...]


PHOTOS = (
    PhotoSpec("01-whiteboard-ship-friday.png", "Harbor whiteboard", ("ship Friday", "North Harbor", "Offline only"), "whiteboard"),
    PhotoSpec("02-nameplate-serial.png", "Bench radio nameplate", ("WAX-HB-4419", "Harbor Workshop"), "nameplate"),
    PhotoSpec("03-receipt-cedar-loft.png", "Cedar Loft receipt", ("Fog Latte", "Cedar Loft"), "receipt"),
    PhotoSpec("04-sticky-dock-code.png", "Dock-code sticky", ("NH-19", "Harbor Workshop"), "sticky"),
    PhotoSpec("05-shipping-label.png", "ANE-7 shipping label", ("PO-NH-8821", "ANE-7"), "shipping"),
    PhotoSpec("06-minilm-error.png", "MiniLM load error", ("harbor-week.wax", "MiniLM"), "terminal"),
    PhotoSpec("07-calendar-hn-tape.png", "HN tape calendar card", ("Record HN tape", "Fri Aug 15"), "calendar"),
    PhotoSpec("08-card-mira-chen.png", "Mira Chen card", ("Mira Chen", "northharbor.dev"), "bizcard"),
    PhotoSpec("09-packing-slip.png", "Packing slip", ("LOT NH-17", "ANE-7"), "packing"),
    PhotoSpec("10-lab-notebook.png", "Lab notebook", ("Recall 50ms", "vector ON"), "notebook"),
)

FILES_SPEC = (
    FileSpec(
        "01-offline-policy.md",
        "markdown",
        "North Harbor offline policy",
        ("offline-only", "harbor-week.wax", "no cloud index"),
        """# North Harbor offline policy

Status: locked for Harbor week.

Wax stays **offline-only**. There is no cloud index and no remote embedder.

- The week lives in one local store: `harbor-week.wax`
- Photos, files, and clips are ingested from disk on this Mac
- Embeddings never leave the machine
- If Apple Intelligence is off, recall still works; answers degrade honestly

How we keep memory on the device: the store is a single local `.wax` file.
Nothing is uploaded.
""",
    ),
    FileSpec(
        "02-standup-2026-08-12.md",
        "markdown",
        "Standup 12 Aug",
        ("ship Friday", "Mira Chen", "WAX-HB-4419"),
        """# Standup — 12 Aug 2026

Attendees: Mira Chen, bench.

- We **ship Friday**. Record the HN tape at 4:00 PM.
- Photo beat: search the camera roll for `WAX-HB-4419` on the bench radio.
- File beat: drop this note plus the Cedar Loft invoice.
- Video beat: the whiteboard walkthrough says the same ship-Friday line.
- Mira owns the grounded-answer footer. If Foundation Models is cold, show
  photo hits only.

Dock code for the loft is **NH-19**. Do not put a guest network password
in the tape.
""",
    ),
    FileSpec(
        "03-architecture-harbor.md",
        "markdown",
        "Harbor retrieval architecture",
        ("MiniLM", "Hybrid search", "Photo RAG"),
        """# Harbor retrieval architecture

Four surfaces, one local store.

| Surface | Ingest | Query that should land |
| --- | --- | --- |
| Vector search | markdown + PDF text | "how do we keep memory on the device" |
| File RAG | UTF-8 notes + PDFKit text | "offline policy", "Fog Latte" |
| Photo RAG | local images + Vision OCR | `WAX-HB-4419`, `PO-NH-8821` |
| Video RAG | mp4 + host transcripts | "ship Friday", "bench radio serial" |

Hybrid search blends MiniLM vectors with BM25. Identifier-like queries
(serials, PO numbers) must stay factual so the unique token wins.

Photo RAG and Video RAG are package APIs used by the example app. File
ingest is `remember(fileAt:)` for markdown and `remember(pdfAt:)` for PDFs.
""",
    ),
    FileSpec(
        "04-changelog-harbor.md",
        "markdown",
        "Harbor week changelog",
        ("on-device retrieval", "paraphrase", "harbor-week.wax"),
        """# Changelog — Harbor week

## Why this corpus exists

StressLab serial plates prove OCR. They look like a test harness on camera.
This set is a single week of workshop artifacts so the tape can show
on-device retrieval against notes, photos, and clips a person would drop.

## Retrieval notes

Ask a paraphrase, not the filename. "How do we keep memory on the device"
should surface this changelog, the offline policy, and the voice memo —
none of those documents repeat the query verbatim.

Exact tokens still matter for the identifier beats: `WAX-HB-4419`,
`PO-NH-8821`, `LOT NH-17`. The week store is `harbor-week.wax`.
""",
    ),
    FileSpec(
        "05-demo-queries.md",
        "markdown",
        "Harbor demo queries",
        ("Record HN tape", "Fog Latte", "ANE-7"),
        """# Harbor demo queries

Use these in order. Each line is a different surface.

1. Photo RAG — `WAX-HB-4419`
2. Photo RAG — `Fog Latte`
3. File RAG — `what is the offline policy`
4. File RAG — `PO-NH-8821`
5. Video RAG — `when do we ship`
6. Video RAG — `bench radio serial`
7. Vector — `how do we keep memory on the device`
8. Cross — `Mira Chen`
9. Cross — `ANE-7 cooling plate`
10. Close — `harbor-week.wax`

Record HN tape on Friday after ingest. Do not open a browser.
""",
    ),
    FileSpec(
        "06-loft-access.md",
        "markdown",
        "Loft access",
        ("NH-19", "Cedar Loft", "North Harbor"),
        """# Loft access — North Harbor

Harbor Workshop sits above Cedar Loft.

- Dock code: **NH-19**
- Bench radio lives on the left shelf; nameplate reads `WAX-HB-4419`
- Coffee run is a Fog Latte; keep the receipt, it is a photo-RAG beat
- Shipping for the ANE-7 cooling plate uses `PO-NH-8821`

This note is boring on purpose. File RAG should still find "dock code"
and "NH-19" from a human query.
""",
    ),
    FileSpec(
        "07-invoice-cedar-loft.pdf",
        "pdf",
        "Cedar Loft invoice",
        ("Fog Latte", "Cedar Loft", "INV-CL-640"),
        "Cedar Loft Coffee\nNorth Harbor\n\nInvoice INV-CL-640\n12 Aug 2026\n\nFog Latte                    6.40\nOat                         0.80\n-------------------------------\nTotal                       7.20\n\nPaid at the loft. Keep the receipt with the week notes.",
    ),
    FileSpec(
        "08-po-nh-8821.pdf",
        "pdf",
        "Purchase order NH-8821",
        ("PO-NH-8821", "ANE-7", "Harbor Workshop"),
        "HARBOR WORKSHOP\nPurchase Order\n\nPO-NH-8821\nVendor: ANE Fixture Co.\nShip to: Harbor Workshop, North Harbor\n\n1 x ANE-7 cooling plate\nLOT NH-17\nNeeded before Friday tape.\n\nReceiving note: leave the plate on the left bench.",
    ),
    FileSpec(
        "09-nameplate-spec.pdf",
        "pdf",
        "Nameplate spec",
        ("WAX-HB-4419", "Harbor Workshop", "bench radio"),
        "NAMEPLATE SPEC\nHarbor Workshop\n\nAsset: Bench radio\nSerial: WAX-HB-4419\nFinish: brushed aluminum\nEngraving: 18pt gothic\n\nEngrave the serial as its own line. Do not write WAXHB4419.\nThe bench radio serial is WAX-HB-4419.",
    ),
    FileSpec(
        "10-harbor-week-report.pdf",
        "pdf",
        "Harbor week report",
        ("harbor-week.wax", "ship Friday", "on-device"),
        "NORTH HARBOR WEEK REPORT\n10-15 Aug 2026\n\nGoal: record four retrieval states from one local store.\nStore: harbor-week.wax\nShip Friday. Stay on-device.\n\nEvidence that must survive ingest:\n- Whiteboard: ship Friday / Offline only\n- Nameplate: WAX-HB-4419\n- Receipt + invoice: Fog Latte at Cedar Loft\n- Label + PO: ANE-7 / PO-NH-8821\n- Sticky + loft note: dock code NH-19\n- Card + standup: Mira Chen\n\nParaphrase query for vector search:\nHow do we keep memory on the device?",
    ),
)

VIDEO_SPECS = (
    VideoSpec(
        "01-standup-ship-friday.mp4",
        "Standup",
        "We ship Friday. Stay offline. No cloud index.",
        ("ship Friday", "offline"),
        (28, 42, 58),
        "01-whiteboard-ship-friday.png",
    ),
    VideoSpec(
        "02-bench-serial.mp4",
        "Bench radio",
        "The bench radio serial is WAX-HB-4419. Harbor Workshop, left shelf.",
        ("WAX-HB-4419", "Harbor Workshop"),
        (62, 58, 48),
        "02-nameplate-serial.png",
    ),
    VideoSpec(
        "03-voice-memo-offline.mp4",
        "Voice memo",
        "All recall stays on this Mac. The store is one local file, harbor-week.wax. Nothing is uploaded.",
        ("harbor-week.wax", "Nothing is uploaded"),
        (36, 52, 48),
        "06-minilm-error.png",
    ),
    VideoSpec(
        "04-whiteboard-walkthrough.mp4",
        "Whiteboard",
        "Board says ship Friday, offline only, North Harbor. That is the photo beat and this clip.",
        ("ship Friday", "North Harbor"),
        (48, 40, 32),
        "01-whiteboard-ship-friday.png",
    ),
    VideoSpec(
        "05-unbox-cooling-plate.mp4",
        "Unbox",
        "Purchase order PO-NH-8821. The ANE-7 cooling plate arrived. Lot NH-17.",
        ("PO-NH-8821", "ANE-7"),
        (70, 48, 32),
        "05-shipping-label.png",
    ),
    VideoSpec(
        "06-coffee-run.mp4",
        "Coffee run",
        "Cedar Loft, the usual Fog Latte. Keep the receipt for photo RAG.",
        ("Cedar Loft", "Fog Latte"),
        (92, 72, 52),
        "03-receipt-cedar-loft.png",
    ),
    VideoSpec(
        "07-hn-rehearsal.mp4",
        "HN rehearsal",
        "Search the camera roll for the serial, then ask Foundation Models. Record HN tape Friday at four.",
        ("Record HN tape", "serial"),
        (40, 36, 64),
        "07-calendar-hn-tape.png",
    ),
    VideoSpec(
        "08-paraphrase-test.mp4",
        "Paraphrase",
        "Ask how we keep memory on the device. Do not use the filename. Vector search should still land.",
        ("keep memory on the device", "Vector search"),
        (32, 56, 64),
        "10-lab-notebook.png",
    ),
    VideoSpec(
        "09-file-drop.mp4",
        "File drop",
        "Drop the markdown notes and the invoice PDF. File RAG should find Fog Latte and the offline policy.",
        ("invoice PDF", "offline policy"),
        (48, 44, 40),
        "03-receipt-cedar-loft.png",
    ),
    VideoSpec(
        "10-close-flush.mp4",
        "Flush",
        "Flush the store. Harbor week is in harbor-week.wax. Mira Chen signs the report.",
        ("harbor-week.wax", "Mira Chen"),
        (24, 32, 40),
        "08-card-mira-chen.png",
    ),
)

BEATS = (
    DemoBeat("photo", "WAX-HB-4419", "OCR serial on the nameplate", ("02-nameplate-serial.png", "09-nameplate-spec.pdf", "02-bench-serial.mp4")),
    DemoBeat("photo", "Fog Latte", "Receipt OCR plus invoice text", ("03-receipt-cedar-loft.png", "07-invoice-cedar-loft.pdf", "06-coffee-run.mp4")),
    DemoBeat("photo", "PO-NH-8821", "Shipping label and purchase order", ("05-shipping-label.png", "08-po-nh-8821.pdf", "05-unbox-cooling-plate.mp4")),
    DemoBeat("file", "what is the offline policy", "Markdown file RAG", ("01-offline-policy.md", "10-harbor-week-report.pdf", "03-voice-memo-offline.mp4")),
    DemoBeat("file", "Mira Chen", "Card + standup note", ("08-card-mira-chen.png", "02-standup-2026-08-12.md", "10-close-flush.mp4")),
    DemoBeat("video", "when do we ship", "Transcript: ship Friday", ("01-standup-ship-friday.mp4", "04-whiteboard-walkthrough.mp4", "02-standup-2026-08-12.md")),
    DemoBeat("video", "bench radio serial", "Spoken WAX-HB-4419", ("02-bench-serial.mp4", "09-nameplate-spec.pdf")),
    DemoBeat("vector", "how do we keep memory on the device", "Paraphrase, not a filename", ("01-offline-policy.md", "04-changelog-harbor.md", "03-voice-memo-offline.mp4", "08-paraphrase-test.mp4")),
    DemoBeat("cross", "ANE-7 cooling plate", "Photo + PDF + video", ("05-shipping-label.png", "08-po-nh-8821.pdf", "05-unbox-cooling-plate.mp4")),
    DemoBeat("close", "harbor-week.wax", "Store name across surfaces", ("06-minilm-error.png", "01-offline-policy.md", "10-close-flush.mp4")),
)


def paper(size: tuple[int, int], base: tuple[int, int, int], seed: int) -> Image.Image:
    rng = random.Random(seed)
    img = Image.new("RGB", size, base)
    px = img.load()
    w, h = size
    for _ in range(w * h // 18):
        x, y = rng.randrange(w), rng.randrange(h)
        d = rng.randint(-14, 14)
        r, g, b = px[x, y]
        px[x, y] = (max(0, min(255, r + d)), max(0, min(255, g + d)), max(0, min(255, b + d)))
    return img


def vignette(img: Image.Image, strength: float = 0.28) -> Image.Image:
    w, h = img.size
    overlay = Image.new("RGB", img.size, (20, 16, 12))
    mask = Image.new("L", img.size, 0)
    m = mask.load()
    cx, cy = w / 2, h / 2
    max_d = math.hypot(cx, cy)
    for y in range(h):
        for x in range(w):
            t = math.hypot(x - cx, y - cy) / max_d
            m[x, y] = int(255 * strength * max(0.0, t - 0.35) / 0.65)
    return Image.composite(overlay, img, mask)


def desk(size: tuple[int, int], color: tuple[int, int, int], seed: int) -> Image.Image:
    img = paper(size, color, seed)
    draw = ImageDraw.Draw(img)
    rng = random.Random(seed + 3)
    for i in range(18):
        y = rng.randint(0, size[1] - 1)
        c = 20 + rng.randint(0, 18)
        draw.line((0, y, size[0], y + rng.randint(-8, 8)), fill=(c, c - 4, c - 8), width=1)
    return vignette(img, 0.22)


def shadow_paste(base: Image.Image, artifact: Image.Image, xy: tuple[int, int], angle: float = -3.0) -> None:
    rot = artifact.convert("RGBA").rotate(angle, expand=True, resample=Image.Resampling.BICUBIC)
    shadow = Image.new("RGBA", (rot.size[0] + 40, rot.size[1] + 40), (0, 0, 0, 0))
    sh = Image.new("RGBA", rot.size, (0, 0, 0, 90))
    shadow.paste(sh, (18, 22), rot.split()[-1])
    shadow = shadow.filter(ImageFilter.GaussianBlur(16))
    base.paste(shadow, (xy[0] - 10, xy[1] - 6), shadow)
    base.paste(rot, xy, rot)


def render_whiteboard() -> Image.Image:
    canvas = desk((1600, 1200), (92, 74, 58), 11)
    board = paper((1180, 860), (236, 230, 214), 12)
    d = ImageDraw.Draw(board)
    d.rectangle((18, 18, 1161, 841), outline=(48, 42, 36), width=10)
    d.rectangle((36, 36, 1143, 823), outline=(210, 204, 188), width=2)
    d.text((80, 70), "NORTH HARBOR", font=f_marker(42), fill=(40, 62, 88))
    d.text((80, 160), "SHIP FRIDAY", font=f_marker(120), fill=(28, 38, 58))
    d.text((80, 320), "Offline only", font=f_marker(72), fill=(140, 42, 36))
    d.text((80, 430), "No cloud index", font=f_marker(64), fill=(48, 48, 48))
    d.line((80, 540, 720, 548), fill=(40, 62, 88), width=4)
    d.text((80, 580), "Serial WAX-HB-4419", font=f_marker(48), fill=(36, 56, 48))
    d.text((80, 660), "Tape 4:00 PM  ·  Fri Aug 15", font=f_marker(40), fill=(70, 64, 56))
    shadow_paste(canvas, board, (170, 140), -2.4)
    return canvas


def render_nameplate() -> Image.Image:
    canvas = desk((1600, 1200), (64, 52, 40), 21)
    plate = Image.new("RGB", (980, 420), (168, 168, 162))
    d = ImageDraw.Draw(plate)
    for y in range(420):
        shade = 150 + int(18 * math.sin(y / 9))
        d.line((0, y, 980, y), fill=(shade, shade - 2, shade - 8))
    d.rectangle((16, 16, 963, 403), outline=(90, 90, 84), width=6)
    d.rectangle((28, 28, 951, 391), outline=(210, 210, 200), width=2)
    d.text((60, 50), "HARBOR WORKSHOP", font=f_helvetica(28, True), fill=(40, 40, 36))
    d.text((60, 100), "BENCH RADIO", font=f_helvetica(22), fill=(56, 56, 50))
    d.text((60, 170), "WAX-HB-4419", font=f_helvetica(84, True), fill=(24, 24, 20))
    d.text((60, 300), "LEFT SHELF  ·  DO NOT RELOCATE", font=f_helvetica(22), fill=(48, 48, 42))
    shadow_paste(canvas, plate, (280, 360), 1.8)
    return canvas


def render_receipt() -> Image.Image:
    canvas = desk((1200, 1600), (118, 96, 78), 31)
    slip = paper((620, 980), (232, 228, 214), 32)
    d = ImageDraw.Draw(slip)
    d.text((40, 36), "CEDAR LOFT", font=f_courier(36, True), fill=(28, 28, 28))
    d.text((40, 84), "North Harbor", font=f_courier(22), fill=(50, 50, 50))
    d.text((40, 130), "12 Aug 2026  09:14", font=f_courier(20), fill=(50, 50, 50))
    d.line((40, 170, 580, 170), fill=(40, 40, 40), width=2)
    d.text((40, 200), "Fog Latte              6.40", font=f_courier(24), fill=(24, 24, 24))
    d.text((40, 240), "Oat                    0.80", font=f_courier(24), fill=(24, 24, 24))
    d.line((40, 290, 580, 290), fill=(40, 40, 40), width=2)
    d.text((40, 320), "TOTAL                  7.20", font=f_courier(26, True), fill=(16, 16, 16))
    d.text((40, 390), "INV-CL-640", font=f_courier(22, True), fill=(16, 16, 16))
    d.text((40, 440), "Card ending 4419", font=f_courier(20), fill=(60, 60, 60))
    d.text((40, 520), "Thanks for visiting.", font=f_courier(18), fill=(70, 70, 70))
    d.text((40, 560), "cedarloft.northharbor", font=f_courier(18), fill=(70, 70, 70))
    for y in range(900, 970, 8):
        d.line((20, y, 600, y + 4), fill=(200, 196, 184), width=1)
    shadow_paste(canvas, slip, (280, 240), -4.2)
    return canvas


def render_sticky() -> Image.Image:
    canvas = desk((1600, 1200), (42, 46, 52), 41)
    laptop = paper((1100, 720), (28, 30, 34), 42)
    ld = ImageDraw.Draw(laptop)
    ld.rounded_rectangle((40, 36, 1060, 680), radius=18, fill=(18, 20, 24), outline=(70, 74, 80), width=3)
    ld.text((70, 70), "harbor-week.wax", font=f_menlo(28), fill=(160, 200, 170))
    note = paper((420, 420), (248, 220, 86), 43)
    nd = ImageDraw.Draw(note)
    nd.text((28, 30), "Dock code", font=f_note(36), fill=(50, 40, 20))
    nd.text((28, 120), "NH-19", font=f_note(96), fill=(40, 28, 16))
    nd.text((28, 260), "Harbor Workshop", font=f_note(32), fill=(60, 44, 24))
    nd.text((28, 320), "left stair", font=f_note(28), fill=(70, 52, 28))
    canvas.paste(laptop, (250, 220))
    shadow_paste(canvas, note, (980, 160), 6.5)
    return canvas


def render_shipping() -> Image.Image:
    canvas = desk((1600, 1200), (86, 70, 52), 51)
    box = paper((1040, 720), (196, 156, 88), 52)
    bd = ImageDraw.Draw(box)
    bd.rectangle((0, 0, 1039, 719), outline=(120, 88, 40), width=8)
    label = paper((720, 420), (250, 250, 246), 53)
    d = ImageDraw.Draw(label)
    d.rectangle((0, 0, 719, 419), outline=(20, 20, 20), width=4)
    d.rectangle((0, 0, 719, 70), fill=(20, 20, 20))
    d.text((24, 18), "HARBOR WORKSHOP  ·  RECEIVING", font=f_helvetica(24, True), fill=(250, 250, 250))
    d.text((24, 92), "PO-NH-8821", font=f_helvetica(52, True), fill=(16, 16, 16))
    d.text((24, 170), "ANE-7 cooling plate", font=f_helvetica(34, True), fill=(24, 24, 24))
    d.text((24, 230), "LOT NH-17", font=f_helvetica(28), fill=(32, 32, 32))
    d.text((24, 280), "Ship to: North Harbor loft", font=f_helvetica(22), fill=(48, 48, 48))
    for i in range(18):
        d.rectangle((24 + i * 28, 340, 40 + i * 28, 390), fill=(10, 10, 10))
    box.paste(label, (160, 150))
    shadow_paste(canvas, box, (260, 210), -1.6)
    return canvas


def render_terminal() -> Image.Image:
    canvas = desk((1600, 1200), (30, 32, 36), 61)
    screen = Image.new("RGB", (1280, 820), (16, 18, 22))
    d = ImageDraw.Draw(screen)
    d.rectangle((0, 0, 1279, 819), outline=(70, 74, 80), width=4)
    d.rectangle((0, 0, 1279, 48), fill=(40, 42, 48))
    d.text((20, 12), "wax-demo — MiniLM", font=f_sf(22), fill=(220, 220, 224))
    lines = [
        ("$ wax ingest --store harbor-week.wax", (180, 190, 180)),
        ("opening harbor-week.wax", (140, 150, 140)),
        ("embedder: MiniLM 384", (140, 150, 140)),
        ("ERROR  MiniLM load failed", (232, 96, 88)),
        ("store: harbor-week.wax", (232, 168, 96)),
        ("hint: retry after WaxPrewarm.miniLM()", (160, 168, 176)),
        ("recall still available (text-only)", (120, 180, 150)),
    ]
    y = 90
    for text, color in lines:
        d.text((36, y), text, font=f_menlo(28), fill=color)
        y += 52
    shadow_paste(canvas, screen, (150, 170), 0.4)
    return canvas


def render_calendar() -> Image.Image:
    canvas = desk((1600, 1200), (110, 92, 74), 71)
    card = paper((720, 860), (248, 244, 236), 72)
    d = ImageDraw.Draw(card)
    d.rectangle((0, 0, 719, 160), fill=(156, 48, 42))
    d.text((40, 28), "AUGUST", font=f_helvetica(28, True), fill=(250, 236, 230))
    d.text((40, 68), "15", font=f_helvetica(72, True), fill=(255, 255, 255))
    d.text((40, 200), "FRI", font=f_helvetica(28, True), fill=(156, 48, 42))
    d.text((40, 260), "Record HN tape", font=f_georgia(44, True), fill=(28, 24, 20))
    d.text((40, 340), "4:00 PM", font=f_georgia(36), fill=(40, 36, 32))
    d.text((40, 420), "Harbor Workshop", font=f_georgia(28), fill=(60, 52, 44))
    d.line((40, 500, 660, 500), fill=(200, 188, 176), width=2)
    d.text((40, 540), "Search WAX-HB-4419 first.", font=f_georgia(24), fill=(50, 44, 38))
    d.text((40, 590), "Stay offline.", font=f_georgia(24), fill=(50, 44, 38))
    d.text((40, 680), "Fri Aug 15  ·  North Harbor", font=f_helvetica(20), fill=(90, 80, 70))
    shadow_paste(canvas, card, (440, 140), -3.8)
    return canvas


def render_bizcard() -> Image.Image:
    canvas = desk((1600, 1200), (72, 64, 56), 81)
    card = Image.new("RGB", (920, 520), (20, 32, 44))
    d = ImageDraw.Draw(card)
    d.rectangle((0, 0, 919, 519), outline=(200, 184, 150), width=3)
    d.text((48, 50), "HARBOR WORKSHOP", font=f_helvetica(20), fill=(200, 184, 150))
    d.text((48, 140), "Mira Chen", font=f_georgia(64, True), fill=(244, 240, 232))
    d.text((48, 240), "Workshop lead", font=f_georgia(26), fill=(210, 200, 180))
    d.line((48, 310, 400, 310), fill=(200, 184, 150), width=2)
    d.text((48, 340), "mira@northharbor.dev", font=f_helvetica(24), fill=(230, 224, 210))
    d.text((48, 390), "North Harbor  ·  dock NH-19", font=f_helvetica(22), fill=(180, 172, 158))
    shadow_paste(canvas, card, (340, 300), 2.6)
    return canvas


def render_packing() -> Image.Image:
    canvas = desk((1600, 1200), (96, 88, 78), 91)
    form = paper((1040, 780), (244, 242, 234), 92)
    d = ImageDraw.Draw(form)
    d.rectangle((0, 0, 1039, 779), outline=(40, 40, 40), width=3)
    d.text((36, 24), "PACKING SLIP", font=f_helvetica(36, True), fill=(20, 20, 20))
    d.text((36, 80), "Harbor Workshop receiving", font=f_helvetica(22), fill=(60, 60, 60))
    d.line((36, 120, 1000, 120), fill=(20, 20, 20), width=2)
    rows = [
        ("PO", "PO-NH-8821"),
        ("Lot", "LOT NH-17"),
        ("Item", "ANE-7 cooling plate"),
        ("Qty", "1"),
        ("Dest", "North Harbor loft"),
        ("Note", "Needed before Friday tape"),
    ]
    y = 160
    for k, v in rows:
        d.text((48, y), k, font=f_helvetica(24, True), fill=(40, 40, 40))
        d.text((280, y), v, font=f_helvetica(24), fill=(20, 20, 20))
        y += 70
    shadow_paste(canvas, form, (260, 180), 1.2)
    return canvas


def render_notebook() -> Image.Image:
    canvas = desk((1600, 1200), (58, 48, 40), 101)
    page = paper((860, 1040), (242, 234, 214), 102)
    d = ImageDraw.Draw(page)
    d.rectangle((70, 0, 76, 1040), fill=(196, 80, 80))
    for y in range(90, 1020, 44):
        d.line((90, y, 820, y), fill=(190, 198, 210), width=2)
    d.text((100, 50), "Harbor lab  ·  13 Aug", font=f_note(36), fill=(36, 56, 92))
    d.text((100, 140), "Recall 50ms", font=f_note(56), fill=(28, 44, 80))
    d.text((100, 230), "vector ON", font=f_note(56), fill=(28, 44, 80))
    d.text((100, 320), "MiniLM warm", font=f_note(48), fill=(36, 52, 88))
    d.text((100, 420), "remember:", font=f_note(36), fill=(50, 44, 36))
    d.text((100, 490), "keep memory", font=f_note(48), fill=(28, 44, 80))
    d.text((100, 560), "on the device", font=f_note(48), fill=(28, 44, 80))
    d.text((100, 680), "store harbor-week.wax", font=f_note(36), fill=(60, 48, 36))
    shadow_paste(canvas, page, (380, 60), -2.0)
    return canvas


RENDERERS = {
    "whiteboard": render_whiteboard,
    "nameplate": render_nameplate,
    "receipt": render_receipt,
    "sticky": render_sticky,
    "shipping": render_shipping,
    "terminal": render_terminal,
    "calendar": render_calendar,
    "bizcard": render_bizcard,
    "packing": render_packing,
    "notebook": render_notebook,
}


def pdf_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def write_pdf(path: Path, title: str, body: str) -> None:
    lines = [title.upper(), ""] + body.splitlines()
    content_ops = ["BT", "/F1 11 Tf", "50 742 Td", "16 TL"]
    content_ops.append(f"({pdf_escape(lines[0])}) Tj")
    for line in lines[1:]:
        content_ops.append("T*")
        content_ops.append(f"({pdf_escape(line)}) Tj")
    content_ops.append("ET")
    stream = "\n".join(content_ops).encode("latin-1", "replace")
    objects = []

    def add(obj: bytes) -> int:
        objects.append(obj)
        return len(objects)

    add(b"<< /Type /Catalog /Pages 2 0 R >>")
    add(b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    add(
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"
    )
    add(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
    add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

    out = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for i, obj in enumerate(objects, start=1):
        offsets.append(len(out))
        out.extend(f"{i} 0 obj\n".encode())
        out.extend(obj)
        out.extend(b"\nendobj\n")
    xref = len(out)
    out.extend(f"xref\n0 {len(objects) + 1}\n".encode())
    out.extend(b"0000000000 65535 f \n")
    for off in offsets[1:]:
        out.extend(f"{off:010d} 00000 n \n".encode())
    out.extend(
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    )
    path.write_bytes(out)


def write_files() -> None:
    FILE_DIR.mkdir(parents=True, exist_ok=True)
    for spec in FILES_SPEC:
        dest = FILE_DIR / spec.filename
        if spec.kind == "markdown":
            dest.write_text(spec.body.lstrip() + "\n", encoding="utf-8")
        else:
            write_pdf(dest, spec.title, spec.body)


def write_images() -> None:
    IMAGE_DIR.mkdir(parents=True, exist_ok=True)
    for spec in PHOTOS:
        img = RENDERERS[spec.renderer]()
        img = ImageEnhance.Contrast(img).enhance(1.04)
        img = ImageEnhance.Color(img).enhance(0.96)
        dest = IMAGE_DIR / spec.filename
        img.save(dest, format="PNG", optimize=True)


def which_voice() -> str:
    listed = subprocess.check_output(["say", "-v", "?"], text=True, stderr=subprocess.STDOUT)
    for candidate in ("Samantha", "Reed (English (US))", "Daniel", "Fred"):
        if candidate.split(" (")[0] in listed:
            return candidate
    return "Samantha"


def write_videos() -> None:
    VIDEO_DIR.mkdir(parents=True, exist_ok=True)
    TRANSCRIPT_DIR.mkdir(parents=True, exist_ok=True)
    voice = which_voice()
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("ffmpeg is required to build the demo videos")

    for spec in VIDEO_SPECS:
        still = IMAGE_DIR / spec.still
        if not still.exists():
            raise SystemExit(f"missing still for {spec.filename}: {still}")
        dest = VIDEO_DIR / spec.filename
        with tempfile.TemporaryDirectory(prefix="wax-corpus-") as tmp:
            tmp_path = Path(tmp)
            card = Image.new("RGB", (1280, 720), spec.card_color)
            plate = Image.open(still).convert("RGB")
            plate.thumbnail((900, 500), Image.Resampling.LANCZOS)
            card.paste(plate, ((1280 - plate.size[0]) // 2, 140))
            d = ImageDraw.Draw(card)
            d.text((48, 36), spec.title.upper(), font=f_helvetica(28, True), fill=(240, 236, 228))
            d.text((48, 640), "North Harbor  ·  on device", font=f_helvetica(22), fill=(220, 214, 200))
            card_path = tmp_path / "card.png"
            card.save(card_path)
            audio = tmp_path / "voice.aiff"
            subprocess.run(["say", "-v", voice, "-r", "175", "-o", str(audio), spec.spoken], check=True)
            cmd = [
                ffmpeg,
                "-y",
                "-loop",
                "1",
                "-i",
                str(card_path),
                "-i",
                str(audio),
                "-c:v",
                "libx264",
                "-tune",
                "stillimage",
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                "-b:a",
                "96k",
                "-shortest",
                "-movflags",
                "+faststart",
                str(dest),
            ]
            encoded = subprocess.run(cmd, capture_output=True, text=True)
            if encoded.returncode != 0:
                raise SystemExit(encoded.stderr or encoded.stdout or "ffmpeg failed")
        duration_ms = probe_duration_ms(dest)
        chunks = split_transcript(spec.spoken, duration_ms)
        (TRANSCRIPT_DIR / spec.filename.replace(".mp4", ".json")).write_text(
            json.dumps(
                {
                    "id": spec.filename.removesuffix(".mp4"),
                    "title": spec.title,
                    "spoken": spec.spoken,
                    "duration_ms": duration_ms,
                    "chunks": chunks,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )


def probe_duration_ms(path: Path) -> int:
    out = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        text=True,
    ).strip()
    return max(1000, int(float(out) * 1000))


def split_transcript(spoken: str, duration_ms: int) -> list[dict[str, object]]:
    parts = [p.strip() for p in spoken.replace(".", ".|").split("|") if p.strip()]
    if not parts:
        return [{"start_ms": 0, "end_ms": duration_ms, "text": spoken}]
    slice_ms = duration_ms // len(parts)
    chunks = []
    for i, part in enumerate(parts):
        start = i * slice_ms
        end = duration_ms if i == len(parts) - 1 else (i + 1) * slice_ms
        chunks.append({"start_ms": start, "end_ms": end, "text": part})
    return chunks


def write_manifest() -> None:
    payload = {
        "theme": "North Harbor Workshop — week of 2026-08-10",
        "store": "harbor-week.wax",
        "counts": {"images": len(PHOTOS), "videos": len(VIDEO_SPECS), "files": len(FILES_SPEC)},
        "photos": [spec.__dict__ | {"renderer": spec.renderer} for spec in PHOTOS],
        "videos": [
            {
                "filename": spec.filename,
                "title": spec.title,
                "spoken": spec.spoken,
                "tokens": list(spec.tokens),
                "still": spec.still,
            }
            for spec in VIDEO_SPECS
        ],
        "files": [
            {
                "filename": spec.filename,
                "kind": spec.kind,
                "title": spec.title,
                "tokens": list(spec.tokens),
            }
            for spec in FILES_SPEC
        ],
        "demo_beats": [
            {
                "surface": beat.surface,
                "query": beat.query,
                "why": beat.why,
                "expect": list(beat.expect),
            }
            for beat in BEATS
        ],
    }
    # dataclasses are frozen; PhotoSpec.__dict__ works
    (ROOT / "manifest.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def verify() -> None:
    missing = []
    for spec in PHOTOS:
        if not (IMAGE_DIR / spec.filename).exists():
            missing.append(spec.filename)
    for spec in VIDEO_SPECS:
        if not (VIDEO_DIR / spec.filename).exists():
            missing.append(spec.filename)
        if not (TRANSCRIPT_DIR / spec.filename.replace(".mp4", ".json")).exists():
            missing.append(spec.filename.replace(".mp4", ".json"))
    for spec in FILES_SPEC:
        if not (FILE_DIR / spec.filename).exists():
            missing.append(spec.filename)
    if missing:
        raise SystemExit("missing: " + ", ".join(missing))

    failures = []
    for spec in FILES_SPEC:
        text = (FILE_DIR / spec.filename).read_text(encoding="utf-8", errors="ignore")
        if spec.kind == "pdf":
            # Raw PDF text is escaped but tokens should still appear.
            blob = (FILE_DIR / spec.filename).read_bytes().decode("latin-1", "ignore")
            text = blob
        haystack = text.lower()
        for token in spec.tokens:
            if token.lower() not in haystack:
                failures.append(f"{spec.filename} missing {token!r}")
    for spec in VIDEO_SPECS:
        spoken = json.loads((TRANSCRIPT_DIR / spec.filename.replace(".mp4", ".json")).read_text())["spoken"]
        haystack = spoken.lower()
        for token in spec.tokens:
            if token.lower() not in haystack:
                failures.append(f"{spec.filename} missing {token!r}")
    if failures:
        raise SystemExit("verify failed:\n" + "\n".join(failures))
    print("ok 10 images, 10 videos, 10 files, tokens present")


def main() -> None:
    os.chdir(ROOT)
    write_files()
    write_images()
    write_videos()
    write_manifest()
    verify()


if __name__ == "__main__":
    if "--verify" in sys.argv:
        verify()
    else:
        main()
