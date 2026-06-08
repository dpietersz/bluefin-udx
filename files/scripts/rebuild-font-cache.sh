#!/usr/bin/env bash
# Regenerate the system fontconfig cache after font-bearing packages are layered.
# The base image's baked cache can miss late-added fonts (for example Noto Color
# Emoji COLRv1). ostree-normalized font-dir mtimes can make runtime lazy rescans
# think stale caches are fresh, causing fontconfig clients to render emoji as tofu.

set -euo pipefail

echo "Rebuilding system fontconfig cache..."
fc-cache --system-only --force
echo "System fontconfig cache rebuilt"
