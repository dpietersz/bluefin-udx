#!/usr/bin/env bash
# Build a recipe locally with bluebuild and run a smoke-test against the result.
# Mirrors the CI smoke-boot gate so failures surface in ~5 min on your laptop
# instead of after a GH Actions run.
#
# Usage:
#   ./scripts/local-build-test.sh                  # builds bluefin-udx
#   ./scripts/local-build-test.sh bluefin-udx-nvidia

set -euo pipefail

RECIPE="${1:-bluefin-udx}"
RECIPE_FILE="recipes/${RECIPE}.yml"

if [ ! -f "$RECIPE_FILE" ]; then
    echo "ERROR: $RECIPE_FILE not found. Available recipes:"
    ls -1 recipes/
    exit 1
fi

if ! command -v bluebuild >/dev/null 2>&1; then
    echo "ERROR: bluebuild not installed."
    echo "Install with: brew install blue-build/tap/bluebuild  (or see https://blue-build.org/learn/getting-started/)"
    exit 1
fi

echo "==> Building $RECIPE locally (no push, no sign)..."
BB_BUILD_PUSH=false bluebuild build --no-sign "$RECIPE_FILE"

# bluebuild may pick the docker driver if a docker daemon is present, so the
# image can land in either store. Look in both.
IMAGE="localhost/${RECIPE}:latest"
if podman image exists "$IMAGE" 2>/dev/null; then
    RUNNER=podman
elif command -v docker >/dev/null && docker image inspect "$IMAGE" >/dev/null 2>&1; then
    RUNNER=docker
else
    echo "ERROR: $IMAGE not found in podman or docker storage"
    podman images 2>&1 | head -5
    docker images 2>&1 | head -5
    exit 1
fi
echo "==> Build done, image $IMAGE found in $RUNNER"

echo
echo "==> Smoke-boot test against $IMAGE (via $RUNNER)"

# Notes on the checks below:
#  - PATH-resident binaries (pass, gpg, …) check via `command -v`.
#  - Bluefin redirects /opt -> /var/opt (writeable, first-boot populated from
#    /usr/lib/opt). Inside a `run` container /var/opt is empty so the
#    /usr/bin/teams-for-linux symlink chain dead-ends. Verify the rpm is
#    installed AND the wrapped binary lives at its real /usr/lib/opt path.
$RUNNER run --rm -e "RECIPE_NAME=${RECIPE}" --entrypoint /bin/bash "$IMAGE" -c '
    set -e
    FAIL=0
    check_bin() {
        if command -v "$1" >/dev/null 2>&1; then echo "  ok    $1"; else echo "  MISS  $1"; FAIL=1; fi
    }
    check_file() {
        if [ -e "$1" ]; then echo "  ok    $1"; else echo "  MISS  $1"; FAIL=1; fi
    }
    check_rpm() {
        if rpm -q "$1" >/dev/null 2>&1; then echo "  ok    rpm $1"; else echo "  MISS  rpm $1"; FAIL=1; fi
    }

    echo "Phase 0 bootstrap binaries:"
    for bin in pass gpg age ssh git jq curl; do check_bin "$bin"; done

    echo "Phase 0 Teams (in /opt, first-boot reflected — check rpm + real path):"
    check_rpm teams-for-linux
    check_file /usr/lib/opt/teams-for-linux/teams-for-linux
    check_file /usr/lib/opt/teams-for-linux/teams-for-linux.real   # wrapper proof
    check_file /etc/teams-for-linux/config.json.default

    echo "Phase 2 system packages:"
    for p in kitty tmux kanshi mate-polkit syncthing swayidle \
             niri waybar pavucontrol NetworkManager-tui blueman SwayNotificationCenter \
             espanso-wayland hyprlock noctalia-shell-v5 \
             nushell swayosd; do check_rpm "$p"; done
    # nwg-displays — installed from upstream tarball (not RPM-backed).
    # Verify the binary exists AND the installed source has niri detection
    # (NIRI_SOCKET env-var check) so a regression back to a pre-0.4 build fails fast.
    check_bin nwg-displays
    if ! grep -q NIRI_SOCKET /usr/lib/python3.*/site-packages/nwg_displays/main.py 2>/dev/null; then
        echo "  FAIL: nwg-displays installed but missing NIRI_SOCKET detection (pre-0.4)"
        exit 1
    fi
    echo "  ok    nwg-displays (niri-aware)"
    echo "Phase 3a GUI apps:"
    for p in chromium browserpass browserpass-chromium zen-browser helium-browser-bin; do
        check_rpm "$p"
    done
    echo "Phase 3b GUI apps:"
    check_rpm beekeeper-studio
    echo "Phase 3c additions:"
    check_rpm zed
    check_rpm postgresql
    check_bin psql
    check_rpm wtype
    check_bin wtype
    check_rpm grim
    check_bin grim
    check_rpm slurp
    check_bin slurp

    echo "Phase 3d OBS Studio + v4l2loopback:"
    check_rpm obs-studio
    check_bin obs
    check_rpm obs-studio-plugin-vaapi
    # ublue-signed kmod (from ghcr.io/ublue-os/akmods main flavor).
    # Package name is `kmod-v4l2loopback` (meta) — backed by a versioned
    # `kmod-v4l2loopback-<kernel>` sub-package. Check the meta.
    check_rpm kmod-v4l2loopback
    check_file /etc/modules-load.d/v4l2loopback.conf
    check_file /etc/modprobe.d/v4l2loopback.conf

    # NVIDIA variant adds nvtop. CUDA toolkit intentionally not baked —
    # incompatible with atomic /usr/local redirect; use nvidia/cuda containers
    # per project instead. See bluefin-udx-nvidia.yml for full rationale.
    if [ "$RECIPE_NAME" = "bluefin-udx-nvidia" ]; then
        echo "Phase 4 NVIDIA additions:"
        check_rpm nvtop
        check_bin nvtop
        # Base bluefin-dx-nvidia-open already provides:
        check_bin nvidia-smi
        check_bin nvidia-ctk
    fi

    exit $FAIL
'

echo
echo "==> Smoke-boot PASSED for $RECIPE"
