#!/bin/bash
# Install latest tagged Nushell release after its GitHub asset digest and
# upstream SHA256SUMS entry agree. Nushell publishes no independent signature.
# Replaces atim/nushell COPR: its Fedora 44 builds stopped at 0.112.2 while
# upstream continued releasing. Current RPM carried only /usr/bin/nu, so this
# preserves installed surface without adding plugin binaries or changing login shell.

set -euo pipefail

REPO="nushell/nushell"
ARCHIVE_ARCH="x86_64-unknown-linux-gnu"
CURL=(curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 20 --max-time 300)
if [ -n "${GH_TOKEN:-}" ]; then
  CURL+=(-H "Authorization: Bearer ${GH_TOKEN}")
fi

for PIN_FILE in /tmp/scripts/build-pins.env /tmp/files/scripts/build-pins.env; do
  if [ -f "$PIN_FILE" ]; then
    # shellcheck disable=SC1090
    . "$PIN_FILE"
    break
  fi
done

if [ -n "${NUSHELL_TAG:-}" ] && [ -n "${NUSHELL_SHA256:-}" ]; then
  TAG="$NUSHELL_TAG"
  SHA256="$NUSHELL_SHA256"
  echo "[nushell] using CI-resolved ${TAG}"
else
  RELEASE_JSON=$("${CURL[@]}" "https://api.github.com/repos/${REPO}/releases/latest")
  TAG=$(jq -r .tag_name <<<"$RELEASE_JSON")
  VERSION="${TAG#v}"
  ARCHIVE="nu-${VERSION}-${ARCHIVE_ARCH}.tar.gz"
  API_SHA256=$(jq -r --arg archive "$ARCHIVE" \
    '.assets[] | select(.name == $archive) | .digest // empty' <<<"$RELEASE_JSON")
  API_SHA256="${API_SHA256#sha256:}"
  MANIFEST_SHA256=$("${CURL[@]}" "https://github.com/${REPO}/releases/download/${TAG}/SHA256SUMS" \
    | awk -v archive="$ARCHIVE" '$2 == archive { print $1; exit }')
  if [ "$API_SHA256" != "$MANIFEST_SHA256" ]; then
    echo "[nushell] GitHub asset digest disagrees with SHA256SUMS" >&2
    exit 1
  fi
  SHA256="$API_SHA256"
fi

VERSION="${TAG#v}"
ARCHIVE="nu-${VERSION}-${ARCHIVE_ARCH}.tar.gz"
URL="https://github.com/${REPO}/releases/download/${TAG}/${ARCHIVE}"

if [[ ! "$TAG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "[nushell] invalid tag or SHA-256: tag=${TAG} sha256=${SHA256}" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

"${CURL[@]}" -o "$WORKDIR/$ARCHIVE" "$URL"
printf '%s  %s\n' "$SHA256" "$WORKDIR/$ARCHIVE" | sha256sum -c -
tar -xzf "$WORKDIR/$ARCHIVE" -C "$WORKDIR"
SRCDIR="$WORKDIR/nu-${VERSION}-${ARCHIVE_ARCH}"

install -Dm 0755 "$SRCDIR/nu" /usr/bin/nu
install -Dm 0644 "$SRCDIR/LICENSE" /usr/share/licenses/nushell/LICENSE
install -Dm 0644 "$SRCDIR/README.txt" /usr/share/doc/nushell/README.txt

INSTALLED=$(/usr/bin/nu --version)
if [ "$INSTALLED" != "$VERSION" ]; then
  echo "[nushell] version mismatch: expected ${VERSION}, got ${INSTALLED}" >&2
  exit 1
fi

echo "[nushell] installed ${INSTALLED}"
