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
    API_URL="https://api.github.com/repos/getpaseo/paseo/releases/latest"
    echo "[paseo] querying $API_URL"
    RPM_URL=$("${CURL[@]}" "$API_URL" \
        | grep -oE '"browser_download_url": *"[^"]*-x86_64\.rpm"' \
        | head -n1 \
        | sed -E 's/.*"(https:[^"]+)".*/\1/')
fi

if [ -z "$RPM_URL" ]; then
    echo "[paseo] ✗ could not find an x86_64 .rpm asset in latest release" >&2
    exit 1
fi

echo "[paseo] installing $RPM_URL"
rpm-ostree install "$RPM_URL"
echo "[paseo] ✓ installed"
