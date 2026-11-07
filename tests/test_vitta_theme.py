"""Regression tests for the Vitta day/night theme CLI."""

from datetime import date, datetime
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from zoneinfo import ZoneInfo


# Loading vitta-theme as a module would otherwise write
# files/vitta/usr/bin/__pycache__/, which a local image build would bake into
# /usr/bin. Subprocesses inherit the same guard through the environment.
sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"

ROOT = Path(__file__).resolve().parents[1]
THEME = ROOT / "files/vitta/usr/bin/vitta-theme"
PALETTE = ROOT / "files/vitta/usr/share/vitta/theme/palette.toml"
AMS = (52.37, 4.90)
TZ = ZoneInfo("Europe/Amsterdam")


def load_theme():
    loader = SourceFileLoader("vitta_theme", str(THEME))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


theme = load_theme()


def minutes(when):
    return when.hour * 60 + when.minute


def dt(value):
    return datetime.fromisoformat(value)


def run_cli(*args):
    return subprocess.run(
        ["python3", str(THEME), *args],
        capture_output=True,
        check=True,
        text=True,
        timeout=15,
    )


def out(*args):
    return json.loads(run_cli(*args).stdout)


class VittaThemeTests(unittest.TestCase):
    def test_amsterdam_midsummer_sun_times(self):
        rise, set_ = theme.sun_times(date(2026, 6, 21), *AMS, TZ)
        self.assertLessEqual(abs(minutes(rise) - (5 * 60 + 18)), 4)
        self.assertLessEqual(abs(minutes(set_) - (22 * 60 + 6)), 4)

    def test_amsterdam_midwinter_sun_times(self):
        rise, set_ = theme.sun_times(date(2026, 12, 21), *AMS, TZ)
        self.assertLessEqual(abs(minutes(rise) - (8 * 60 + 48)), 4)
        self.assertLessEqual(abs(minutes(set_) - (16 * 60 + 29)), 4)

    def test_mode_noon_light_midnight_dark(self):
        self.assertEqual(theme.mode_at(dt("2026-06-21T12:00+02:00"), *AMS), "light")
        self.assertEqual(theme.mode_at(dt("2026-06-21T23:30+02:00"), *AMS), "dark")

    def test_mode_winter_morning_before_sunrise_is_dark(self):
        self.assertEqual(theme.mode_at(dt("2026-12-21T08:00+01:00"), *AMS), "dark")
        self.assertEqual(theme.mode_at(dt("2026-12-21T17:00+01:00"), *AMS), "dark")

    def test_polar_day_and_night(self):
        self.assertEqual(theme.mode_at(dt("2026-06-21T02:00+02:00"), 78.2, 15.6), "light")
        self.assertEqual(theme.mode_at(dt("2026-12-21T12:00+01:00"), 78.2, 15.6), "dark")

    def test_cli_mode_uses_config_and_tz(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "theme.conf"
            config.write_text("latitude = -33.87\nlongitude = 151.21\n")
            result = subprocess.run(
                [
                    "python3", str(THEME), "mode",
                    "--at", "2026-12-21T12:00+11:00",
                    "--config", str(config),
                ],
                env={**os.environ, "TZ": "Europe/Amsterdam"},
                capture_output=True,
                check=True,
                text=True,
                timeout=15,
            )
        self.assertEqual(result.stdout.strip(), "light")

    def test_cli_broken_config_falls_back_to_amsterdam(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "theme.conf"
            config.write_text("not = [valid toml")
            result = subprocess.run(
                [
                    "python3", str(THEME), "mode",
                    "--at", "2026-06-21T12:00+02:00",
                    "--config", str(config),
                ],
                capture_output=True,
                text=True,
                timeout=15,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "light")
        self.assertIn("warning:", result.stderr)

    def test_palette_dark_values(self):
        # R20: layout A band colours; the old "stripe2 = fg" rule is gone.
        self.assertEqual(
            out("palette", "--mode", "dark", "--json"),
            {
                "bg": "#282828",
                "fg": "#ebdbb2",
                "stripe1": "#689d6a",
                "stripe2": "#458588",
                "stripe3": "#d79921",
                "stripe4": "#cc241d",
                "muted": "#a89984",
                "error": "#fb4934",
            },
        )

    def test_palette_light_values(self):
        self.assertEqual(
            out("palette", "--mode", "light", "--json"),
            {
                "bg": "#fbf1c7",
                "fg": "#3c3836",
                "stripe1": "#8ec07c",
                "stripe2": "#83a598",
                "stripe3": "#fabd2f",
                "stripe4": "#fb4934",
                "muted": "#7c6f64",
                "error": "#9d0006",
            },
        )

    def test_greeter_fallback_palette_mirrors_palette_toml(self):
        """Theme.qml keeps a built-in copy of palette.toml for when
        vitta-theme fails; it must not drift from the real palette."""
        qml = (ROOT / "files/vitta/usr/share/vitta/greeter/Theme.qml").read_text()
        palette = theme.load_palette(PALETTE)
        for mode in ("dark", "light"):
            block = re.search(rf"^        {mode}: \{{\n(.*?)\n        \}}", qml, re.DOTALL | re.MULTILINE)
            self.assertIsNotNone(block, mode)
            self.assertEqual(dict(re.findall(r'(\w+): "(#[0-9a-fA-F]{6})"', block.group(1))), palette[mode], mode)

    # ---- hyprlock, layout A (R20) -------------------------------------------
    # The fragment is parsed into widgets and laid out the way hyprlock does
    # it (IWidget::posFromHVAlign with halign/valign center: a widget's centre
    # sits at the screen centre plus `position`, y up; `%` values are relative
    # to the monitor, per axis). Image size is px; a label's box is estimated
    # as 1.3 x its pixel size high (font_size is Pango points at 96 dpi,
    # px = pt * 4/3) and the full screen wide, since every label is centred.

    def render(self, mode="dark"):
        return run_cli(
            "render", "hyprlock", "--mode", mode,
            "--palette", str(PALETTE), "--logo-dir", "/logos",
        ).stdout

    def widgets(self, rendered):
        """Return [(kind, {key: value}), ...] in file order."""
        found = []
        for kind, body in re.findall(r"^(\w[\w-]*) \{\n(.*?)\n\}", rendered, re.DOTALL | re.MULTILINE):
            props = dict(re.findall(r"^    (\w+) = (.*)$", body, re.MULTILINE))
            found.append((kind, props))
        return found

    @staticmethod
    def length(value, extent):
        value = value.strip()
        return float(value[:-1]) / 100 * extent if value.endswith("%") else float(value)

    def layout(self, rendered, width=1920, height=1080):
        """Return [(kind, props, (x0, y0, x1, y1)), ...] in screen px, y down."""
        boxes = []
        for kind, props in self.widgets(rendered):
            if kind == "background":
                boxes.append((kind, props, (0, 0, width, height)))
                continue
            self.assertEqual((props["halign"], props["valign"]), ("center", "center"), kind)
            px, py = props["position"].split(",")
            cx = width / 2 + self.length(px, width)
            cy = height / 2 - self.length(py, height)
            if kind == "image":
                w = h = float(props["size"])
            elif kind == "label":
                w, h = width, int(props["font_size"]) * 4 / 3 * 1.3
            else:
                sw, sh = props["size"].split(",")
                w, h = self.length(sw, width), self.length(sh, height)
            boxes.append((kind, props, (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)))
        return boxes

    @staticmethod
    def zindex(props):
        return int(props["zindex"]) if "zindex" in props else 0

    def paint(self, boxes, x, y):
        """Colour hyprlock paints at pixel centre (x, y): background and shapes
        only, topmost zindex wins; rounding -1 makes a circle."""
        colour = None
        for kind, props, (x0, y0, x1, y1) in sorted(
            (b for b in boxes if b[0] in ("background", "shape")), key=lambda b: self.zindex(b[1])
        ):
            if kind == "shape" and props["rounding"].strip() == "-1":
                r = min(x1 - x0, y1 - y0) / 2
                inside = (x - (x0 + x1) / 2) ** 2 + (y - (y0 + y1) / 2) ** 2 <= r * r
            else:
                inside = x0 <= x < x1 and y0 <= y < y1
            if inside:
                colour = props["color"]
        return colour

    def runs(self, boxes, x, height=1080):
        """Run-length encode the painted column at x: [[colour, first_y, count], ...]."""
        result = []
        for y in range(height):
            colour = self.paint(boxes, x + 0.5, y + 0.5)
            if result and result[-1][0] == colour:
                result[-1][2] += 1
            else:
                result.append([colour, y, 1])
        return result

    def test_render_hyprlock_header_and_no_general_or_auth(self):
        for mode in ("dark", "light"):
            rendered = self.render(mode)
            self.assertEqual(rendered.splitlines()[0], f"# vitta-theme render hyprlock --mode {mode}")
            self.assertIn(f"path = /logos/logo-{mode}.png", rendered)
            self.assertNotIn("general {", rendered)
            self.assertNotIn("auth {", rendered)
            self.assertIn("font_family = Monaspace Neon", rendered)
            self.assertNotIn("border_color", rendered)

    def test_render_hyprlock_four_flat_full_width_bands_in_order(self):
        """Down any column away from the logo: bg, stripe1, stripe2, stripe3,
        stripe4, bg. Each band 2 % of H thick (21.6 px at 1080p, +-1 px for
        hyprlock rounding % sizes to pixels; whole percents only, R21), block
        centred at 40 % of H, touching, at every common height."""
        for mode in ("dark", "light"):
            colours = theme.load_palette(PALETTE)[mode]
            rendered = self.render(mode)
            shapes = [props for kind, props in self.widgets(rendered) if kind == "shape"]
            for props in shapes:
                self.assertEqual(props["border_size"], "0")
                self.assertEqual(props["shadow_passes"], "0")
            bands = [props for props in shapes if props["rounding"] != "-1"]
            self.assertEqual(len(bands), 4)
            self.assertTrue(all(props["size"].startswith("100%,") for props in bands), "bands span the screen")
            self.assertTrue(all(props["size"].endswith("%") and props["position"].endswith("%") for props in bands),
                            "band height and position follow the monitor")
            expected = [theme.rgba(colours[key]) for key in ("bg", "stripe1", "stripe2", "stripe3", "stripe4", "bg")]
            for width, height in ((1920, 1080), (2560, 1440), (1920, 1200), (1366, 768)):
                boxes = self.layout(rendered, width, height)
                for x in (0, 40, width - 1):
                    column = self.runs(boxes, x, height)
                    self.assertEqual([run[0] for run in column], expected, (mode, width, height, x))
                    band = 0.02 * height
                    self.assertTrue(all(abs(run[2] - band) <= 1 for run in column[1:5]), (column, band))
                    centre = (column[1][1] + column[4][1] + column[4][2]) / 2
                    self.assertLessEqual(abs(centre - 0.4 * height), 1, (width, height, centre))

    def test_render_hyprlock_logo_sits_in_round_bg_gap_over_the_bands(self):
        rendered = self.render("light")
        colours = theme.load_palette(PALETTE)["light"]
        boxes = self.layout(rendered)
        gaps = [(props, box) for kind, props, box in boxes if kind == "shape" and props["rounding"] == "-1"]
        images = [(props, box) for kind, props, box in boxes if kind == "image"]
        self.assertEqual(len(gaps), 1)
        self.assertEqual(len(images), 1)
        (gap, gap_box), (logo, logo_box) = gaps[0], images[0]
        self.assertEqual(gap["color"], theme.rgba(colours["bg"]))
        # R20 sizes at 1080p: logo round(0.24 H) = 259, gap radius 0.54 x logo.
        self.assertEqual(int(logo["size"]), round(0.24 * 1080))
        self.assertEqual(gap_box[2] - gap_box[0], 2 * round(0.54 * int(logo["size"])))
        self.assertEqual(gap_box[2] - gap_box[0], gap_box[3] - gap_box[1], "gap is a circle")
        self.assertEqual((logo["rounding"], logo["border_size"]), ("0", "0"), "logo neither cropped nor framed")
        centre = lambda b: ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2)
        self.assertEqual(centre(gap_box), centre(logo_box))
        self.assertEqual(centre(logo_box), (960, 0.4 * 1080), "logo centred on the band block")
        # Explicit painter's order: background < bands < gap < logo, unique
        # (hyprlock's zindex sort is unstable).
        order = [self.zindex(props) for kind, props, _ in boxes if kind in ("background", "shape")]
        order.append(self.zindex(logo))
        self.assertTrue(all(kind not in ("background", "shape", "image") or "zindex" in props
                            for kind, props, _ in boxes), "explicit zindex")
        self.assertEqual(order, sorted(set(order)))
        # The bands end in the gap: bg down the centre column, bands right
        # outside the circle.
        bg = theme.rgba(colours["bg"])
        self.assertEqual({run[0] for run in self.runs(boxes, 960)}, {bg})
        radius = (gap_box[2] - gap_box[0]) / 2
        self.assertEqual(len(self.runs(boxes, int(960 - radius - 2))), 6)

    def test_render_hyprlock_widgets_inside_screen_and_clear_of_each_other(self):
        """Clock, date, band block, gap circle, logo, password field and host
        line stay on screen and never overlap, except that the bands run into
        the gap circle and the logo by design. Checked at 1080p (the
        reference) and the larger screens a dock may add."""
        for width, height in ((1920, 1080), (1920, 1200), (2560, 1440), (3840, 2160)):
            boxes = self.layout(self.render(), width, height)
            bands = [box for kind, props, box in boxes if kind == "shape" and props["rounding"] != "-1"]
            named = [("bands", (0, min(b[1] for b in bands), width, max(b[3] for b in bands)))]
            labels = iter(("clock", "date", "host"))
            for kind, props, box in boxes:
                if kind == "shape" and props["rounding"] == "-1":
                    named.append(("gap", box))
                elif kind == "image":
                    named.append(("logo", box))
                elif kind == "input-field":
                    named.append(("input", box))
                elif kind == "label":
                    named.append((next(labels), box))
            self.assertEqual(sorted(name for name, _ in named),
                             ["bands", "clock", "date", "gap", "host", "input", "logo"])
            allowed = {frozenset(("bands", "gap")), frozenset(("bands", "logo")), frozenset(("gap", "logo"))}
            for name, (x0, y0, x1, y1) in named:
                self.assertTrue(0 <= x0 and x1 <= width and 0 <= y0 and y1 <= height, (width, height, name))
            for index, (name_a, a) in enumerate(named):
                for name_b, b in named[index + 1:]:
                    if frozenset((name_a, name_b)) in allowed:
                        continue
                    overlap = a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]
                    self.assertFalse(overlap, f"{width}x{height}: {name_a} {a} overlaps {name_b} {b}")

    def test_render_hyprlock_geometry_is_whole_numbers(self):
        """hyprlock reads `%` and numbers with the locale-sensitive std::stof:
        under a decimal-comma LC_NUMERIC "2.2%" misparses. Every size,
        position, rounding and other number must be an integer (R21). Only
        the input field's dots_size/dots_spacing are inherently fractions of
        the field height; niri-lock.sh starts hyprlock with LC_NUMERIC=C."""
        fractional = {"dots_size", "dots_spacing"}
        for mode in ("dark", "light"):
            widgets = self.widgets(self.render(mode))
            geometry = [(kind, key, value) for kind, props in widgets for key, value in props.items()
                        if key in ("size", "position", "rounding") or key.endswith(("_size", "_thickness"))]
            self.assertGreater(len([g for g in geometry if g[1] == "position"]), 8)
            for kind, key, value in geometry:
                if key not in fractional:
                    self.assertNotRegex(value, r"\d\.\d", (mode, kind, key))
                    self.assertRegex(value, r"^-?\d+%?(, -?\d+%?)?$", (mode, kind, key))
            numbers = [(kind, key, value) for kind, props in widgets for key, value in props.items()
                       if key not in fractional and not key.endswith(("text", "path"))]
            for kind, key, value in numbers:
                self.assertNotRegex(value, r"\d\.\d", (mode, kind, key))

    def test_render_hyprlock_matches_greeter_text(self):
        rendered = run_cli(
            "render", "hyprlock", "--mode", "dark",
            "--palette", str(PALETTE), "--logo-dir", "/logos",
        ).stdout
        # LoginScreen.qml at 1080p: 0.09 H = 97 px clock (73 pt), 0.03 H =
        # 32 px "dddd d MMMM yyyy" date (24 pt), `host · vitta <version>`.
        self.assertIn('date "+<b>%H:%M</b>"\n    color = rgba(ebdbb2ff)\n    font_size = 73\n', rendered)
        self.assertIn('date "+%A %-d %B %Y"\n    color = rgba(a89984ff)\n    font_size = 24\n', rendered)
        # The greeter's fields are 380 x 48 at u = H / 800, border max(2, 2u).
        self.assertIn("input-field {\n    monitor =\n    size = 513, 65\n    outline_thickness = 3\n", rendered)
        self.assertIn('date "+%A %-d %B %Y"', rendered)
        self.assertIn(
            'echo "$(uname -n) · vitta $(. /etc/os-release; echo ${IMAGE_VERSION:-$VERSION_ID})"',
            rendered,
        )
        self.assertNotIn("$HOSTNAME", rendered)

if __name__ == "__main__":
    unittest.main()
