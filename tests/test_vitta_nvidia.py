"""Static regression checks for the Vitta NVIDIA recipe and its private overlay."""

from pathlib import Path
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / "recipes/vitta-nvidia.yml"
KARGS = ROOT / "files/vitta-nvidia/usr/lib/bootc/kargs.d/10-vitta-nvidia.toml"


class VittaNvidiaRecipeTests(unittest.TestCase):
    def recipe_text(self):
        self.assertTrue(RECIPE.is_file(), "vitta-nvidia recipe must exist")
        return RECIPE.read_text()

    def test_identity(self):
        recipe = self.recipe_text()
        self.assertIn("name: vitta-nvidia", recipe)
        self.assertIn("base-image: ghcr.io/ublue-os/base-nvidia", recipe)
        self.assertIn("image-version: 44", recipe)
        for value in (
            "ID: vitta",
            "ID_LIKE: fedora",
            'NAME: "Vitta"',
            'PRETTY_NAME: "Vitta 44 (NVIDIA)"',
            "VARIANT_ID: vitta-nvidia",
            "IMAGE_ID: vitta-nvidia",
        ):
            with self.subTest(value=value):
                self.assertIn(value, recipe)

    def test_module_order(self):
        recipe = self.recipe_text()
        markers = (
            "source: system",
            "- from-file: common.yml",
            "- from-file: vitta-modules.yml",
            "source: vitta-nvidia",
            "- type: rpm-ostree",
            "- type: os-release",
            "- type: initramfs",
        )
        positions = [recipe.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(recipe.rstrip().splitlines()[-1], "  - type: initramfs")

    def test_kargs_exact(self):
        self.assertTrue(KARGS.is_file(), "vitta-nvidia kernel-args overlay must exist")
        with KARGS.open("rb") as file:
            self.assertEqual(
                tomllib.load(file),
                {
                    "kargs": [
                        "rd.driver.blacklist=nouveau",
                        "modprobe.blacklist=nouveau",
                        "nvidia-drm.modeset=1",
                        "initcall_blacklist=simpledrm_platform_driver_init",
                    ]
                },
            )

    def test_overlay_is_nvidia_only(self):
        self.assertIn("source: vitta-nvidia", self.recipe_text())
        for recipe_path in (ROOT / "recipes").glob("*.yml"):
            if recipe_path != RECIPE:
                with self.subTest(recipe=recipe_path.name):
                    self.assertNotIn("source: vitta-nvidia", recipe_path.read_text())
        for recipe_path in (ROOT / "recipes/vitta.yml", ROOT / "recipes/vitta-modules.yml"):
            recipe = recipe_path.read_text()
            with self.subTest(recipe=recipe_path.name):
                self.assertNotIn("vitta-nvidia", recipe)
                self.assertNotIn("base-nvidia", recipe)

    def test_no_cuda_toolkit(self):
        self.assertNotIn("- cuda-toolkit", self.recipe_text())


if __name__ == "__main__":
    unittest.main()
