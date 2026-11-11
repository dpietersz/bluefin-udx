"""Behavioural checks for selecting the DRM device that drives Vitta's greeter."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
VITTA = ROOT / "files/vitta"
HELPER = VITTA / "usr/libexec/vitta/vitta-greeter-gpu"
LAUNCHER = VITTA / "usr/libexec/vitta/vitta-greeter"


class VittaGreeterGpuTests(unittest.TestCase):
    def make_sysfs(self, tmp):
        drm = tmp / "class/drm"
        drm.mkdir(parents=True)
        return drm

    def add_card(self, drm, number, boot_vga=None):
        card = drm / f"card{number}"
        card.mkdir()
        if boot_vga is not None:
            device = card / "device"
            device.mkdir()
            (device / "boot_vga").write_text(f"{boot_vga}\n")
        return card

    def add_edp(self, drm, number, status):
        connector = drm / f"card{number}-eDP-1"
        connector.mkdir()
        (connector / "status").write_text(f"{status}\n")

    def run_helper(self, sysfs_root):
        return subprocess.run(
            ["bash", str(HELPER)],
            env=os.environ | {"VITTA_SYSFS_ROOT": str(sysfs_root)},
            capture_output=True,
            text=True,
            check=False,
        )

    def test_single_gpu_prints_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            drm = self.make_sysfs(Path(tmp))
            self.add_card(drm, 0, boot_vga=1)
            self.add_edp(drm, 0, "connected")
            result = self.run_helper(tmp)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_p14s_topology(self):
        with tempfile.TemporaryDirectory() as tmp:
            drm = self.make_sysfs(Path(tmp))
            self.add_card(drm, 0, boot_vga=1)
            self.add_edp(drm, 0, "connected")
            self.add_card(drm, 1, boot_vga=0)
            result = self.run_helper(tmp)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "/dev/dri/card0\n")

    def test_swapped_numbering(self):
        with tempfile.TemporaryDirectory() as tmp:
            drm = self.make_sysfs(Path(tmp))
            self.add_card(drm, 0, boot_vga=0)
            self.add_card(drm, 1, boot_vga=1)
            self.add_edp(drm, 1, "connected")
            result = self.run_helper(tmp)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "/dev/dri/card1\n")

    def test_lid_closed_docked(self):
        with tempfile.TemporaryDirectory() as tmp:
            drm = self.make_sysfs(Path(tmp))
            self.add_card(drm, 0, boot_vga=1)
            self.add_edp(drm, 0, "disconnected")
            self.add_card(drm, 1, boot_vga=0)
            result = self.run_helper(tmp)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "/dev/dri/card0\n")

    def test_no_hint_prints_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            drm = self.make_sysfs(Path(tmp))
            self.add_card(drm, 0)
            self.add_card(drm, 1)
            result = self.run_helper(tmp)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_missing_sysfs_exits_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_helper(Path(tmp) / "missing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def run_launcher(self, sysfs_root, helper, inherited_wlr=None):
        with tempfile.TemporaryDirectory() as tmp:
            fake_bin = Path(tmp) / "bin"
            fake_bin.mkdir()
            cage = fake_bin / "cage"
            cage.write_text(
                "#!/bin/bash\n"
                "if [ \"${WLR_DRM_DEVICES+x}\" = x ]; then\n"
                "    printf '%s\\n' \"$WLR_DRM_DEVICES\"\n"
                "else\n"
                "    printf 'unset\\n'\n"
                "fi\n"
            )
            cage.chmod(0o755)
            env = os.environ | {
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "VITTA_SYSFS_ROOT": str(sysfs_root),
                "VITTA_GREETER_GPU_HELPER": str(helper),
            }
            if inherited_wlr is None:
                env.pop("WLR_DRM_DEVICES", None)
            else:
                env["WLR_DRM_DEVICES"] = inherited_wlr
            return subprocess.run(
                ["bash", str(LAUNCHER)],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

    def test_launcher_exports_only_when_set(self):
        script = LAUNCHER.read_text()
        self.assertIn("WLR_DRM_DEVICES", script)
        self.assertIn("exec cage -d -s -m last -- quickshell ", script)

        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            drm = self.make_sysfs(tmp / "multi")
            self.add_card(drm, 0, boot_vga=1)
            self.add_edp(drm, 0, "connected")
            self.add_card(drm, 1, boot_vga=0)
            pinned = self.run_launcher(tmp / "multi", HELPER)

            single = self.make_sysfs(tmp / "single")
            self.add_card(single, 0, boot_vga=1)
            self.add_edp(single, 0, "connected")
            unpinned = self.run_launcher(tmp / "single", HELPER)

        self.assertEqual(pinned.returncode, 0, pinned.stderr)
        self.assertEqual(pinned.stdout, "/dev/dri/card0\n")
        self.assertEqual(unpinned.returncode, 0, unpinned.stderr)
        self.assertEqual(unpinned.stdout, "unset\n")

    def test_launcher_falls_back_when_helper_is_unusable(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            sysfs = self.make_sysfs(tmp / "sysfs")
            self.add_card(sysfs, 0, boot_vga=1)
            self.add_card(sysfs, 1, boot_vga=0)
            failing = tmp / "failing-helper"
            failing.write_text("#!/bin/bash\nexit 1\n")
            failing.chmod(0o755)
            garbage = tmp / "garbage-helper"
            garbage.write_text("#!/bin/bash\nprintf '%s\\n' not-a-drm-node\n")
            garbage.chmod(0o755)
            not_executable = tmp / "not-executable-helper"
            not_executable.write_text("#!/bin/bash\nprintf '%s\\n' /dev/dri/card0\n")

            for helper in (tmp / "missing-helper", not_executable, failing, garbage):
                with self.subTest(helper=helper.name):
                    result = self.run_launcher(sysfs.parent, helper, "/dev/dri/card9")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, "unset\n")


if __name__ == "__main__":
    unittest.main()
