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
        self.assertEqual(
            out("palette", "--mode", "dark", "--json"),
            {
                "bg": "#282828",
                "fg": "#ebdbb2",
                "stripe1": "#689d6a",
                "stripe2": "#ebdbb2",
                "stripe3": "#d65d0e",
                "stripe4": "#cc241d",
                "muted": "#a89984",
                "error": "#fb4934",
            },
        )

    def test_palette_light_stripe2_is_fg(self):
        palette = out("palette", "--mode", "light", "--json")
        self.assertEqual(palette["stripe2"], "#3c3836")
        self.assertEqual(palette["stripe2"], palette["fg"])
        self.assertEqual(palette["bg"], "#fbf1c7")

    def test_render_hyprlock_has_four_concentric_shapes_in_order(self):
        rendered = run_cli(
            "render", "hyprlock", "--mode", "dark",
            "--palette", str(PALETTE), "--logo-dir", "/logos",
        ).stdout
        self.assertEqual(rendered.splitlines()[0], "# vitta-theme render hyprlock --mode dark")
        light = run_cli(
            "render", "hyprlock", "--mode", "light",
            "--palette", str(PALETTE), "--logo-dir", "/logos",
        ).stdout
        self.assertEqual(light.splitlines()[0], "# vitta-theme render hyprlock --mode light")
        # R19: flat filled bands in painter's order (stripe1 outermost first,
        # then stripe2..4 each inset 5 px, then the card fill in bg), no
        # borders or shadows, concentric radii 24 - 5*i.
        shapes = re.findall(r"shape \{\n(.*?)\n\}", rendered, re.DOTALL)
        self.assertEqual(len(shapes), 5)
        self.assertEqual(
            [re.search(r"^    color = (rgba\([^)]*\))$", shape, re.MULTILINE).group(1) for shape in shapes],
            ["rgba(689d6aff)", "rgba(ebdbb2ff)", "rgba(d65d0eff)", "rgba(cc241dff)", "rgba(282828ff)"],
        )
        sizes = [
            tuple(map(int, re.search(r"size = (\d+), (\d+)", shape).groups()))
            for shape in shapes
        ]
        self.assertEqual(sizes[0], (560, 460))
        self.assertTrue(all(
            previous[0] - current[0] == 10 and previous[1] - current[1] == 10
            for previous, current in zip(sizes, sizes[1:])
        ))
        self.assertEqual(
            [int(re.search(r"rounding = (\d+)", shape).group(1)) for shape in shapes],
            [24, 19, 14, 9, 4],
        )
        self.assertTrue(all("border_size = 0" in shape for shape in shapes))
        self.assertTrue(all("shadow_passes = 0" in shape for shape in shapes))
        self.assertNotIn("border_color", rendered)
        self.assertIn("background {\n    monitor =\n    color = rgba(282828ff)", rendered)
        self.assertIn("font_family = Monaspace Neon", rendered)
        self.assertIn("path = /logos/logo-dark.png", rendered)
        self.assertNotIn("general {", rendered)
        self.assertNotIn("auth {", rendered)

    def test_render_hyprlock_pins_painters_order_with_zindex(self):
        """hyprlock sorts widgets by zindex with an unstable sort, so the band
        order must not rest on file order: background < stripe1 < ... < card
        fill < every content widget (image, input, labels keep the default 0).
        """
        rendered = run_cli(
            "render", "hyprlock", "--mode", "light",
            "--palette", str(PALETTE), "--logo-dir", "/logos",
        ).stdout
        def zindex(block):
            match = re.search(r"zindex = (-?\d+)", block)
            return int(match.group(1)) if match else None
        background = re.findall(r"^background \{\n(.*?)\n\}", rendered, re.DOTALL | re.MULTILINE)
        shapes = re.findall(r"^shape \{\n(.*?)\n\}", rendered, re.DOTALL | re.MULTILINE)
        content = [
            block
            for kind in ("image", "input-field", "label")
            for block in re.findall(rf"^{kind} \{{\n(.*?)\n\}}", rendered, re.DOTALL | re.MULTILINE)
        ]
        self.assertEqual(len(background), 1)
        order = [zindex(background[0])] + [zindex(shape) for shape in shapes]
        self.assertNotIn(None, order)
        self.assertEqual(order, sorted(set(order)), "background and bands must have strictly rising zindex")
        self.assertLess(order[-1], 0, "card fill must stay below content widgets (default zindex 0)")
        self.assertEqual(len(content), 5)
        self.assertTrue(all(zindex(block) is None for block in content))

    def render_boxes(self):
        """Return (inner card half-extents, [(kind, x0, x1, y0, y1), ...]).

        hyprlock centres each widget on its `position` (halign/valign center,
        y up). Image and input boxes use their `size`. A label's box height is
        estimated as 1.3 x its pixel size; hyprlock's font_size is Pango
        points at 96 dpi (px = pt * 4/3). Label width is taken as the whole
        inner card: every label is centred, so only vertical room matters.
        """
        rendered = run_cli(
            "render", "hyprlock", "--mode", "dark",
            "--palette", str(PALETTE), "--logo-dir", "/logos",
        ).stdout
        shapes = re.findall(r"shape \{\n(.*?)\n\}", rendered, re.DOTALL)
        inner_width, inner_height = map(
            int, re.search(r"size = (\d+), (\d+)", shapes[-1]).groups()
        )
        max_x = inner_width / 2 - 12
        max_y = inner_height / 2 - 12

        boxes = []
        for kind in ("image", "input-field", "label"):
            for block in re.findall(rf"^{kind} \{{\n(.*?)\n\}}", rendered, re.DOTALL | re.MULTILINE):
                x, y = map(int, re.search(r"position = (-?\d+), (-?\d+)", block).groups())
                if kind == "label":
                    font_px = int(re.search(r"font_size = (\d+)", block).group(1)) * 96 / 72
                    width, height = 2 * max_x, font_px * 1.3
                else:
                    width, height = map(
                        int, re.search(r"size = (\d+), (\d+)", block).groups()
                    )
                boxes.append((kind, x - width / 2, x + width / 2, y - height / 2, y + height / 2))
        return (max_x, max_y), boxes

    def test_render_hyprlock_keeps_content_inside_innermost_shape(self):
        (max_x, max_y), boxes = self.render_boxes()
        self.assertEqual([kind for kind, *_ in boxes].count("label"), 3)
        self.assertEqual(len(boxes), 5)
        for kind, x0, x1, y0, y1 in boxes:
            self.assertLessEqual(max(abs(x0), abs(x1)), max_x, kind)
            self.assertLessEqual(max(abs(y0), abs(y1)), max_y, kind)

    def test_render_hyprlock_widgets_do_not_overlap(self):
        _, boxes = self.render_boxes()
        for index, first in enumerate(boxes):
            for second in boxes[index + 1:]:
                overlap_x = first[1] < second[2] and second[1] < first[2]
                overlap_y = first[3] < second[4] and second[3] < first[4]
                self.assertFalse(overlap_x and overlap_y, f"{first} overlaps {second}")

    def test_render_hyprlock_matches_greeter_text(self):
        rendered = run_cli(
            "render", "hyprlock", "--mode", "dark",
            "--palette", str(PALETTE), "--logo-dir", "/logos",
        ).stdout
        # Card.qml: 72 px clock, "dddd d MMMM yyyy" date, `host · vitta <version>`.
        self.assertIn('date "+<b>%H:%M</b>"\n    color = rgba(ebdbb2ff)\n    font_size = 54\n', rendered)
        self.assertIn('date "+%A %-d %B %Y"', rendered)
        self.assertIn(
            'echo "$(uname -n) · vitta $(. /etc/os-release; echo ${IMAGE_VERSION:-$VERSION_ID})"',
            rendered,
        )
        self.assertNotIn("$HOSTNAME", rendered)

if __name__ == "__main__":
    unittest.main()
