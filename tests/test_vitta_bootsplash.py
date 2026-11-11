"""Static checks for the Vitta Plymouth boot splash (R23).

The smoke gates check the built image (theme installed, Theme=vitta, theme
inside the initramfs); scripts/vitta-bootsplash-preview.sh renders it with the
real plymouthd. These run in seconds without either: palette and geometry
against the login screen and R23, the pre-rendered images against the ladder,
and the recipe wiring.
"""

import ast
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
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
STOCK_DEFAULTS = """# Distribution defaults. Changes to this file will get overwritten during
# upgrades.
[Daemon]
Theme=bgrt
ShowDelay=0
DeviceTimeout=8
UseSimpledrmNoLuks=1
"""


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
        names |= {f"{kind}-{h}.png" for kind in ("badge", "wordmark", "logo") for h in ladder}
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
            "fg": self.dark["fg"], "muted": self.dark["muted"],
            # LUKS prompt screen (R25): field fill bg0_s, border focus / error.
            "field": "#32302f", "focus": self.dark["focus"], "error": self.dark["error"],
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
        self.assertIn("local.image = text_image (text, palette.fg, geo.font_px);", self.code)

    def test_password_box_shows_capped_bullets_not_text(self):
        self.assertIn('show_prompt ("password", text, "", bullets);', self.code)
        self.assertIn("count = Math.Min (count, pr.cap);", self.code)

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
        self.assertIn("/usr/share/plymouth/plymouthd.defaults", text)
        self.assertIn("sed -i 's/^Theme=.*/Theme=vitta/' \"${DEFAULTS}\"", text)
        self.assertNotIn("plymouth-set-default-theme vitta", text)

    def test_theme_script_pins_device_scale(self):
        script = ROOT / "files/scripts/vitta-plymouth-theme.sh"
        text = script.read_text()
        # The fixture executes the shipped script only after it exposes every
        # image path as an override, so this test cannot write host /usr or /etc.
        self.assertIn('DEFAULTS=${DEFAULTS:-/usr/share/plymouth/plymouthd.defaults}', text)
        self.assertIn('CONF=${CONF:-/etc/plymouth/plymouthd.conf}', text)
        self.assertIn('THEME=${THEME:-/usr/share/plymouth/themes/vitta/vitta.plymouth}', text)

        variants = {
            "stock": STOCK_DEFAULTS,
            "commented": STOCK_DEFAULTS.replace("Theme=bgrt", "Theme=bgrt\n#DeviceScale=2"),
            "existing": STOCK_DEFAULTS.replace("Theme=bgrt", "Theme=bgrt\nDeviceScale=2"),
        }
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            fake_bin = tmp / "bin"
            plugin_dir = tmp / "plugins"
            fake_bin.mkdir()
            plugin_dir.mkdir()
            (plugin_dir / "script.so").touch()
            theme = tmp / "vitta.plymouth"
            theme.write_text("[Plymouth Theme]\n")
            (fake_bin / "plymouth").write_text(
                "#!/bin/bash\n"
                "if [ \"$1\" = --get-splash-plugin-path ]; then\n"
                "  printf '%s/\\n' \"$VITTA_TEST_PLUGIN_DIR\"\n"
                "fi\n"
            )
            (fake_bin / "plymouth-set-default-theme").write_text("#!/bin/bash\necho vitta\n")
            for executable in fake_bin.iterdir():
                executable.chmod(0o755)

            def run(defaults):
                defaults_path = tmp / "plymouthd.defaults"
                conf_path = tmp / "plymouthd.conf"
                defaults_path.write_text(defaults)
                defaults_path.chmod(0o644)
                conf_path.write_text("[Daemon]\n")
                result = subprocess.run(
                    ["bash", str(script)],
                    env=os.environ | {
                        "PATH": f"{fake_bin}:{os.environ['PATH']}",
                        "DEFAULTS": str(defaults_path),
                        "CONF": str(conf_path),
                        "THEME": str(theme),
                        "VITTA_TEST_PLUGIN_DIR": str(plugin_dir),
                    },
                    capture_output=True,
                    text=True,
                    timeout=15,
                    check=False,
                )
                return result, defaults_path

            for name, defaults in variants.items():
                with self.subTest(variant=name):
                    result, defaults_path = run(defaults)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    written = defaults_path.read_text()
                    self.assertEqual(
                        [(section, line) for section, line in self._device_scale_lines(written)],
                        [("Daemon", "DeviceScale=1")],
                    )
                    self.assertEqual(defaults_path.stat().st_mode & 0o777, 0o644)
                    repeat, repeated_path = run(written)
                    self.assertEqual(repeat.returncode, 0, repeat.stderr)
                    self.assertEqual(repeated_path.read_text(), written)
                    self.assertEqual(repeated_path.stat().st_mode & 0o777, 0o644)

            malformed = STOCK_DEFAULTS + "\n[Other]\nDeviceScale=2\n"
            result, defaults_path = run(malformed)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(defaults_path.read_text(), malformed)
            self.assertEqual(defaults_path.stat().st_mode & 0o777, 0o644)

    @staticmethod
    def _device_scale_lines(defaults):
        section = None
        found = []
        for line in defaults.splitlines():
            match = re.fullmatch(r"\[([^]]+)\]", line)
            if match:
                section = match.group(1)
            elif re.match(r"^\s*DeviceScale\s*=", line):
                found.append((section, line))
        return found

    def test_smoke_gates_check_theme_default_and_initramfs(self):
        needles = (
            "check_rpm plymouth-plugin-script",
            'grep -qx "Theme=vitta" /usr/share/plymouth/plymouthd.defaults',
            'grep -q "^DeviceScale=1$" /usr/share/plymouth/plymouthd.defaults',
            'for VITTA_KVER in $(rpm -q --qf "%{VERSION}-%{RELEASE}.%{ARCH}\\n" kernel-core 2>/dev/null || true); do',
            '"/usr/lib/modules/$VITTA_KVER/vmlinuz"',
            'VITTA_INITRAMFS_CANDIDATES=$((VITTA_INITRAMFS_CANDIDATES + 1))',
            'find "$VITTA_THEME_DIR" -maxdepth 1 -type f -printf "%f\\n" | sort',
            'VITTA_LSINITRD=$(lsinitrd "$VITTA_INITRAMFS" 2>/dev/null || true)',
            "usr/lib64/plymouth/script.so",
            'lsinitrd -f usr/share/plymouth/plymouthd.defaults "$VITTA_INITRAMFS"',
            'grep -q "^DeviceScale=1$"',
            'grep -q "/i915\\.ko"',
            'lsinitrd -f etc/cmdline.d/20-force_drivers.conf "$VITTA_INITRAMFS"',
            'grep -q "^rd.driver.pre=i915$"',
            'usr/lib/modprobe.d/nvidia.conf',
            "for VITTA_DRACUT_MOD in ostree systemd plymouth vitta-plymouth-font; do",
            # LUKS prompt font (R25) inside the exact kernel initramfs.
            "usr/lib64/plymouth/label-freetype.so",
            "usr/share/fonts/monaspace-neon/MonaspaceNeon-Regular.otf",
            "usr/share/fonts/monaspace-neon/MonaspaceNeon-Bold.otf",
            '"Plymouth-monospace.ttf -> /usr/share/fonts/monaspace-neon/MonaspaceNeon-Regular.otf"',
            '"Plymouth.ttf -> /usr/share/fonts/monaspace-neon/MonaspaceNeon-Bold.otf"',
            'grep -qF " usr/share/fonts/$VITTA_FONT_LINK"',
            "check_file /usr/lib/dracut/modules.d/99vitta-plymouth-font/module-setup.sh",
            "check_file /usr/lib/dracut/dracut.conf.d/90-vitta-plymouth-font.conf",
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



def script_geometry(code, width, height):
    """Evaluate vitta.script's geo.* / pgeo.* assignments for one screen size.

    The script's arithmetic is a tiny subset (round, Math.Max/Min/Int, + - * /),
    so translating it to Python keeps the test tied to the real expressions.
    """
    env = {"rnd": rnd, "max": max, "min": min, "int": int, "w": width, "h": height, "G": {}, "P": {}}
    for target, name, expr in re.findall(r"(?m)^\s*(geo|pgeo)\.(\w+) = (.+);", code):
        expr = re.sub(r"\bpgeo\.(\w+)", r'P["\1"]', expr)
        expr = re.sub(r"\bgeo\.(\w+)", r'G["\1"]', expr)
        expr = (expr.replace("Math.Max (", "max(").replace("Math.Min (", "min(")
                .replace("Math.Int (", "int(").replace("round (", "rnd(")
                .replace("screen.w", "w").replace("screen.h", "h"))
        env["G" if target == "geo" else "P"][name] = eval(expr, env)  # noqa: S307 (test-only, repo source)
    return env["G"], env["P"]


class LuksPromptTests(unittest.TestCase):
    """LUKS prompt screen, ruling R25 (docs/superpowers/specs/2026-11-08-vitta-luks-prompt-design.md)."""

    SIZES = ((1920, 1080), (1366, 768), (2560, 1440), (2560, 1600), (1280, 800), (3840, 2160), (1024, 768))

    @classmethod
    def setUpClass(cls):
        cls.script = SCRIPT.read_text()
        cls.code = "\n".join(line.split("#", 1)[0] for line in cls.script.splitlines())
        cls.dark = tomllib.loads(PALETTE.read_text())["dark"]

    def function(self, name):
        m = re.search(rf"(?ms)^fun {name} \([^)]*\)\n\{{\n(.*?)^\}}", self.code)
        self.assertIsNotNone(m, name)
        return m.group(1)

    # ---- layout constants vs R25 ----------------------------------------------------
    def test_t580_prompt_geometry(self):
        geo, pgeo = script_geometry(self.code, 1920, 1080)
        self.assertEqual((pgeo["logo"], pgeo["logo_top"]), (227, 173))          # 21 % h, top at 16 % h
        self.assertEqual((pgeo["field_w"], pgeo["field_h"]), (595, 58))         # 31 % w
        self.assertEqual((pgeo["field_x"], pgeo["field_y"]), (662, 533))
        self.assertEqual(pgeo["field_y"] + pgeo["field_h"] // 2, 562)            # centre at 52 % h
        self.assertEqual(pgeo["border"], 3)                                     # 3 px border at 1080p
        self.assertEqual(geo["band"], 24)                                       # 2.2 % h per band
        self.assertEqual(pgeo["max_lines"], 3)

    def test_prompt_geometry_follows_r25_at_every_size(self):
        for w, h in self.SIZES:
            geo, pgeo = script_geometry(self.code, w, h)
            with self.subTest(size=f"{w}x{h}"):
                self.assertLessEqual(abs(pgeo["logo"] - 0.21 * h), 1)
                self.assertLessEqual(abs(pgeo["logo_top"] - 0.16 * h), 1)
                self.assertLessEqual(abs(pgeo["field_y"] + pgeo["field_h"] / 2 - 0.52 * h), 1)
                self.assertLessEqual(abs(pgeo["field_w"] - 0.31 * w), 1)
                self.assertLessEqual(abs(pgeo["field_x"] * 2 + pgeo["field_w"] - w), 1)  # centred
                self.assertEqual(geo["band"], max(1, rnd(0.022 * h)))
                self.assertGreaterEqual(pgeo["border"], 2)
                # The logo ends above the field; the field above the prompt bands.
                self.assertLess(pgeo["logo_top"] + pgeo["logo"], pgeo["field_y"])
                self.assertLess(pgeo["field_y"] + pgeo["field_h"] + pgeo["text_gap"], h - 4 * geo["band"])

    def test_prompt_r25_expressions(self):
        for line in (
            "pgeo.logo = round (0.21 * screen.h);",
            "pgeo.logo_top = round (0.16 * screen.h);",
            "pgeo.field_w = Math.Min (round (0.31 * screen.w), screen.w - 2 * geo.margin);",
            "pgeo.field_y = round (0.52 * screen.h) - Math.Int (pgeo.field_h / 2);",
            "pgeo.field_x = Math.Int ((screen.w - pgeo.field_w) / 2);",
        ):
            self.assertIn(line, self.code)
        self.assertIn("pr.logo.SetPosition (screen.x + Math.Int ((screen.w - pgeo.logo) / 2), screen.y + pgeo.logo_top, 40);",
                      self.code)

    def test_prompt_bands_full_width_flush_with_the_bottom(self):
        self.assertIn('pr.bands[local.i] = Sprite (Image ("band" + (local.i + 1) + ".png").Tile (screen.w, geo.band));',
                      self.code)
        self.assertIn("pr.bands[local.i].SetPosition (screen.x, screen.y + screen.h - (4 - local.i) * geo.band, 40);",
                      self.code)
        h = 1080
        band = rnd(0.022 * h)
        self.assertEqual([h - (4 - i) * band for i in range(4)], [984, 1008, 1032, 1056])
        self.assertEqual(h - (4 - 3) * band + band, h)  # last band ends on the bottom edge

    def test_prompt_colours(self):
        m = re.search(r"palette\.fg2 = \[(\d+), (\d+), (\d+)\];", self.code)
        self.assertEqual("#%02x%02x%02x" % tuple(int(v) for v in m.groups()), "#d5c4a1")
        self.assertIn("text_image (local.lines[local.i], palette.fg2, pgeo.font_px)", self.code)
        self.assertIn('pr.frame_focus = Image ("focus.png").Tile (pgeo.field_w, pgeo.field_h);', self.code)
        self.assertIn('pr.frame_error = Image ("error.png").Tile (pgeo.field_w, pgeo.field_h);', self.code)
        self.assertIn('Image ("field.png").Tile (pgeo.field_w - 2 * pgeo.border, pgeo.field_h - 2 * pgeo.border)',
                      self.code)
        self.assertEqual(png_pixel(THEME_DIR / "field.png"), "#32302f")
        self.assertEqual(png_pixel(THEME_DIR / "focus.png"), "#689d6a")
        self.assertEqual(png_pixel(THEME_DIR / "error.png"), "#fb4934")
        self.assertEqual(png_pixel(THEME_DIR / "fg.png"), "#ebdbb2")  # square bullets
        self.assertIn('pr.bullet_image = Image ("fg.png").Tile (pgeo.bullet, pgeo.bullet);', self.code)

    def test_logo_ladder_images_match_r25(self):
        for h in assets_constant("LADDER"):
            side = rnd(0.21 * h)
            self.assertEqual(png_header(THEME_DIR / f"logo-{h}.png")[:2], (side, side), h)
        self.assertIn('ladder_image ("logo", screen.h)', self.code)

    # ---- splash hidden while prompting, restored after ----------------------------------
    def test_splash_sprites_hidden_while_prompting_and_restored(self):
        body = self.function("apply_screen")
        self.assertIn("local.on = prompt.active;", body)
        self.assertIn("local.splash = !local.on;", body)
        self.assertIn("badge.sprite.SetOpacity (local.splash);", body)
        self.assertIn("word.sprite.SetOpacity (local.splash);", body)
        self.assertIn('message.sprite.SetOpacity (local.splash && message.text != "");', body)
        self.assertIn("bands.visible = -1;\n  place_bands (ease_out (progress.shown));", body)
        for sprite in ("pr.frame", "pr.field", "pr.bands[local.i]", "pr.logo"):
            self.assertIn(f"{sprite}.SetOpacity (local.on", body)
        # Progress bands keep moving underneath; they only show outside a prompt.
        self.assertIn("SetOpacity (local.visible > 0 && !prompt.active);", self.function("place_bands"))
        self.assertIn("place_bands (ease_out (progress.shown));", self.function("refresh_callback"))
        self.assertIn("message.sprite.SetOpacity (!prompt.active);", self.function("display_message_callback"))

    def test_prompt_and_normal_mode_switch_screens(self):
        show = self.function("show_prompt")
        self.assertLess(show.index("prompt.active = 1;"), show.index("apply_screen ();"))
        normal = self.function("display_normal_callback")
        self.assertLess(normal.index("prompt.active = 0;"), normal.index("apply_screen ();"))
        self.assertIn("set_bullets (0);", normal)
        # Hotplug re-layout restores whichever screen is current.
        layout = self.function("layout")
        self.assertIn("layout_prompt ();", layout)
        self.assertIn("show_prompt (prompt.kind, prompt.text, prompt.entry_text, prompt.bullets_wanted);", layout)
        self.assertIn("apply_screen ();", layout)

    # ---- wrong passphrase ------------------------------------------------------------
    def test_wrong_passphrase_turns_the_border_error_red(self):
        frame = self.function("set_frame")
        self.assertIn("if (error && pr.frame_error)\n    pr.frame.SetImage (pr.frame_error);", frame)
        self.assertIn("pr.frame.SetImage (pr.frame_focus);", frame)
        self.assertIn("set_frame (prompt.error);", self.function("show_prompt"))
        # Retry = cryptsetup asks again with the text of an answered prompt.
        self.assertIn("prompt.answered[prompt.text] = 1;", self.function("leave_password_prompt"))
        password = self.function("display_password_callback")
        self.assertIn("if (prompt.answered[text] == 1)\n        prompt.error = 1;", password)
        self.assertIn("leave_password_prompt ();", self.function("display_normal_callback"))
        self.assertIn("prompt.error = 0;", self.function("display_normal_callback"))

    def test_password_shows_bullets_never_text(self):
        self.assertIn('show_prompt ("password", text, "", bullets);', self.function("display_password_callback"))
        self.assertNotIn("SetDisplayPromptFunction", self.code)
        self.assertIn("pr.lock[local.i].SetOpacity (local.on && prompt.kind == \"password\");", self.code)
        self.assertIn("pr.cap = Math.Max (1, ", self.code)

    def test_long_prompts_wrap_and_never_overflow(self):
        wrap = self.function("wrap_text")
        self.assertIn('text.CharAt (local.i) == " "', wrap)
        self.assertIn("text_width (local.candidate) <= pgeo.text_w", wrap)
        self.assertIn('local.line = local.line + " ...";', wrap)
        self.assertIn("pgeo.text_w = screen.w - 2 * geo.margin;", self.code)
        self.assertIn("fit_width (text_image (local.lines[local.i], palette.fg2, pgeo.font_px), pgeo.text_w)",
                      self.code)
        self.assertIn("image.Crop (", self.function("fit_width"))

    def test_no_keyboard_layout_line(self):
        # Plymouth 24's script API has no keymap accessor (script-lib-plymouth.c:
        # GetCapslockState and GetMode only), so R25's layout line is omitted.
        for word in ("Keymap", "keymap", "Layout (", "GetKeyboard"):
            self.assertNotIn(word, self.code)
        self.assertIn("Plymouth.GetCapslockState ()", self.code)

    # ---- font in the initramfs ------------------------------------------------------
    def test_prompt_font_selects_label_freetypes_monospace_face(self):
        m = re.search(r'fonts\.regular = "([^"]+)";', self.code)
        self.assertIsNotNone(m)
        self.assertTrue(m.group(1).startswith("Monaspace Neon"))
        self.assertIn("mono", m.group(1))  # label-freetype: strstr(font, "mono") -> Plymouth-monospace.ttf
        self.assertNotRegex(self.code, r'Image\.Text \([^)]*"Sans')

    def test_dracut_module_links_monaspace_after_plymouth(self):
        module = ROOT / "files/vitta/usr/lib/dracut/modules.d/99vitta-plymouth-font/module-setup.sh"
        text = module.read_text()
        self.assertEqual(text.splitlines()[0], "#!/bin/bash")
        self.assertIn("echo plymouth", text)
        self.assertIn('ln -sfn "$VITTA_FONT_DIR/MonaspaceNeon-Regular.otf" "${initdir}/usr/share/fonts/Plymouth-monospace.ttf"', text)
        self.assertIn('ln -sfn "$VITTA_FONT_DIR/MonaspaceNeon-Bold.otf" "${initdir}/usr/share/fonts/Plymouth.ttf"', text)
        self.assertIn("VITTA_FONT_DIR=/usr/share/fonts/monaspace-neon", text)
        self.assertIn("return 255", text)
        # Installed after 45plymouth's populate-initrd (dracut installs in directory order).
        self.assertGreater(int(module.parent.name[:2]), 45)
        conf = (ROOT / "files/vitta/usr/lib/dracut/dracut.conf.d/90-vitta-plymouth-font.conf").read_text()
        self.assertIn('add_dracutmodules+=" vitta-plymouth-font "', conf)
        # Fonts are baked before the initramfs module runs.
        modules = (ROOT / "recipes/vitta-modules.yml").read_text()
        self.assertIn("      - install-monaspace-neon.sh", modules)

    def test_preview_harness_renders_text_like_the_initramfs(self):
        render = (ROOT / "scripts/bootsplash-preview/render.sh").read_text()
        self.assertIn("2560x1600", render)
        self.assertIn('rm -f "${PLUGIN_DIR}label-pango.so"', render)
        self.assertIn("mv /usr/bin/fc-match /usr/bin/fc-match.off", render)
        self.assertIn('ln -sfn "$FONT_DIR/MonaspaceNeon-Regular.otf" /usr/share/fonts/Plymouth-monospace.ttf', render)
        self.assertIn('ln -sfn "$FONT_DIR/MonaspaceNeon-Bold.otf" /usr/share/fonts/Plymouth.ttf', render)
        containerfile = (ROOT / "scripts/bootsplash-preview/Containerfile").read_text()
        install = (ROOT / "files/scripts/install-monaspace-neon.sh").read_text()
        url = re.search(r'URL="([^"]+)"', install).group(1)
        sha = re.search(r'SHA256="([0-9a-f]+)"', install).group(1)
        self.assertIn(f"ARG MONASPACE_URL={url}", containerfile)
        self.assertIn(f"ARG MONASPACE_SHA256={sha}", containerfile)

if __name__ == "__main__":
    unittest.main()
