#!/bin/bash
# Make the Vitta boot splash (files/vitta/usr/share/plymouth/themes/vitta) the
# image's default Plymouth theme. Vitta-only: run from recipes/vitta-modules.yml
# after the files/vitta overlay, before the initramfs module bakes it in.
#
# Why plymouthd.defaults and not /etc/plymouth/plymouthd.conf (what
# plymouth-set-default-theme writes): plymouthd, plymouth-set-default-theme and
# plymouth-populate-initrd all read Theme= from /etc/plymouth/plymouthd.conf
# first and fall back to /usr/share/plymouth/plymouthd.defaults. /usr comes
# straight from the image on every deployment, while /etc goes through the
# ostree 3-way merge, so the defaults file is what reaches machines rebased
# onto Vitta without leaving an /etc diff behind. The boot splash itself runs
# from the initramfs, which bootc/rpm-ostree take from the image as built here.
# A local Theme= line in a machine's /etc still wins, as an explicit choice.

set -euo pipefail

DEFAULTS=${DEFAULTS:-/usr/share/plymouth/plymouthd.defaults}
CONF=${CONF:-/etc/plymouth/plymouthd.conf}
THEME=${THEME:-/usr/share/plymouth/themes/vitta/vitta.plymouth}

test -s "${THEME}" || { echo "[vitta-plymouth] ${THEME} missing" >&2; exit 1; }
test -f "$(plymouth --get-splash-plugin-path)script.so" || {
  echo "[vitta-plymouth] plymouth script plugin (plymouth-plugin-script) not installed" >&2
  exit 1
}

# Keep Fedora's other defaults (ShowDelay, DeviceTimeout, UseSimpledrmNoLuks):
# swap only the Theme= line, and insist there is exactly one to swap.
if [ "$(grep -c '^Theme=' "${DEFAULTS}")" != 1 ]; then
  echo "[vitta-plymouth] expected exactly one Theme= line in ${DEFAULTS}" >&2
  exit 1
fi
# The script plugin lays out in logical pixels. Pin the daemon's device scale
# so the 2560x1600 P14s panel uses its full native coordinate space and the
# 1600-px assets are not enlarged from a 1280x800 logical canvas. Reject an
# unexpected active key outside [Daemon] rather than producing an ambiguous
# initramfs configuration.
DEVICE_SCALE_TMP=$(mktemp "${DEFAULTS}.XXXXXX")
trap 'rm -f "${DEVICE_SCALE_TMP}"' EXIT
if ! awk '
function finish_daemon() {
  if (section == "Daemon" && scale_count == 0) {
    print "DeviceScale=1"
    scale_count = 1
  }
}
/^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
  finish_daemon()
  section = $0
  sub(/^[[:space:]]*\[/, "", section)
  sub(/\][[:space:]]*$/, "", section)
  if (section == "Daemon")
    daemon_count++
  print
  next
}
/^[[:space:]]*DeviceScale[[:space:]]*=/ {
  if (section != "Daemon") {
    print "[vitta-plymouth] DeviceScale must be in [Daemon]" > "/dev/stderr"
    exit 1
  }
  scale_count++
  if (scale_count != 1) {
    print "[vitta-plymouth] expected at most one DeviceScale= line in [Daemon]" > "/dev/stderr"
    exit 1
  }
  print "DeviceScale=1"
  next
}
{ print }
END {
  finish_daemon()
  if (daemon_count != 1 || scale_count != 1) {
    print "[vitta-plymouth] expected one [Daemon] section and one DeviceScale= line" > "/dev/stderr"
    exit 1
  }
}
' "${DEFAULTS}" > "${DEVICE_SCALE_TMP}"; then
  echo "[vitta-plymouth] unable to set DeviceScale=1 in ${DEFAULTS}" >&2
  exit 1
fi
chmod --reference="${DEFAULTS}" "${DEVICE_SCALE_TMP}"
mv "${DEVICE_SCALE_TMP}" "${DEFAULTS}"
trap - EXIT
sed -i 's/^Theme=.*/Theme=vitta/' "${DEFAULTS}"

# The image's own /etc copy is also what lands in the initramfs; an active
# Theme= there would outrank the defaults everywhere.
if grep -Eq '^[[:space:]]*Theme[[:space:]]*=' "${CONF}" 2>/dev/null; then
  echo "[vitta-plymouth] ${CONF} sets Theme=, which would override ${DEFAULTS}" >&2
  exit 1
fi

ACTIVE=$(plymouth-set-default-theme)
if [ "${ACTIVE}" != vitta ]; then
  echo "[vitta-plymouth] default theme resolves to ${ACTIVE}, expected vitta" >&2
  exit 1
fi
echo "[vitta-plymouth] default theme: vitta (${DEFAULTS})"
