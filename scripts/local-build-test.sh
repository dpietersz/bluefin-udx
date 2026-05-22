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

# bluebuild writes to localhost/<name>:<tag>. Find the most recent.
IMAGE=$(podman images --format "{{.Repository}}:{{.Tag}}" \
    | grep "^localhost/${RECIPE}:" \
    | head -n1)
if [ -z "$IMAGE" ]; then
    echo "ERROR: no localhost/${RECIPE}:* image in podman store after build"
    podman images
    exit 1
fi

echo
echo "==> Smoke-boot test against $IMAGE"
# Single podman run that exits non-zero if any expected binary is missing.
# Keep this list aligned with what each phase adds. Phase 0 = bootstrap pkgs + Teams.
podman run --rm --entrypoint /bin/bash "$IMAGE" -c '
    set -e
    FAIL=0
    check() {
        if command -v "$1" >/dev/null 2>&1; then
            echo "  ok    $1"
        else
            echo "  MISS  $1"
            FAIL=1
        fi
    }
    echo "Phase 0 binaries:"
    for bin in pass gpg age ssh git jq curl teams-for-linux; do
        check "$bin"
    done

    # Verify Teams wrapper actually got installed (file at /etc/teams-for-linux/config.json.default).
    if [ -f /etc/teams-for-linux/config.json.default ]; then
        echo "  ok    Teams config.json.default seeded"
    else
        echo "  MISS  Teams config.json.default seed"
        FAIL=1
    fi

    exit $FAIL
'

echo
echo "==> Smoke-boot PASSED for $RECIPE"
