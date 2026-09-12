"""Offline regression tests for the COPR freshness CI gate."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
COPR = "https://copr.fedorainfracloud.org/api_3"
CHROOT = "fedora-44-x86_64"


class CoprFreshnessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.responses = {}
        self.now = int(time.time())
        for owner, project, package, upstream in (
            ("lionheartp", "Hyprland", "hyprlock", "hyprwm/hyprlock"),
            ("sneexy", "zen-browser", "zen-browser", "zen-browser/desktop"),
            ("barsnick", "non-fed", "showmethekey", "AlynxZhou/showmethekey"),
        ):
            self.responses[f"https://api.github.com/repos/{upstream}/releases/latest"] = {
                "tag_name": "v1.0.0", "published_at": "2026-01-01T00:00:00Z"
            }
            self.responses[self.package_url(owner, project, package)] = {
                "builds": {"latest": {"source_package": {"version": "1.0.0-1"}}}
            }
        self.responses["https://git.dec05eba.com/gpu-screen-recorder/plain/meson.build"] = (
            "project('gpu-screen-recorder', 'c', version : '6.1.1')\n"
        )
        self.responses["https://git.dec05eba.com/gpu-screen-recorder/atom/"] = (
            "<entry>\n<title>6.1.1</title>\n"
            "<published>2026-01-01T00:00:00Z</published>\n</entry>\n"
        )
        # Reproduce September 10/11: latest submission is Rawhide-only.
        self.responses[self.package_url("lionheartp", "Hyprland", "gpu-screen-recorder")] = {
            "builds": {"latest": {
                "id": 10965656, "state": "succeeded",
                "chroots": ["fedora-rawhide-x86_64"], "ended_on": self.now,
                "source_package": {"version": "6.1.1-2"},
            }}
        }
        self.target = {"state": "succeeded", "build_id": 10961079, "pkg_version": "6.1.1-1"}
        self.chroots = {CHROOT: self.target, "fedora-rawhide-x86_64": {
            "state": "succeeded", "build_id": 10965656, "pkg_version": "6.1.1-2"
        }}
        self.responses[f"{COPR}/monitor?ownername=lionheartp&projectname=Hyprland"] = {
            "packages": [{"name": "gpu-screen-recorder", "chroots": self.chroots}]
        }
        self.build = {"name": CHROOT, "state": "succeeded", "ended_on": self.now - 86400}
        self.responses[f"{COPR}/build-chroot?build_id=10961079&chrootname={CHROOT}"] = self.build
        curl = self.directory / "curl"
        curl.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['CURL_FIXTURES']) as f: responses = json.load(f)\n"
            "url = sys.argv[-1]\n"
            "if url not in responses:\n"
            "    print('Unexpected URL: ' + url, file=sys.stderr)\n"
            "    sys.exit(22)\n"
            "value = responses[url]\n"
            "print(value if isinstance(value, str) else json.dumps(value))\n"
        )
        curl.chmod(0o755)

    @staticmethod
    def package_url(owner, project, package):
        return (f"{COPR}/package?ownername={owner}&projectname={project}"
                f"&packagename={package}&with_latest_build=true")

    def run_audit(self):
        fixtures = self.directory / "responses.json"
        fixtures.write_text(json.dumps(self.responses))
        return subprocess.run(
            ["bash", str(ROOT / "scripts/audit-copr-freshness.sh")],
            env={**os.environ, "PATH": f"{self.directory}:{os.environ['PATH']}",
                 "CURL_FIXTURES": str(fixtures), "GH_TOKEN": ""},
            capture_output=True, text=True, timeout=15,
        )

    def test_newer_rawhide_build_does_not_hide_successful_target(self):
        result = self.run_audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("gpu-screen-recorder COPR=6.1.1-1", result.stdout)

    def test_unrelated_chroot_failure_does_not_reject_target(self):
        self.chroots["fedora-rawhide-x86_64"]["state"] = "failed"
        result = self.run_audit()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_target_fails(self):
        del self.chroots[CHROOT]
        self.assertNotEqual(self.run_audit().returncode, 0)

    def test_failed_target_fails(self):
        self.target["state"] = "failed"
        self.assertNotEqual(self.run_audit().returncode, 0)

    def test_failed_build_chroot_fails(self):
        self.build["state"] = "failed"
        self.assertNotEqual(self.run_audit().returncode, 0)

    def test_old_target_fails_despite_fresh_rawhide(self):
        self.build["ended_on"] = self.now - 91 * 86400
        result = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("maximum 90d", result.stderr)

    def test_stale_target_fails_despite_current_rawhide(self):
        self.target["pkg_version"] = "6.1.0-1"
        result = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is stale", result.stderr)

    def test_packaging_grace_period_remains(self):
        self.target["pkg_version"] = "6.1.0-1"
        published = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self.now - 86400))
        self.responses["https://git.dec05eba.com/gpu-screen-recorder/atom/"] = (
            f"<entry>\n<title>6.1.1</title>\n<published>{published}</published>\n</entry>\n"
        )
        result = self.run_audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("grace period", result.stderr)

    def test_missing_or_invalid_build_timestamp_fails(self):
        for value in (None, "invalid"):
            with self.subTest(value=value):
                self.build["ended_on"] = value
                self.assertNotEqual(self.run_audit().returncode, 0)

    def test_missing_monitor_metadata_fails(self):
        self.responses[f"{COPR}/monitor?ownername=lionheartp&projectname=Hyprland"] = {}
        self.assertNotEqual(self.run_audit().returncode, 0)


if __name__ == "__main__":
    unittest.main()
