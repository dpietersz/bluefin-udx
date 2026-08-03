#!/usr/bin/env bash
# fc-cache-boot — rebuild the system fontconfig cache and stamp it to the UNIX
# epoch so it wins font lookups against anything a container writes.
#
# THE BUG THIS FIXES (re-diagnosed 2026-08-03 — the older explanation was wrong):
#
# distrobox bind-mounts the host $HOME into every toolbox at the SAME path, so
# ~/.cache/fontconfig is ONE directory shared by the host and all containers.
# fontconfig names cache files md5(<absolute dir path>)-<arch>.cache-<version>.
# /usr/share/fonts exists on the host (37 RPM subdirs, ~275 files) AND inside
# every container with completely different contents (Ubuntu: X11/opentype/
# truetype). Same key, different filesystem, one shared directory.
#
# So when any app in a toolbox touches fonts, the container's fontconfig writes
# a ~216-byte cache for "/usr/share/fonts" describing the CONTAINER's near-empty
# view, under the HOST's exact cache key and (Ubuntu 24.04 ships fontconfig 2.15)
# the HOST's exact cache version. The host then reads it, finds zero
# subdirectories, and every baked system font goes invisible — at which point the
# user's ~360 Nerd Fonts win the generic serif/sans-serif match by glyph coverage
# and Chromium/Electron (Helium, teams-for-linux, PDFium) render a MONOSPACE for
# `serif`: wrong serif, wide digits, tofu.
#
# Reproduce in one command:
#   distrobox enter <ubuntu-box> -- fc-cache -f
#   -> host goes from 665 fc-list entries to 0; fc-match serif flips to a Nerd Font.
#
# WHY THE EPOCH STAMP IS THE FIX (measured on fontconfig 2.17.0, the system lib
# that Helium/Electron actually link — NOT Homebrew's 2.18 which is first on PATH):
#
# Cache-directory ORDER does not save us. /etc/fonts/conf.d is included at line 88
# of /etc/fonts/fonts.conf, BEFORE the cachedir block at 92-95, so
# 05-bluefin-writable-cache.conf can only ever make /var/cache/fontconfig the
# FIRST cachedir — and first LOSES. Measured, good=correct 1928 B cache,
# bad=container poison, permuting cachedirs via FONTCONFIG_FILE:
#
#     mtimes          [good,bad]   [bad,good]
#     equal               0           666
#     bad newer           0           666
#     good newer          0           666
#     good mtime=0      666           666     <-- the fix
#
# fontconfig has an explicit OSTree accommodation: FcCacheTimeValid ends with
#   return dir_stat->st_mtime == 0 || (cache->checksum == (int)dir_stat->st_mtime && fnano);
# and FcDirCacheMapHelper prefers an epoch-stamped cache. Under composefs
# /usr/share/fonts genuinely HAS mtime 0, so this is precisely the case upstream
# built that branch for. Stamping our cache files to @0 makes them win from the
# cachedir position they already occupy — no fonts.conf edit, no new directory,
# no SELinux relabel, no per-container configuration.
#
# CAVEAT — VERSION COUPLED. On fontconfig 2.18 the selection rule changes to
# "newest cache mtime wins" (FcDirCacheProcess no longer breaks on first hit;
# FcDirCacheMapHelper compares latest_cache_mtime). RE-VERIFY THIS SCRIPT when
# Fedora bumps fontconfig past 2.17, and treat that bump as a regression trigger.
#
# Upstream status: this is a known, stalled distrobox bug —
#   https://github.com/89luca89/distrobox/issues/1945  (open since 2025-12-22, no reply)
#   https://github.com/89luca89/distrobox/pull/2149    (open, unmerged)
# Do not wait for it.
#
# NOTE: deliberately NO `set -e` and NO `pipefail`. The canary check pipes
# `fc-list | grep -q`; grep -q closes the pipe on first match, fc-list dies with
# SIGPIPE, and under pipefail the whole pipeline would report failure — a false
# negative that would delete a perfectly good cache on every boot.
set -u

CACHE_DIR=/var/cache/fontconfig
# A serif family baked into the base image (google-noto-vf). If this is missing
# from fc-list after a rebuild, the scan came up empty and the cache is poison.
CANARY="Noto Serif"

mkdir -p "${CACHE_DIR}"

# Full rebuild. NOT --system-only: it exits non-zero on this image and produced
# exactly the empty cache this service exists to prevent.
/usr/bin/fc-cache --force

# GUARD: never publish a cache that does not actually contain the system fonts.
# A missing cache is recoverable (readers rescan live); a valid-but-empty one
# stamped to the epoch would validate forever and never self-heal.
if ! /usr/bin/fc-list | grep -qi "${CANARY}"; then
    echo "fc-cache-boot: '${CANARY}' not visible after rebuild — /usr/share/fonts" \
         "did not materialize. Removing the cache so readers rescan live." >&2
    rm -f "${CACHE_DIR}"/*.cache-*
    exit 1
fi

# THE FIX: stamp every cache file to the UNIX epoch so it wins against any
# container-written cache in ~/.cache/fontconfig regardless of cachedir order.
touch -d @0 "${CACHE_DIR}"/*.cache-* 2>/dev/null || true

echo "fc-cache-boot: system font cache rebuilt and epoch-stamped" \
     "($(find "${CACHE_DIR}" -name '*.cache-*' -type f 2>/dev/null | wc -l) files)"
