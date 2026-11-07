#!/usr/bin/env bash
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

DEFAULTS=/usr/share/plymouth/plymouthd.defaults
CONF=/etc/plymouth/plymouthd.conf
THEME=/usr/share/plymouth/themes/vitta/vitta.plymouth

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
