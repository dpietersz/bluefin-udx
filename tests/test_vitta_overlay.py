"""Static regression checks for Vitta overlay files the smoke gate cannot boot.

The smoke gates assert the same facts inside the built image; these run in
seconds without a build.
"""

import contextlib
import importlib.util
from importlib.machinery import SourceFileLoader
import io
from pathlib import Path
import re
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
VITTA = ROOT / "files/vitta"
SHADOW_SYNC = VITTA / "usr/libexec/vitta/vitta-shadow-sync"


def load_shadow_sync():
    loader = SourceFileLoader("vitta_shadow_sync", str(SHADOW_SYNC))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


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

    def test_shadow_sync_unit_runs_before_logins_and_is_enabled(self):
        # user@<greetd uid> fails in pam_unix account without a shadow entry;
        # the entry must exist before greetd (After=systemd-user-sessions).
        unit = (VITTA / "usr/lib/systemd/system/vitta-shadow-sync.service").read_text()
        self.assertRegex(unit, r"(?m)^After=.*\bsystemd-sysusers\.service\b")
        self.assertRegex(unit, r"(?m)^Before=.*\bsystemd-user-sessions\.service\b")
        self.assertRegex(unit, r"(?m)^ExecStart=/usr/libexec/vitta/vitta-shadow-sync$")
        self.assertRegex(unit, r"(?m)^WantedBy=sysinit\.target$")
        self.assertTrue(SHADOW_SYNC.stat().st_mode & 0o111)
        recipe = (ROOT / "recipes/vitta-modules.yml").read_text()
        self.assertRegex(recipe, r"(?m)^\s+- vitta-shadow-sync\.service\s*$")

    def test_shadow_sync_adds_locked_entries_only_for_image_accounts(self):
        # The T580 state: greetd moved to /usr/lib/passwd by rpm-ostree
        # layering, /etc/shadow kept from before the rebase.
        sync = load_shadow_sync()
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "lib-passwd").write_text(
                "root:x:0:0:root:/root:/bin/bash\n"
                "dbus:x:81:81:System message bus:/:/usr/sbin/nologin\n"
                "greetd:x:965:965:greetd daemon:/var/lib/greetd:/usr/sbin/nologin\n"
                "nopw:*:970:970::/:/usr/sbin/nologin\n"
                "localonly:x:971:971::/:/usr/sbin/nologin\n"
            )
            (tmp / "etc-passwd").write_text(
                "root:x:0:0:root:/root:/bin/bash\n"
                "pietersz:x:1000:1000::/var/home/pietersz:/bin/bash\n"
                "localonly:x:971:971::/:/usr/sbin/nologin\n"
            )
            original = "root:!locked::0:99999:7:::\ndbus:!*:::::::\npietersz:$6$hash:20000:0:99999:7:::"
            (tmp / "shadow").write_text(original)  # no trailing newline
            sync.IMAGE_PASSWD = str(tmp / "lib-passwd")
            sync.LOCAL_PASSWD = str(tmp / "etc-passwd")
            sync.SHADOW = str(tmp / "shadow")
            sync.LOCK = str(tmp / ".pwd.lock")

            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(sync.main(), 0)
            self.assertIn("greetd", out.getvalue())
            self.assertEqual((tmp / "shadow").read_text(), original + "\ngreetd:!*:::::::\n")

            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(sync.main(), 0)
            self.assertEqual(out.getvalue(), "")
            self.assertEqual((tmp / "shadow").read_text(), original + "\ngreetd:!*:::::::\n")


if __name__ == "__main__":
    unittest.main()
