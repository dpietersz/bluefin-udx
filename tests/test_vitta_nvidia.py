"""Static regression checks for the Vitta NVIDIA recipe and its private overlay."""

import os
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
RECIPE = ROOT / "recipes/vitta-nvidia.yml"


class VittaNvidiaRecipeTests(unittest.TestCase):
    def recipe_text(self):
        self.assertTrue(RECIPE.is_file(), "vitta-nvidia recipe must exist")
        return RECIPE.read_text()

    def test_identity(self):
        recipe = self.recipe_text()
        for value in (
            "name: vitta-nvidia",
            "base-image: ghcr.io/ublue-os/base-main",
            "image-version: 44",
            "ID: vitta",
            "ID_LIKE: fedora",
            'NAME: "Vitta"',
            'PRETTY_NAME: "Vitta 44 (NVIDIA)"',
            "VARIANT_ID: vitta-nvidia",
            "IMAGE_ID: vitta-nvidia",
        ):
            with self.subTest(value=value):
                self.assertRegex(recipe, rf"(?m)^\s*{re.escape(value)}$")

    def test_module_order(self):
        recipe = self.recipe_text()
        modules = "\n".join(
            line for line in recipe.splitlines() if not line.lstrip().startswith("#")
        )
        markers = (
            "source: system",
            "- from-file: common.yml",
            "- from-file: vitta-modules.yml",
            "- type: akmods",
            "nvidia-driver: nvidia-open",
            "- type: rpm-ostree",
            "- type: os-release",
            "- type: initramfs",
        )
        positions = [modules.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(modules.rstrip().splitlines()[-1], "  - type: initramfs")

    def test_nvidia_driver_comes_from_akmods_module(self):
        recipe = self.recipe_text()
        self.assertRegex(
            recipe,
            r"(?m)^  - type: akmods\n    install: \[\]\n    nvidia-driver: nvidia-open$",
        )
        for recipe_path in (ROOT / "recipes/vitta.yml", ROOT / "recipes/vitta-modules.yml"):
            with self.subTest(recipe=recipe_path.name):
                recipe = recipe_path.read_text()
                self.assertNotIn("nvidia-driver", recipe)
                self.assertNotIn("base-nvidia", recipe)

    def test_no_own_kargs_file(self):
        self.assertEqual(list((ROOT / "files").glob("**/kargs.d/*.toml")), [])
        for recipe_path in (ROOT / "recipes").glob("*.yml"):
            with self.subTest(recipe=recipe_path.name):
                self.assertNotIn("source: vitta-nvidia", recipe_path.read_text())

    def test_no_cuda_toolkit(self):
        self.assertNotIn("- cuda-toolkit", self.recipe_text())

    def test_fprintd_is_shared(self):
        shared = (ROOT / "recipes/vitta-modules.yml").read_text()
        for package in ("fprintd", "fprintd-pam"):
            with self.subTest(package=package):
                self.assertRegex(shared, rf"(?m)^\s+- {re.escape(package)}(\s+#.*)?$")
                self.assertNotRegex(self.recipe_text(), rf"(?m)^\s+- {re.escape(package)}(\s+#.*)?$")


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

    def test_gates_probe_greetd_auth(self):
        probes = (
            'timeout -k 5 25 python3 /smoke/pam_probe.py greetd vittaprobe "$VITTA_PROBE_PW" --expect success --max-seconds 5',
            'timeout -k 5 25 python3 /smoke/pam_probe.py greetd vittaprobe "wrong-$VITTA_PROBE_PW" --expect fail --max-seconds 10',
            'timeout -k 5 25 python3 /smoke/pam_probe.py greetd vittaprobe "" --expect fail --max-seconds 10',
            'grep -Ev "^-?auth[[:space:]].*(pam_gnome_keyring|pam_kwallet)" /etc/pam.d/greetd > /etc/pam.d/vittaprobe-nokeyring',
            'timeout -k 5 25 python3 /smoke/pam_probe.py vittaprobe-nokeyring vittaprobe "$VITTA_PROBE_PW" --expect success --max-seconds 5',
        )
        for gate, mount in (
            (self.BUILD_WORKFLOW, '-v "$GITHUB_WORKSPACE/tests/smoke:/smoke:ro"'),
            (self.LOCAL_GATE, '-v "$REPO_ROOT/tests/smoke:/smoke:ro,z"'),
        ):
            text = gate.read_text()
            with self.subTest(gate=gate.name):
                self.assertIn(mount, text)
                for probe in probes:
                    self.assertIn(probe, text)
                self.assertEqual(text.count("python3 /smoke/pam_probe.py"), 4)
                self.assertNotIn("--expect-message", text)
                self.assertNotIn("--forbid-message", text)
                for line in (
                    "check_rpm fprintd\n",
                    "check_rpm fprintd-pam\n",
                    "check_file /usr/lib64/security/pam_fprintd.so\n",
                ):
                    self.assertIn(line, text)

    def test_local_gate_run_variables_are_assigned_before_use(self):
        lines = self.LOCAL_GATE.read_text().splitlines()
        run_index = next(index for index, line in enumerate(lines) if line.startswith("$RUNNER run "))
        run_line = lines[run_index]
        variables = {
            match.group("braced") or match.group("plain")
            for match in re.finditer(
                r"\$(?:\{(?P<braced>[A-Za-z_][A-Za-z0-9_]*)\}|(?P<plain>[A-Za-z_][A-Za-z0-9_]*))",
                run_line,
            )
        }
        assigned_before_run = {
            match.group(1)
            for line in lines[:run_index]
            if (match := re.match(r"\s*(?:export )?([A-Za-z_][A-Za-z0-9_]*)=", line))
        }
        self.assertEqual(variables, {"RUNNER", "RECIPE", "REPO_ROOT", "IMAGE"})
        self.assertTrue(
            variables <= assigned_before_run,
            f"variables used before assignment: {sorted(variables - assigned_before_run)}",
        )

    def test_nvidia_kargs_come_from_akmods_module(self):
        for gate in (self.BUILD_WORKFLOW, self.LOCAL_GATE):
            with self.subTest(gate=gate):
                text = gate.read_text()
                self.assertIn("/usr/lib/bootc/kargs.d/00-bluebuild-nvidia-kargs.toml", text)
                self.assertNotIn("10-vitta-nvidia.toml", text)

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

    def test_promotion_rejects_unsupported_image_names(self):
        workflow = self.PROMOTION_WORKFLOW.read_text()
        run_scripts = re.findall(r"(?ms)^        run: \|\n(.*?)(?=^      - |\Z)", workflow)
        for script in run_scripts:
            with self.subTest(script=script):
                self.assertNotIn("inputs.image", script)

        validation = re.search(
            r'(?ms)^          case "\$IMAGE_NAME" in\n.*?^          esac$',
            workflow,
        )
        self.assertIsNotNone(validation, "promotion workflow must validate IMAGE_NAME")
        snippet = validation.group(0)
        for image_name in ("vitta", "vitta-nvidia"):
            with self.subTest(image_name=image_name):
                result = subprocess.run(
                    ["bash", "-c", snippet],
                    env=os.environ | {"IMAGE_NAME": image_name},
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
        for image_name in ("vitta-evil", "bluefin-udx", "", "vitta/../x"):
            with self.subTest(image_name=image_name):
                result = subprocess.run(
                    ["bash", "-c", snippet],
                    env=os.environ | {"IMAGE_NAME": image_name},
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("::error::", result.stdout)


if __name__ == "__main__":
    unittest.main()
