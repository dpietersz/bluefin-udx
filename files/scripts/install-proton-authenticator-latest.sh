#!/bin/bash
# Proton Authenticator — install the newest active stable x86_64 RPM published
# in Proton's official Linux manifest.
#
# Proton does not provide a DNF repository and its RPM is not RPM-signed. The
# official version.json publishes a SHA-512 digest for every artifact, so this
# installer resolves URL + digest together and refuses the package unless both
# the checksum and RPM identity match.
#
# CI pre-resolves the manifest into build-pins.env. That file becomes part of
# the build context, invalidating the cached script layer when Proton publishes
# a new release. Local builds resolve the same manifest directly.

set -euo pipefail

MANIFEST_URL="https://proton.me/download/authenticator/linux/version.json"
CURL=(curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 20 --max-time 300)

for PIN_FILE in /tmp/scripts/build-pins.env /tmp/files/scripts/build-pins.env; do
  if [ -f "$PIN_FILE" ]; then
    # shellcheck disable=SC1090
    . "$PIN_FILE"
    break
  fi
done

if [ -n "${PROTON_AUTHENTICATOR_VERSION:-}${PROTON_AUTHENTICATOR_RPM_URL:-}${PROTON_AUTHENTICATOR_SHA512:-}" ]; then
  : "${PROTON_AUTHENTICATOR_VERSION:?CI pin missing PROTON_AUTHENTICATOR_VERSION}"
  : "${PROTON_AUTHENTICATOR_RPM_URL:?CI pin missing PROTON_AUTHENTICATOR_RPM_URL}"
  : "${PROTON_AUTHENTICATOR_SHA512:?CI pin missing PROTON_AUTHENTICATOR_SHA512}"
  VERSION="$PROTON_AUTHENTICATOR_VERSION"
  RPM_URL="$PROTON_AUTHENTICATOR_RPM_URL"
  SHA512="$PROTON_AUTHENTICATOR_SHA512"
  echo "[proton-authenticator] using CI-resolved version ${VERSION}"
else
  echo "[proton-authenticator] querying ${MANIFEST_URL}"
  RELEASE=$(
    "${CURL[@]}" "$MANIFEST_URL" | jq -r '
      [
        .Releases[]
        | select(.CategoryName == "Stable" and (.RolloutPercentage // 0) > 0)
        | . as $release
        | .File[]
        | select(.Identifier | startswith(".rpm"))
        | {
            version: $release.Version,
            url: .Url,
            sha512: .Sha512CheckSum
          }
      ][0] // empty
      | [.version, .url, .sha512]
      | @tsv
    '
  )
  if [ -z "$RELEASE" ]; then
    echo "[proton-authenticator] ✗ no active stable RPM found in official manifest" >&2
    exit 1
  fi
  IFS=$'\t' read -r VERSION RPM_URL SHA512 <<< "$RELEASE"
fi

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+)+$ ]]; then
  echo "[proton-authenticator] ✗ invalid version from manifest: ${VERSION}" >&2
  exit 1
fi
if [[ ! "$RPM_URL" =~ ^https://proton\.me/download/authenticator/linux/ProtonAuthenticator-[0-9]+(\.[0-9]+)+-[0-9]+\.x86_64\.rpm$ ]]; then
  echo "[proton-authenticator] ✗ unexpected RPM URL: ${RPM_URL}" >&2
  exit 1
fi
if [[ ! "$SHA512" =~ ^[0-9a-fA-F]{128}$ ]]; then
  echo "[proton-authenticator] ✗ invalid SHA-512 from manifest" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
RPM_PATH="${WORKDIR}/ProtonAuthenticator.rpm"

echo "[proton-authenticator] downloading ${RPM_URL}"
"${CURL[@]}" -o "$RPM_PATH" "$RPM_URL"
echo "${SHA512}  ${RPM_PATH}" | sha512sum --check --status

echo "[proton-authenticator] ✓ SHA-512 verified"
RPM_ID=$(rpm -qp --queryformat '%{NAME}\t%{VERSION}\t%{ARCH}\n' "$RPM_PATH")
IFS=$'\t' read -r RPM_NAME RPM_VERSION RPM_ARCH <<< "$RPM_ID"
if [ "$RPM_NAME" != "proton-authenticator" ] || [ "$RPM_VERSION" != "$VERSION" ] || [ "$RPM_ARCH" != "x86_64" ]; then
  echo "[proton-authenticator] ✗ unexpected RPM identity: ${RPM_NAME} ${RPM_VERSION} ${RPM_ARCH}" >&2
  exit 1
fi

rpm-ostree install "$RPM_PATH"

# Proton documents a WebKit white-screen failure on some NVIDIA systems. Both
# image variants share this installer, so keep the workaround app-scoped rather
# than setting WEBKIT_DISABLE_DMABUF_RENDERER globally. Disabling acceleration
# is harmless for this small GTK application and gives the P14s deterministic
# behavior while preserving the same package/configuration on the Intel T580.
DESKTOP_ENTRY="/usr/share/applications/Proton Authenticator.desktop"
if [ ! -f "$DESKTOP_ENTRY" ]; then
  echo "[proton-authenticator] ✗ desktop entry missing after RPM install" >&2
  exit 1
fi
if ! grep -Eq '^Exec=env WEBKIT_DISABLE_DMABUF_RENDERER=1 proton-authenticator([[:space:]].*)?$' "$DESKTOP_ENTRY"; then
  sed -i -E \
    's|^Exec=(/usr/bin/)?proton-authenticator([[:space:]].*)?$|Exec=env WEBKIT_DISABLE_DMABUF_RENDERER=1 proton-authenticator\2|' \
    "$DESKTOP_ENTRY"
fi
if ! grep -Eq '^Exec=env WEBKIT_DISABLE_DMABUF_RENDERER=1 proton-authenticator([[:space:]].*)?$' "$DESKTOP_ENTRY"; then
  echo "[proton-authenticator] ✗ could not apply NVIDIA WebKit workaround" >&2
  exit 1
fi

echo "[proton-authenticator] ✓ installed ${RPM_NAME} ${RPM_VERSION} (${RPM_ARCH})"
