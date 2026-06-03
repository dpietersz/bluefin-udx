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

CURL=(curl -fsSL)
# GH_TOKEN dramatically raises the API rate limit. Honored if CI passes it in.
if [ -n "${GH_TOKEN:-}" ]; then
    CURL+=(-H "Authorization: Bearer ${GH_TOKEN}")
fi

# CI pre-resolves the .rpm URL using GITHUB_TOKEN (1000 req/h quota) and
# writes it to /tmp/scripts/build-pins.env, avoiding the unauthenticated
# GitHub API 60/h limit which both matrix legs share via the runner IP pool.
# Local builds without this file fall back to the unauthenticated API call.
if [ -f /tmp/scripts/build-pins.env ]; then
    # shellcheck disable=SC1091
    . /tmp/scripts/build-pins.env
fi

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
