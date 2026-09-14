#!/usr/bin/env bash
# Bake an epoch-stamped system fontconfig cache into the image.
#
# WHY THIS EXISTS: /usr/libexec/bluefin-udx/fc-cache-boot.sh rebuilds and
# epoch-stamps /var/cache/fontconfig at every boot, and that is the authoritative
# copy. But /var is runtime state on bootc, so it is empty on a brand-new machine
# until that service has run once. This pass bakes an equivalent cache into
# /usr/lib/fontconfig/cache (which IS part of the image) so first-boot font
# lookups — including anything that runs before display-manager — are already
# correct.
#
# TWO NON-OBVIOUS THINGS, both previously wrong here:
#
# 1. The output must NOT land in /var. files/system/etc/fonts/conf.d/
#    05-bluefin-writable-cache.conf is installed by the `files` module BEFORE this
#    script runs, which makes /var/cache/fontconfig the FIRST cachedir at build
#    time too — so a bare `fc-cache` writes there, and bluebuild's post_build.sh
#    (`rm -rf /tmp/* /var/* /opt`) then deletes it. The bake was silently a no-op.
#    We therefore put the baked cachedir BEFORE the conf.d include in a
#    throwaway FONTCONFIG_FILE. Appending it afterward does NOT pin writes:
#    the included 05 config still takes the first writable slot.
#
# 2. `--system-only` is NOT usable: it exits non-zero on this image and produces
#    an empty cache. It was removed from the boot service for exactly that reason
#    (commit f0a69fc) but survived here until 2026-08-03.
#
# /etc/fonts/conf.d/06-bluefin-host-font-dir-salt.conf, included below, is the
# collision fix: it separates host keys from unsalted container keys.
# Keep the epoch stamp for composefs cache validation, but do not treat cache
# selection order or timestamp precedence as the namespace boundary.

# NO pipefail, and this is not an oversight. The canary check below pipes
# `fc-list | grep -qi`; grep -q exits on the first match and closes the pipe,
# fc-list then dies with SIGPIPE (141), and under pipefail the whole pipeline
# reports failure EVEN WHEN THE CANARY WAS FOUND. That inverts the check, takes
# the error branch, and fails the image build with the font cache in perfect
# shape. Verified: with 135 Noto Serif faces present, `set -uo pipefail` takes
# the error branch and `set -u` takes the ok branch. Same trap is documented in
# the dotfiles fontconfig-heal.sh header — and I still walked into it here.
set -u

CACHE_DIR=/usr/lib/fontconfig/cache
CANARY="Noto Serif"
CONF=$(mktemp /tmp/bake-fonts-XXXXXX.conf)
trap 'rm -f "${CONF}"' EXIT

mkdir -p "${CACHE_DIR}"

cat > "${CONF}" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <cachedir>${CACHE_DIR}</cachedir>
  <dir>/usr/share/fonts</dir>
  <dir>/usr/local/share/fonts</dir>
  <dir>/usr/share/X11/fonts/Type1</dir>
  <dir>/usr/share/X11/fonts/TTF</dir>
  <include ignore_missing="yes">/etc/fonts/conf.d</include>
</fontconfig>
EOF

echo "Baking system fontconfig cache into ${CACHE_DIR}..."
FONTCONFIG_FILE="${CONF}" fc-cache --force

if ! FONTCONFIG_FILE="${CONF}" fc-list | grep -qi "${CANARY}"; then
    echo "ERROR: '${CANARY}' not visible after baking the font cache." >&2
    echo "       The base image no longer ships it, or the scan failed." >&2
    echo "       Both fc-cache-boot.sh and local-build-test.sh use this canary." >&2
    exit 1
fi

# A visible canary alone can come from /var or an older baked cache. Require
# the newly salted root cache in the location that survives image cleanup.
ROOT_KEY=$(printf %s /usr/share/fontsbluefin-udx-host | md5sum | cut -d ' ' -f1)
if ! compgen -G "${CACHE_DIR}/${ROOT_KEY}-*.cache-*" >/dev/null; then
    echo "ERROR: salted root font cache missing from ${CACHE_DIR}" >&2
    exit 1
fi

# Preserve the composefs-friendly cache timestamp; directory salt isolates it.
touch -d @0 "${CACHE_DIR}"/*.cache-* 2>/dev/null || true

echo "System fontconfig cache baked and epoch-stamped ($(find "${CACHE_DIR}" -name '*.cache-*' -type f | wc -l) files)"
