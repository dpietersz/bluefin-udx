"""Static regression checks for Vitta overlay files the smoke gate cannot boot.

The smoke gates assert the same facts inside the built image; these run in
seconds without a build.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
VITTA = ROOT / "files/vitta"


class VittaOverlayTests(unittest.TestCase):
    def test_greeter_cage_uses_one_output(self):
        # cage's default -m extend spans every monitor: a docked laptop would
        # centre the login card on the seam between screens.
        script = (VITTA / "usr/libexec/vitta/vitta-greeter").read_text()
        self.assertRegex(script, r"(?m)^exec cage -s -m last -- quickshell ")

    def test_tmpfiles_recreates_greeter_portal_mask(self):
        # greetd's %post mask lives in the image /var, which a rebase never applies.
        lines = [
            line.split()
            for line in (VITTA / "usr/lib/tmpfiles.d/vitta-greetd.conf").read_text().splitlines()
            if line.strip() and not line.startswith("#")
        ]
        home = "/var/lib/greetd"
        for path in (home, f"{home}/.config", f"{home}/.config/systemd", f"{home}/.config/systemd/user"):
            self.assertIn(path, [fields[1] for fields in lines if fields[0] == "d"])
        self.assertIn(
            ["L", f"{home}/.config/systemd/user/xdg-desktop-portal.service", "-", "-", "-", "-", "/dev/null"],
            lines,
        )

    def test_pam_password_substack_reaches_keyring(self):
        # `include` would inline pam_unix "sufficient" and end the stack before
        # the keyring line; gdm-password uses substack for the same reason.
        pam = (VITTA / "etc/pam.d/greetd").read_text()
        self.assertRegex(pam, r"(?m)^password\s+substack\s+system-auth\s*$")
        self.assertNotRegex(pam, r"(?m)^password\s+include\s+system-auth")
        substack = re.search(r"(?m)^password\s+substack", pam).start()
        keyring = re.search(r"(?m)^-password\s+optional\s+pam_gnome_keyring\.so\s+use_authtok\s*$", pam).start()
        self.assertLess(substack, keyring)


if __name__ == "__main__":
    unittest.main()
