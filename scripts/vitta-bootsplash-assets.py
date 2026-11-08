#!/usr/bin/env python3
"""Render the Vitta Plymouth theme's images (files/vitta/usr/share/plymouth/themes/vitta).

Plymouth's script plugin scales images with unfiltered bilinear sampling,
which aliases badly on large down-scales (a 512 px logo drawn at 259 px looks
grainy). So the badge (bg gap disc + Fedora logo) and the Lenovo wordmark are
pre-rendered with Lanczos for a ladder of design heights; vitta.script picks the
design height nearest the screen height and scales by at most ~1.2. The same
goes for the plain Fedora logo of the LUKS prompt screen (R25).

Geometry must match vitta.script and R23 (tests/test_vitta_bootsplash.py checks
both):
  logo  = round(0.24 * H)          gap radius = round(0.54 * logo)
  badge = 2 * gap square           wordmark width = round(0.26 * H)
  prompt logo = round(0.21 * H) square (R25)

Needs Pillow. Run it in the preview container, which has it:
  podman run --rm -v "$PWD:/repo:z" -w /repo localhost/vitta-bootsplash-preview \
    python3 scripts/vitta-bootsplash-assets.py
"""

from pathlib import Path
import sys

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
THEME = ROOT / "files/vitta/usr/share/plymouth/themes/vitta"
# The greeter's logo (same file as docs/.../logo-final/vitta-logo-dark.png).
LOGO = ROOT / "files/vitta/usr/share/vitta/theme/logo-dark.png"
WORDMARK = ROOT / "docs/superpowers/specs/assets/logo-final/lenovo-wordmark-dark.png"

LADDER = (720, 768, 800, 900, 1080, 1200, 1440, 1600, 1800, 2160)
BG = (0x28, 0x28, 0x28)
# 1x1 tiles vitta.script stretches with Image.Tile (pixel copies, crisp edges).
TILES = {
    "band1": (0x68, 0x9D, 0x6A),  # stripe1
    "band2": (0x45, 0x85, 0x88),  # stripe2
    "band3": (0xD7, 0x99, 0x21),  # stripe3
    "band4": (0xCC, 0x24, 0x1D),  # stripe4
    "fg": (0xEB, 0xDB, 0xB2),     # bullets
    "muted": (0xA8, 0x99, 0x84),  # lock glyph
    "field": (0x32, 0x30, 0x2F),  # prompt field fill (Gruvbox bg0_s, R25)
    "focus": (0x68, 0x9D, 0x6A),  # prompt field border (palette focus)
    "error": (0xFB, 0x49, 0x34),  # border after a wrong passphrase (palette error)
}
SUPERSAMPLE = 8


def rnd(value: float) -> int:
    """Round half up, like vitta.script's Math.Int(v + 0.5) and QML Math.round."""
    return int(value + 0.5)


def geometry(height: int) -> dict:
    logo = rnd(0.24 * height)
    gap = rnd(0.54 * logo)
    return {"logo": logo, "gap": gap, "badge": 2 * gap, "word_w": rnd(0.26 * height),
            "prompt_logo": rnd(0.21 * height)}


def resize(image: Image.Image, size: tuple) -> Image.Image:
    # Premultiplied resampling: no dark fringes from transparent pixels.
    return image.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")


def badge(height: int, logo: Image.Image) -> Image.Image:
    g = geometry(height)
    side = g["badge"]
    big = Image.new("L", (side * SUPERSAMPLE, side * SUPERSAMPLE), 0)
    ImageDraw.Draw(big).ellipse((0, 0, side * SUPERSAMPLE - 1, side * SUPERSAMPLE - 1), fill=255)
    alpha = big.resize((side, side), Image.BOX)
    out = Image.new("RGBA", (side, side), BG + (0,))
    out.putalpha(alpha)
    mark = resize(logo, (g["logo"], g["logo"]))
    offset = (side - g["logo"]) // 2
    out.alpha_composite(mark, (offset, offset))
    return out


def wordmark(height: int, source: Image.Image) -> Image.Image:
    width = geometry(height)["word_w"]
    return resize(source, (width, rnd(source.height * width / source.width)))


def prompt_logo(height: int, logo: Image.Image) -> Image.Image:
    side = geometry(height)["prompt_logo"]
    return resize(logo, (side, side))


def main() -> int:
    logo = Image.open(LOGO).convert("RGBA")
    word = Image.open(WORDMARK).convert("RGBA")
    THEME.mkdir(parents=True, exist_ok=True)
    for height in LADDER:
        badge(height, logo).save(THEME / f"badge-{height}.png", optimize=True)
        wordmark(height, word).save(THEME / f"wordmark-{height}.png", optimize=True)
        prompt_logo(height, logo).save(THEME / f"logo-{height}.png", optimize=True)
    for name, rgb in TILES.items():
        Image.new("RGB", (1, 1), rgb).save(THEME / f"{name}.png", optimize=True)
    print(f"wrote {len(LADDER) * 3 + len(TILES)} images to {THEME.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
