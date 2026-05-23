#!/usr/bin/env bash
# Wire client-side cosign verification for ghcr.io/dpietersz/* images into
# /etc/containers/policy.json at image build time.
#
# Why a script and not a static file overlay:
#   policy.json is shared with upstream Bluefin (entries for ghcr.io/ublue-os,
#   quay.io/toolbx-images, registry.redhat.io, ...). Replacing it wholesale
#   would silently drop those entries the next time upstream adds one.
#   Merging with jq keeps us forward-compatible.
#
# Pairs with:
#   /usr/lib/pki/containers/bluefin-udx.pub      (the cosign pubkey)
#   /etc/containers/registries.d/dpietersz.yaml         (sigstore attachments)
#
# After this lands in the image, clients can rebase via:
#   sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/dpietersz/bluefin-udx-nvidia:stable

set -euo pipefail

POLICY=/etc/containers/policy.json
KEY=/usr/lib/pki/containers/bluefin-udx.pub
REGISTRY="ghcr.io/dpietersz"

if [ ! -f "$POLICY" ]; then
    echo "[cosign-policy] ✗ $POLICY missing — base image changed shape?" >&2
    exit 1
fi

if [ ! -f "$KEY" ]; then
    echo "[cosign-policy] ✗ $KEY missing — files overlay did not land" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "[cosign-policy] installing jq (build-time only)"
    rpm-ostree install jq
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# Idempotent merge: set transports.docker["ghcr.io/dpietersz"] to a single
# sigstoreSigned entry keyed against our pubkey. matchRepository (instead of
# matchRepoDigestOrExact) is the right rule for tag-based rebases: cosign
# signs the image by digest reference, so the signature payload's
# docker-reference is `repo` without a tag — `matchRepoDigestOrExact`
# rejects `repo:stable` pulls against that. matchRepository requires only
# the repo namespace to match, which is what upstream Bluefin/ublue uses
# for their own ghcr.io/ublue-os entry.
jq \
    --arg reg "$REGISTRY" \
    --arg key "$KEY" \
    '.transports.docker[$reg] = [
        {
            "type": "sigstoreSigned",
            "keyPath": $key,
            "signedIdentity": { "type": "matchRepository" }
        }
    ]' \
    "$POLICY" > "$TMP"

# Validate before swap — if jq produced garbage, fail loud instead of leaving
# a broken policy.json that would brick podman/rpm-ostree on next boot.
if ! jq empty "$TMP" >/dev/null 2>&1; then
    echo "[cosign-policy] ✗ jq produced invalid JSON, refusing to install" >&2
    exit 1
fi

install -m 0644 "$TMP" "$POLICY"
echo "[cosign-policy] ✓ policy.json now trusts $REGISTRY via $KEY"
