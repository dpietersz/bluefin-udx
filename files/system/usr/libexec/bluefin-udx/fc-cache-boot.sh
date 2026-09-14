#!/usr/bin/env bash
# fc-cache-boot — rebuild the writable system fontconfig cache before login.
#
# CACHE NAMESPACE: distrobox shares ~/.cache/fontconfig with the host while its
# /usr/share/fonts is a different filesystem. The host-only <dir salt> entries
# in /etc/fonts/conf.d/06-bluefin-host-font-dir-salt.conf give every host system
# font directory (and its descendants) distinct cache keys. This isolates every
# cache format version; do not remove it or replace it with cachedir ordering.
#
# The epoch stamp below is retained for composefs cache validation and first-boot
# resilience. It is not the namespace boundary: a foreign unsalted cache must
# never have the same key in the first place. The focused fixture at
# tests/test_fontconfig_namespace.sh proves duplicate salted <dir> entries update
# the stock directories without reset-dirs and preserve user font directories.
#
# Historical evidence (do not revive the materialization-race explanation):
# - 7e085d6 / f0a69fc assumed composefs made caches perpetually stale. Wrong:
#   FcCacheTimeValid returns dir_stat->st_mtime == 0 || (...). An epoch font
#   directory accepts a foreign cache indefinitely; no rescan race is needed.
# - 97a44d4 measured system fontconfig 2.17: epoch-stamping the correct cache
#   won over an unsalted foreign cache-9 regardless of cachedir order. fcdf671
#   fixed the bake canary's SIGPIPE/pipefail false failure.
# - That cache-9 preference cannot protect Helium's cache-11 consumer. Native
#   Helium 0.17.0.1 reproduced monospace chrome with a genuine 224-byte foreign
#   root cache-11; the shipped salt restored fonts without removing that file.
#   A linked libfontconfig or healthy /usr/bin/fc-match alone is not proof.
# - Fontconfig 2.18 changes cache selection; keep timestamps secondary, not the
#   namespace boundary. See RECIPE.md and tests/test_fontconfig_namespace.sh.
# Upstream context: https://github.com/89luca89/distrobox/issues/1945
#                   https://github.com/89luca89/distrobox/pull/2149
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
         "fonts are not visible. Removing the cache so readers rescan live." >&2
    rm -f "${CACHE_DIR}"/*.cache-*
    exit 1
fi

# Preserve the composefs-friendly cache timestamp. Namespace isolation is done
# by 06-bluefin-host-font-dir-salt.conf, not by this timestamp.
touch -d @0 "${CACHE_DIR}"/*.cache-* 2>/dev/null || true

echo "fc-cache-boot: system font cache rebuilt and epoch-stamped" \
     "($(find "${CACHE_DIR}" -name '*.cache-*' -type f 2>/dev/null | wc -l) files)"
