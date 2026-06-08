#!/usr/bin/env bash
# nwg-displays — installed at image build time from the latest upstream tag.
#
# Why not the COPR `tofik/nwg-shell`: that package is stuck at v0.3.28, which
# predates niri support. Niri detection landed in the 0.4.x line. Upstream
# moves faster than the (single-maintainer) Fedora COPR ecosystem, and the
# upstream `install.sh` writes only to atomic-safe paths (/usr/bin,
# /usr/lib/python3.X/site-packages, /usr/share), so we vendor it directly.
#
# Runtime deps (gtk3, gtk-layer-shell, python3-gobject, python3-i3ipc) and
# build deps (python3-build, python3-installer, python3-wheel,
# python3-setuptools) are layered separately in recipes/common.yml so this
# script can stay pure tarball+install.
#
# Every image rebuild = freshest nwg-displays.

set -euo pipefail

REPO="nwg-piotr/nwg-displays"
CURL=(curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 20 --max-time 300)
if [ -n "${GH_TOKEN:-}" ]; then
    CURL+=(-H "Authorization: Bearer ${GH_TOKEN}")
fi

# CI pre-resolves the tag using GITHUB_TOKEN (1000 req/h quota) and writes
# build-pins.env before bluebuild generate. Depending on how the script module
# stages files, the pin can surface via either /tmp/scripts or /tmp/files/scripts.
# Local builds without this file fall back to the unauthenticated API call below.
for PIN_FILE in /tmp/scripts/build-pins.env /tmp/files/scripts/build-pins.env; do
    if [ -f "$PIN_FILE" ]; then
        # shellcheck disable=SC1090
        . "$PIN_FILE"
        break
    fi
done

if [ -n "${NWG_DISPLAYS_TAG:-}" ]; then
    TAG="$NWG_DISPLAYS_TAG"
    echo "[nwg-displays] using CI-resolved tag ${TAG}"
else
    API_URL="https://api.github.com/repos/${REPO}/tags"
    echo "[nwg-displays] querying $API_URL"
    TAG=$("${CURL[@]}" "$API_URL" \
        | grep -oE '"name": *"v?[0-9]+\.[0-9]+\.[0-9]+"' \
        | head -n1 \
        | sed -E 's/.*"(v?[0-9]+\.[0-9]+\.[0-9]+)".*/\1/')
fi

if [ -z "$TAG" ]; then
    echo "[nwg-displays] ✗ could not resolve latest tag" >&2
    exit 1
fi

TARBALL_URL="https://codeload.github.com/${REPO}/tar.gz/refs/tags/${TAG}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "[nwg-displays] installing ${TAG} from ${TARBALL_URL}"
"${CURL[@]}" -o "${WORKDIR}/src.tar.gz" "$TARBALL_URL"
tar -xzf "${WORKDIR}/src.tar.gz" -C "$WORKDIR"
SRCDIR="${WORKDIR}/nwg-displays-${TAG#v}"

if [ ! -d "$SRCDIR" ]; then
    echo "[nwg-displays] ✗ extracted dir not found at $SRCDIR" >&2
    ls -1 "$WORKDIR" >&2
    exit 1
fi

cd "$SRCDIR"
# We don't run upstream install.sh as-is: it calls `python -m installer dist/*.whl`
# with no --prefix, and Fedora's default sysconfig scheme routes scripts to
# /usr/local/bin — which doesn't exist at atomic image build time, so the
# installer hits FileNotFoundError. We do the same steps manually with
# --prefix /usr so scripts land in /usr/bin.
python3 -m build --wheel --no-isolation
python3 -m installer --prefix /usr dist/*.whl
install -Dm 644 -t /usr/share/applications nwg-displays.desktop
install -Dm 644 -t /usr/share/pixmaps nwg-displays.svg
install -Dm 644 -t /usr/share/licenses/nwg-displays LICENSE
install -Dm 644 -t /usr/share/doc/nwg-displays README.md

# Verify the binary landed and self-reports a niri-aware version.
if [ ! -x /usr/bin/nwg-displays ]; then
    echo "[nwg-displays] ✗ /usr/bin/nwg-displays missing after install" >&2
    exit 1
fi

# Confirm 0.4.x or newer (i.e. niri-capable) is what landed.
if ! grep -q 'NIRI_SOCKET' /usr/lib/python3.*/site-packages/nwg_displays/main.py 2>/dev/null; then
    echo "[nwg-displays] ✗ installed source lacks NIRI_SOCKET detection — wrong version?" >&2
    exit 1
fi

echo "[nwg-displays] ✓ installed ${TAG}"
