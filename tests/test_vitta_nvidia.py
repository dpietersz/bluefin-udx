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


class VittaNvidiaCiTests(unittest.TestCase):
    BUILD_WORKFLOW = ROOT / ".github/workflows/build.yml"
    LOCAL_GATE = ROOT / "scripts/local-build-test.sh"
    PROMOTION_WORKFLOW = ROOT / ".github/workflows/promote-vitta.yml"

    def test_matrix_has_testing_leg(self):
        workflow = self.BUILD_WORKFLOW.read_text()
        self.assertRegex(
            workflow,
            r"(?ms)^        include:\n.*?^          - recipe: vitta-nvidia\n            stream: testing$",
        )

    def test_publish_allow_list(self):
        workflow = self.BUILD_WORKFLOW.read_text()
        self.assertIn("vitta-nvidia:testing", workflow)
        self.assertNotIn("vitta-nvidia:stable", workflow)

    def test_gates_use_flags(self):
        for gate in (self.BUILD_WORKFLOW, self.LOCAL_GATE):
            with self.subTest(gate=gate):
                text = gate.read_text()
                self.assertRegex(text, r"vitta\|vitta-nvidia\).*IS_VITTA=1")
                self.assertRegex(text, r"bluefin-udx-nvidia\|vitta-nvidia\).*IS_NVIDIA=1")
                self.assertNotIn('"$RECIPE_NAME" = "vitta"', text)
                self.assertNotIn('"$RECIPE_NAME" = "bluefin-udx-nvidia"', text)

    def test_smoke_block_rules(self):
        workflow = self.BUILD_WORKFLOW.read_text()
        smoke = workflow[workflow.index("      - name: Smoke-boot test"):workflow.index("      # Push (only on main", workflow.index("      - name: Smoke-boot test"))]
        run = smoke.split("        run: |\n", 1)[1]
        self.assertNotIn("${{", run)
        body = run.split("-c '\n", 1)[1].rsplit("\n          '", 1)[0]
        self.assertNotIn("'", body)

    def test_fedora_next_covers_recipe(self):
        workflow = self.BUILD_WORKFLOW.read_text()
        self.assertIn(
            "RECIPES: recipes/common.yml recipes/vitta.yml recipes/vitta-modules.yml recipes/vitta-nvidia.yml",
            workflow,
        )

    def test_promotion_takes_image(self):
        workflow = self.PROMOTION_WORKFLOW.read_text()
        self.assertRegex(workflow, r"(?ms)^      image:\n.*?^        type: choice$")
        self.assertIn("          - vitta", workflow)
        self.assertIn("          - vitta-nvidia", workflow)
        self.assertIn("        default: vitta", workflow)
        self.assertIn("IMAGE_NAME: ${{ inputs.image }}", workflow)
        self.assertIn('IMAGE_REGISTRY="ghcr.io/${GITHUB_REPOSITORY_OWNER}/${IMAGE_NAME}"', workflow)
        self.assertNotIn("IMAGE_REGISTRY: ghcr.io/${{ github.repository_owner }}/${IMAGE_NAME}", workflow)
        self.assertNotIn("ghcr.io/${{ github.repository_owner }}/vitta\n", workflow)


if __name__ == "__main__":
    unittest.main()
