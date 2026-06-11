#!/usr/bin/env bash
# Paseo desktop (https://paseo.sh) — installed at image build time from the
# latest GitHub release of getpaseo/paseo. Every image rebuild pulls the
# freshest Paseo; there is no vendor yum repo, and asset filenames embed the
# version (Paseo-X.Y.Z-x86_64.rpm), so the GitHub /latest/download/<name>
# redirect cannot be used — we resolve via the API.
#
# The CLI counterpart (@getpaseo/cli) is installed per-user via chezmoi
# (~/.local/share/npm), not here.

set -euo pipefail

CURL=(curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 20 --max-time 300)
# GH_TOKEN dramatically raises the API rate limit. Honored if CI passes it in.
if [ -n "${GH_TOKEN:-}" ]; then
    CURL+=(-H "Authorization: Bearer ${GH_TOKEN}")
fi

# CI pre-resolves the .rpm URL using GITHUB_TOKEN (1000 req/h quota) and
# writes build-pins.env before bluebuild generate. Depending on how the script
# module stages files, the pin can surface via either /tmp/scripts or
# /tmp/files/scripts. Local builds without this file fall back to the
# unauthenticated API call.
for PIN_FILE in /tmp/scripts/build-pins.env /tmp/files/scripts/build-pins.env; do
    if [ -f "$PIN_FILE" ]; then
        # shellcheck disable=SC1090
        . "$PIN_FILE"
        break
    fi
done

if [ -n "${PASEO_RPM_URL:-}" ]; then
    RPM_URL="$PASEO_RPM_URL"
    echo "[paseo] using CI-resolved URL $RPM_URL"
else
    # Query the releases LIST, not /releases/latest. getpaseo/paseo has shipped
    # duplicate tags with an empty "latest" release (e.g. two v0.1.93 releases on
    # 2026-06-10, the one /releases/latest resolves to carrying 0 assets). jq picks
    # the newest stable (non-draft, non-prerelease) release that actually exposes an
    # x86_64.rpm — same filter the CI pre-resolve step uses. jq is guaranteed
    # present: recipes/common.yml installs it in the Phase-0 rpm-ostree module that
    # runs before this script module (and bluefin-dx base ships it too). This path
    # is the local/unauthenticated fallback (CI always uses the pre-resolved pin).
    API_URL="https://api.github.com/repos/getpaseo/paseo/releases?per_page=100"
    echo "[paseo] querying $API_URL"
    RPM_URL=$("${CURL[@]}" "$API_URL" \
        | jq -r '[.[] | select(.draft==false and .prerelease==false) | .assets[] | select(.name | endswith("x86_64.rpm")) | .browser_download_url][0] // empty')
fi

if [ -z "$RPM_URL" ]; then
    echo "[paseo] ✗ could not find an x86_64 .rpm asset in any stable release" >&2
    exit 1
fi

echo "[paseo] installing $RPM_URL"
rpm-ostree install "$RPM_URL"
echo "[paseo] ✓ installed"
