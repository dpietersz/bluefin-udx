"""Static regression checks for Vitta overlay files the smoke gate cannot boot.

The smoke gates assert the same facts inside the built image; these run in
seconds without a build.
"""

import contextlib
import errno
import importlib.util
from importlib.machinery import SourceFileLoader
import io
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest import mock


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
        self.assertRegex(script, r"(?m)^exec cage -d -s -m last -- quickshell ")

    def test_greeter_cage_tells_clients_not_to_decorate(self):
        # Without -d cage answers xdg-decoration with client_side, so Qt draws
        # its bradient frame: a white title bar and 3 px white edges around the
        # greeter (T580 acceptance round 2).
        script = (VITTA / "usr/libexec/vitta/vitta-greeter").read_text()
        cage = re.search(r"(?m)^exec cage (.*) -- quickshell ", script)
        self.assertIsNotNone(cage)
        self.assertIn("-d", cage.group(1).split())
        self.assertNotIn("QT_WAYLAND_DISABLE_WINDOWDECORATION", script)

    def test_greeter_selftest_checks_edges_under_the_launchers_cage(self):
        # The selftest reruns the greeter inside headless cage with the
        # launcher's own flags and checks the window covers the whole output.
        preview = (VITTA / "usr/bin/vitta-greeter-preview").read_text()
        selftest = (VITTA / "usr/share/vitta/greeter/selftest.qml").read_text()
        self.assertIn("usr/libexec/vitta/vitta-greeter", preview)
        self.assertIn("WLR_BACKENDS=headless", preview)
        self.assertIn("VITTA_GREETER_SELFTEST_CAGE=1", preview)
        self.assertIn('Quickshell.env("VITTA_GREETER_SELFTEST_CAGE")', selftest)
        self.assertIn("window.screen.width", selftest)

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

    def shadow_fixture(self, tmp):
        """Point the sync at tmp: greetd needs an entry, shadow lives in tmp/etc."""
        sync = load_shadow_sync()
        etc = tmp / "etc"
        etc.mkdir()
        (tmp / "lib-passwd").write_text("greetd:x:965:965::/var/lib/greetd:/usr/sbin/nologin\n")
        (etc / "passwd").write_text("root:x:0:0:root:/root:/bin/bash\n")
        (etc / "shadow").write_text("root:!locked::0:99999:7:::\n")
        sync.IMAGE_PASSWD = str(tmp / "lib-passwd")
        sync.LOCAL_PASSWD = str(etc / "passwd")
        sync.SHADOW = str(etc / "shadow")
        sync.LOCK = str(etc / ".pwd.lock")
        return sync, etc

    def test_shadow_sync_temp_copy_failure_leaves_shadow_unchanged(self):
        # A short write followed by ENOSPC (full disk) while writing the copy:
        # /etc/shadow keeps its inode and bytes, no temporary copy is left.
        with tempfile.TemporaryDirectory() as tmp:
            sync, etc = self.shadow_fixture(Path(tmp))
            shadow = etc / "shadow"
            before, inode = shadow.read_bytes(), shadow.stat().st_ino
            real_write = os.write

            def short_then_full(fd, data):
                if fd > 2 and len(data) > 1:
                    real_write(fd, bytes(data[: len(data) // 2]))
                    raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))
                return real_write(fd, data)

            with mock.patch.object(sync.os, "write", short_then_full), \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(sync.main(), 1)
            self.assertIn("left unchanged", err.getvalue())
            self.assertEqual(shadow.read_bytes(), before)
            self.assertEqual(shadow.stat().st_ino, inode)
            self.assertEqual(sorted(p.name for p in etc.iterdir()), [".pwd.lock", "passwd", "shadow"])

            # A later run without the failure succeeds.
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(sync.main(), 0)
            self.assertEqual(shadow.read_text(), before.decode() + "greetd:!*:::::::\n")

    def test_shadow_sync_replaces_atomically_keeping_owner_mode_and_label(self):
        with tempfile.TemporaryDirectory() as tmp:
            sync, etc = self.shadow_fixture(Path(tmp))
            shadow = etc / "shadow"
            shadow.chmod(0o640)
            (etc / ".shadow.vitta-stale").write_text("left by a power cut")
            inode = shadow.stat().st_ino
            label = b"system_u:object_r:shadow_t:s0\x00"
            labels, calls = {str(shadow): label}, []

            def getxattr(path, name, follow_symlinks=True):
                self.assertEqual(name, "security.selinux")
                if str(path) in labels:
                    return labels[str(path)]
                raise OSError(errno.ENODATA, "no label")

            def setxattr(fd, name, value):
                calls.append((os.readlink(f"/proc/self/fd/{fd}"), name, value))

            renames, real_rename = [], os.rename

            def rename(source, target):
                renames.append((source, target))
                real_rename(source, target)

            fsynced = []
            real_fsync = os.fsync

            def fsync(fd):
                fsynced.append(os.readlink(f"/proc/self/fd/{fd}"))
                real_fsync(fd)

            with mock.patch.object(sync.os, "getxattr", getxattr), \
                    mock.patch.object(sync.os, "setxattr", setxattr), \
                    mock.patch.object(sync.os, "rename", rename), \
                    mock.patch.object(sync.os, "fsync", fsync), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(sync.main(), 0)
            self.assertEqual(shadow.read_text(), "root:!locked::0:99999:7:::\ngreetd:!*:::::::\n")
            self.assertNotEqual(shadow.stat().st_ino, inode, "replaced, not edited in place")
            self.assertEqual(shadow.stat().st_mode & 0o7777, 0o640)
            self.assertEqual((shadow.stat().st_uid, shadow.stat().st_gid), (os.getuid(), os.getgid()))
            self.assertEqual(len(renames), 1)
            temporary = renames[0][0]
            self.assertEqual((os.path.dirname(temporary), renames[0][1]), (str(etc), str(shadow)))
            self.assertEqual(calls, [(temporary, "security.selinux", label)], "shadow_t copied to the copy")
            self.assertEqual(fsynced, [temporary, str(etc)], "copy fsynced before rename, /etc after")
            self.assertEqual(sorted(p.name for p in etc.iterdir()), [".pwd.lock", "passwd", "shadow"])


if __name__ == "__main__":
    unittest.main()
