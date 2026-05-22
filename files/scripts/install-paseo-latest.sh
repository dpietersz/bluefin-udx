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

API_URL="https://api.github.com/repos/getpaseo/paseo/releases/latest"
CURL=(curl -fsSL)
# GH_TOKEN dramatically raises the API rate limit. Honored if CI passes it in.
if [ -n "${GH_TOKEN:-}" ]; then
    CURL+=(-H "Authorization: Bearer ${GH_TOKEN}")
fi

echo "[paseo] querying $API_URL"
RPM_URL=$("${CURL[@]}" "$API_URL" \
    | grep -oE '"browser_download_url": *"[^"]*-x86_64\.rpm"' \
    | head -n1 \
    | sed -E 's/.*"(https:[^"]+)".*/\1/')

if [ -z "$RPM_URL" ]; then
    echo "[paseo] ✗ could not find an x86_64 .rpm asset in latest release" >&2
    exit 1
fi

echo "[paseo] installing $RPM_URL"
rpm-ostree install "$RPM_URL"
echo "[paseo] ✓ installed"
