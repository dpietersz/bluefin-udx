#!/usr/bin/env bash
# Regenerate the system fontconfig cache after font-bearing packages are layered.
# The base image's baked cache can miss late-added fonts (for example Noto Color
# Emoji COLRv1). ostree-normalized font-dir mtimes can make runtime lazy rescans
# think stale caches are fresh, causing fontconfig clients to render emoji as tofu.
#
# This build-time pass is best-effort only: the baked cache it writes records a
# real font-dir mtime that ostree/composefs later normalizes to epoch, so it goes
# stale at runtime regardless. The durable fix is the RUNTIME rebuild into the
# shared writable /var/cache/fontconfig via fc-cache-boot.service (enabled from
# recipes/common.yml; cachedir registered by
# files/system/etc/fonts/conf.d/05-bluefin-writable-cache.conf). Keep this pass
# anyway so first-boot non-GUI font lookups before that service runs still work.

set -euo pipefail

echo "Rebuilding system fontconfig cache..."
fc-cache --system-only --force
echo "System fontconfig cache rebuilt"
