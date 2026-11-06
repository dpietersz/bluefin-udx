"""Regression tests for the Vitta day/night theme CLI."""

from datetime import date, datetime
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from zoneinfo import ZoneInfo


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
        shapes = re.findall(r"shape \{\n(.*?)\n\}", rendered, re.DOTALL)
        self.assertEqual(len(shapes), 4)
        self.assertEqual(
            [re.search(r"border_color = (rgba\([^)]*\))", shape).group(1) for shape in shapes],
            ["rgba(689d6aff)", "rgba(ebdbb2ff)", "rgba(d65d0eff)", "rgba(cc241dff)"],
        )
        sizes = [
            tuple(map(int, re.search(r"size = (\d+), (\d+)", shape).groups()))
            for shape in shapes
        ]
        self.assertTrue(all(
            previous[0] - current[0] == 10 and previous[1] - current[1] == 10
            for previous, current in zip(sizes, sizes[1:])
        ))
        self.assertEqual(
            [int(re.search(r"rounding = (\d+)", shape).group(1)) for shape in shapes],
            [14, 9, 4, 0],
        )
        self.assertTrue(all("border_size = 5" in shape for shape in shapes))
        self.assertIn("background {\n    monitor =\n    color = rgba(282828ff)", rendered)
        self.assertIn("color = rgba(282828ff)", shapes[-1])
        self.assertIn("font_family = Monaspace Neon", rendered)
        self.assertIn("path = /logos/logo-dark.png", rendered)
        self.assertNotIn("general {", rendered)
        self.assertNotIn("auth {", rendered)


if __name__ == "__main__":
    unittest.main()
