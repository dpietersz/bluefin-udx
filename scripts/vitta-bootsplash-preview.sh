#!/bin/bash
# Render the Vitta Plymouth theme offscreen and capture PNG frames.
#
#   ./scripts/vitta-bootsplash-preview.sh [OUT_DIR]     (default: ./bootsplash-preview)
#
# Runs Fedora's own plymouthd + script plugin (same packages as base-main) with
# the x11 renderer Fedora ships in plymouth-devel, drawing into an Xvfb screen
# inside a rootless container: no --privileged, no devices, no network (the
# daemon's abstract socket stays in the container's namespace). The container
# script refuses to start if any DRM/fbdev/VT device is visible, so this can
# never take over the host console.
#
# Env: MAIN_SIZE (default 1920x1080), EXTRA_SIZES (space separated),
#      FONTLESS=1 (no usable font: proves the prompt still takes a passphrase).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(realpath -m "${1:-$ROOT/bootsplash-preview}")
IMAGE=localhost/vitta-bootsplash-preview

mkdir -p "$OUT"
podman build -q -t "$IMAGE" -f "$ROOT/scripts/bootsplash-preview/Containerfile" \
  "$ROOT/scripts/bootsplash-preview" >/dev/null
podman run --rm --network=none \
  -e MAIN_SIZE="${MAIN_SIZE:-1920x1080}" \
  ${EXTRA_SIZES+-e EXTRA_SIZES="$EXTRA_SIZES"} \
  -e FONTLESS="${FONTLESS:-0}" \
  -v "$ROOT/files/vitta/usr/share/plymouth/themes/vitta:/theme:ro,z" \
  -v "$ROOT/scripts/bootsplash-preview/render.sh:/render.sh:ro,z" \
  -v "$OUT:/out:z" \
  "$IMAGE" bash /render.sh
echo "frames in $OUT"
