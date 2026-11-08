"""Static checks for the Vitta Plymouth boot splash (R23).

The smoke gates check the built image (theme installed, Theme=vitta, theme
inside the initramfs); scripts/vitta-bootsplash-preview.sh renders it with the
real plymouthd. These run in seconds without either: palette and geometry
against the login screen and R23, the pre-rendered images against the ladder,
and the recipe wiring.
"""

import ast
from pathlib import Path
import re
import struct
import sys
import tomllib
import unittest
import zlib


sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
THEME_DIR = ROOT / "files/vitta/usr/share/plymouth/themes/vitta"
SCRIPT = THEME_DIR / "vitta.script"
PALETTE = ROOT / "files/vitta/usr/share/vitta/theme/palette.toml"
LOGIN = ROOT / "files/vitta/usr/share/vitta/greeter/LoginScreen.qml"
ASSETS = ROOT / "scripts/vitta-bootsplash-assets.py"
WORDMARK_SOURCE = ROOT / "docs/superpowers/specs/assets/logo-final/lenovo-wordmark-dark.png"
SMOKE_GATES = (ROOT / ".github/workflows/build.yml", ROOT / "scripts/local-build-test.sh")


def png_header(path):
    """(width, height, colour_type) from a PNG's IHDR chunk."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError(f"{path} is not a PNG")
    width, height, _depth, colour_type = struct.unpack(">IIBB", data[16:26])
    return width, height, colour_type


def png_pixel(path):
    """RGB of a 1x1 8-bit RGB/RGBA PNG (the theme's colour tiles)."""
    data = path.read_bytes()
    width, height, colour_type = png_header(path)
    assert (width, height) == (1, 1), path
    pos, idat = 8, b""
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        if kind == b"IDAT":
            idat += data[pos + 8:pos + 8 + length]
        pos += 12 + length
    raw = zlib.decompress(idat)
    assert raw[0] == 0, "1x1 tile should use filter type 0"
    channels = {2: 3, 6: 4}[colour_type]
    return "#" + raw[1:1 + channels][:3].hex()


def rnd(value):
    return int(value + 0.5)


def assets_constant(name):
    """A module-level constant from scripts/vitta-bootsplash-assets.py (no Pillow import)."""
    tree = ast.parse(ASSETS.read_text())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == name for t in node.targets):
            return ast.literal_eval(node.value)
    raise KeyError(name)


class BootsplashTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = SCRIPT.read_text()
        cls.code = "\n".join(line.split("#", 1)[0] for line in cls.script.splitlines())
        cls.dark = tomllib.loads(PALETTE.read_text())["dark"]

    # ---- theme file -------------------------------------------------------------
    def test_theme_file_uses_script_plugin_from_the_theme_dir(self):
        text = (THEME_DIR / "vitta.plymouth").read_text()
        self.assertRegex(text, r"(?m)^ModuleName=script$")
        self.assertRegex(text, r"(?m)^ImageDir=/usr/share/plymouth/themes/vitta$")
        self.assertRegex(text, r"(?m)^ScriptFile=/usr/share/plymouth/themes/vitta/vitta\.script$")

    def test_script_brackets_balance(self):
        # Cheap syntax guard; the preview harness parses it with the real plugin.
        for opening, closing in ("()", "{}", "[]"):
            self.assertEqual(self.code.count(opening), self.code.count(closing), opening + closing)

    def test_every_referenced_image_exists(self):
        names = set(re.findall(r'Image \("([a-z0-9.-]+\.png)"\)', self.code))
        names |= {f"band{i}.png" for i in range(1, 5)}
        ladder = assets_constant("LADDER")
        names |= {f"{kind}-{h}.png" for kind in ("badge", "wordmark") for h in ladder}
        for name in sorted(names):
            self.assertTrue((THEME_DIR / name).is_file(), name)

    def test_ladder_image_loader_falls_back_to_the_nearest_available_asset(self):
        # Image() returns NULL for a missing file. The loader must try every
        # ladder entry by distance from the screen height before layout uses it.
        self.assertIn("fun ladder_image (kind, h)", self.code)
        self.assertIn("local.distance = ladder[local.i] - h;", self.code)
        self.assertIn("if (local.distance < 0)\n            local.distance = -local.distance;", self.code)
        self.assertIn("local.best < 0 || local.distance < local.best_distance", self.code)
        self.assertIn("local.used[local.best] = 1;", self.code)
        self.assertIn('local.image = Image (kind + "-" + ladder[local.best] + ".png");', self.code)
        self.assertIn("if (local.image)\n        return local.image;", self.code)
        self.assertIn('local.image = ladder_image ("badge", screen.h);', self.code)
        self.assertIn('local.image = ladder_image ("wordmark", screen.h);', self.code)

    # ---- palette (= login screen, palette.toml [dark]) -------------------------
    def test_script_palette_matches_palette_toml(self):
        for key in ("bg", "fg", "muted"):
            m = re.search(rf"palette\.{key} = \[(\d+), (\d+), (\d+)\];", self.code)
            self.assertIsNotNone(m, key)
            self.assertEqual("#%02x%02x%02x" % tuple(int(v) for v in m.groups()), self.dark[key], key)

    def test_background_is_flat_bg(self):
        for side in ("Top", "Bottom"):
            self.assertIn(
                f"Window.SetBackground{side}Color (channel (palette.bg[0]), channel (palette.bg[1]), channel (palette.bg[2]));",
                self.code)

    def test_channel_survives_plymouths_truncation(self):
        # Plymouth stores CLAMP(255 * c) in a uint8_t (truncation); channel(v) = (v + 0.5) / 255.
        self.assertIn("return (v + 0.5) / 255;", self.code)
        for v in range(256):
            self.assertEqual(int(255 * ((v + 0.5) / 255)), v)

    def test_tiles_carry_the_login_palette(self):
        expected = {
            "band1": self.dark["stripe1"], "band2": self.dark["stripe2"],
            "band3": self.dark["stripe3"], "band4": self.dark["stripe4"],
            "fg": self.dark["fg"], "muted": self.dark["muted"], "field": "#3c3836",
        }
        for name, colour in expected.items():
            self.assertEqual(png_pixel(THEME_DIR / f"{name}.png"), colour, name)
        self.assertEqual(assets_constant("BG"), (0x28, 0x28, 0x28))
        self.assertEqual("#%02x%02x%02x" % assets_constant("BG"), self.dark["bg"])

    def test_bands_drawn_in_stripe_order_top_down(self):
        self.assertIn('Image ("band" + (local.i + 1) + ".png").Tile (bands.length, geo.band)', self.code)
        self.assertIn("screen.y + geo.top + local.i * geo.band", self.code)

    # ---- geometry (R23 + LoginScreen.qml) ---------------------------------------
    def test_band_and_logo_rules_match_the_login_screen(self):
        login = LOGIN.read_text()
        pairs = {
            "band": (r"Math\.max\(1, Math\.round\(0\.022 \* height\)\)", r"geo\.band = Math\.Max \(1, round \(0\.022 \* screen\.h\)\);"),
            "centre": (r"Math\.round\(0\.4 \* height\)", r"geo\.centre = round \(0\.4 \* screen\.h\);"),
            "logo": (r"Math\.round\(0\.24 \* height\)", r"geo\.logo = round \(0\.24 \* screen\.h\);"),
            "gap": (r"Math\.round\(0\.54 \* logoSize\)", r"geo\.gap = round \(0\.54 \* geo\.logo\);"),
        }
        for name, (qml, script) in pairs.items():
            self.assertRegex(login, qml, name)
            self.assertRegex(self.code, script, name)
        self.assertIn("geo.top = geo.centre - 2 * geo.band;", self.code)

    def test_badge_at_81_percent_width(self):
        self.assertRegex(self.code, r"geo\.badge_x = Math\.Min \(round \(0\.81 \* screen\.w\), ")
        self.assertIn("badge.sprite.SetPosition (screen.x + geo.badge_x - geo.gap, screen.y + geo.centre - geo.gap, 10);", self.code)
        self.assertIn("geo.word_w = round (0.26 * screen.h);", self.code)
        self.assertIn("geo.word_top = geo.centre + geo.gap + round (0.01 * screen.h);", self.code)

    def test_bands_grow_from_left_edge_to_badge_with_ease_out(self):
        # Full length = badge centre, under the badge disc, which cuts the round gap.
        self.assertIn("bands.length = geo.badge_x;", self.code)
        self.assertIn("bands[local.i].sprite.SetX (screen.x + local.visible - bands.length);", self.code)
        self.assertIn("return 1 - local.u * local.u * local.u;", self.code)
        self.assertIn("place_bands (ease_out (progress.shown));", self.code)
        # Bands under the badge (z 1 < 10).
        self.assertIn("screen.y + geo.top + local.i * geo.band, 1);", self.code)

    def test_t580_geometry(self):
        # 1920x1080: what the preview frames show (band end 1361 px at progress 0.5).
        h, w = 1080, 1920
        band, centre, logo = rnd(0.022 * h), rnd(0.4 * h), rnd(0.24 * h)
        gap = rnd(0.54 * logo)
        self.assertEqual((band, centre, logo, gap), (24, 432, 259, 140))
        badge_x = min(rnd(0.81 * w), w - max(gap, rnd(0.26 * h) // 2 + 1) - rnd(0.02 * h))
        self.assertEqual(badge_x, 1555)
        ease = 1 - (1 - 0.5) ** 3
        self.assertEqual(int(ease * badge_x + 0.5), 1361)

    def test_ladder_matches_assets_and_images_match_geometry(self):
        ladder = assets_constant("LADDER")
        m = re.search(r"ladder = \[([0-9, ]+)\];\s*ladder_count = (\d+);", self.code)
        self.assertIsNotNone(m)
        self.assertEqual(tuple(int(v) for v in m.group(1).split(",")), ladder)
        self.assertEqual(int(m.group(2)), len(ladder))
        self.assertEqual(ladder, tuple(sorted(ladder)))
        src_w, src_h, _ = png_header(WORDMARK_SOURCE)
        for h in ladder:
            logo = rnd(0.24 * h)
            gap = rnd(0.54 * logo)
            self.assertEqual(png_header(THEME_DIR / f"badge-{h}.png")[:2], (2 * gap, 2 * gap), h)
            word_w = rnd(0.26 * h)
            self.assertEqual(png_header(THEME_DIR / f"wordmark-{h}.png")[:2], (word_w, rnd(src_h * word_w / src_w)), h)

    def test_ladder_steps_keep_downscale_small(self):
        # Picking the smallest design height >= the screen keeps the bilinear
        # down-scale at or below 1.2x for every screen height in the ladder's range.
        ladder = assets_constant("LADDER")
        for low, high in zip(ladder, ladder[1:]):
            self.assertLessEqual(high / (low + 1), 1.2, (low, high))

    # ---- behaviour ---------------------------------------------------------------
    def test_registers_progress_prompt_message_quit_and_hotplug_callbacks(self):
        for fn in ("SetRefreshFunction", "SetBootProgressFunction", "SetSystemUpdateFunction",
                   "SetQuitFunction", "SetDisplayHotplugFunction", "SetDisplayMessageFunction",
                   "SetHideMessageFunction", "SetDisplayPasswordFunction",
                   "SetDisplayQuestionFunction", "SetDisplayNormalFunction"):
            self.assertRegex(self.code, rf"Plymouth\.{fn} \(\w+\);", fn)

    def test_no_generic_prompt_callback(self):
        # display_prompt gets the typed passphrase as text; password callback gets a count.
        self.assertNotIn("SetDisplayPromptFunction", self.code)

    def test_quit_and_non_boot_modes_show_bands_fully_grown(self):
        self.assertRegex(self.code, r"fun finish \(\)\s*\{\s*progress\.target = 1;\s*progress\.shown = 1;\s*place_bands \(1\);")
        self.assertIn("Plymouth.SetQuitFunction (finish);", self.code)
        self.assertIn('if (mode == "boot")\n    set_target (fraction);', self.code)

    def test_progress_never_runs_backwards(self):
        self.assertRegex(self.code, r"if \(t > progress\.target\)\s*progress\.target = t;")

    def test_messages_plain_text_at_the_bottom(self):
        self.assertIn("screen.y + screen.h - geo.margin - local.image.GetHeight (), 20);", self.code)
        self.assertIn("local.image = text_image (text, palette.fg);", self.code)

    def test_password_box_shows_capped_bullets_not_text(self):
        self.assertIn('show_prompt (text, "", bullets);', self.code)
        self.assertIn("count = Math.Min (count, prompt.cap);", self.code)

    # ---- wiring --------------------------------------------------------------------
    def test_recipe_installs_plugin_sets_default_and_rebuilds_initramfs_last(self):
        modules = (ROOT / "recipes/vitta-modules.yml").read_text()
        self.assertRegex(modules, r"(?m)^      - plymouth-plugin-script\b")
        overlay = modules.index("      - source: vitta\n        destination: /")
        self.assertGreater(modules.index("      - vitta-plymouth-theme.sh"), overlay)
        vitta = (ROOT / "recipes/vitta.yml").read_text()
        last = re.findall(r"(?m)^  - (?:type|from-file): (\S+)", vitta)
        self.assertEqual(last[-2:], ["os-release", "initramfs"])

    def test_bluefin_recipes_untouched(self):
        for name in ("common.yml", "bluefin-udx.yml", "bluefin-udx-nvidia.yml"):
            text = (ROOT / "recipes" / name).read_text()
            self.assertNotIn("initramfs", text, name)
            self.assertNotIn("plymouth", text, name)
        self.assertFalse((ROOT / "files/system/usr/share/plymouth").exists())

    def test_default_theme_script_targets_plymouthd_defaults(self):
        text = (ROOT / "files/scripts/vitta-plymouth-theme.sh").read_text()
        self.assertEqual(text.splitlines()[0], "#!/bin/bash")
        self.assertIn("DEFAULTS=/usr/share/plymouth/plymouthd.defaults", text)
        self.assertIn("sed -i 's/^Theme=.*/Theme=vitta/' \"${DEFAULTS}\"", text)
        self.assertNotIn("plymouth-set-default-theme vitta", text)

    def test_smoke_gates_check_theme_default_and_initramfs(self):
        needles = (
            "check_rpm plymouth-plugin-script",
            'grep -qx "Theme=vitta" /usr/share/plymouth/plymouthd.defaults',
            'for VITTA_KVER in $(rpm -q --qf "%{VERSION}-%{RELEASE}.%{ARCH}\\n" kernel-core 2>/dev/null || true); do',
            '"/usr/lib/modules/$VITTA_KVER/vmlinuz"',
            'VITTA_INITRAMFS_CANDIDATES=$((VITTA_INITRAMFS_CANDIDATES + 1))',
            'find "$VITTA_THEME_DIR" -maxdepth 1 -type f -printf "%f\\n" | sort',
            'VITTA_LSINITRD=$(lsinitrd "$VITTA_INITRAMFS" 2>/dev/null || true)',
            "usr/lib64/plymouth/script.so",
            'lsinitrd -f usr/share/plymouth/plymouthd.defaults "$VITTA_INITRAMFS"',
            "for VITTA_DRACUT_MOD in ostree systemd plymouth; do",
        )
        blocks = []
        for gate in SMOKE_GATES:
            text = gate.read_text()
            start = text.index('echo "Vitta boot splash (Plymouth):"')
            end = text.index("no bootc kargs.d entry disables Plymouth", start)
            block = text[start:end]
            for needle in needles:
                self.assertIn(needle, block, f"{gate.name}: {needle}")
            self.assertNotIn("head -n 1", block, f"{gate.name}: initramfs must not be selected by glob order")
            self.assertNotIn("'", block, f"{gate.name}: smoke shell is single-quoted")
            blocks.append([line.strip() for line in block.splitlines()])
        self.assertEqual(blocks[0], blocks[1], "CI and local smoke gates drifted")


if __name__ == "__main__":
    unittest.main()
