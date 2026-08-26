#!/bin/bash
# Proton Mail desktop — install the newest active stable Fedora/RHEL x86_64
# RPM published in Proton's official Linux manifest. Alpha and EarlyAccess
# releases are deliberately excluded.
#
# Proton provides no DNF repository and the RPM is not RPM-signed. Resolve the
# versioned URL and SHA-512 together, then verify both the digest and RPM
# identity before installation.
#
# CI pre-resolves the manifest into build-pins.env. That file becomes part of
# the build context, invalidating the cached script layer when Proton publishes
# a new stable release. Local builds resolve the same manifest directly.

set -euo pipefail

MANIFEST_URL="https://proton.me/download/mail/linux/version.json"
CURL=(curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 20 --max-time 300)

for PIN_FILE in /tmp/scripts/build-pins.env /tmp/files/scripts/build-pins.env; do
  if [ -f "$PIN_FILE" ]; then
    # shellcheck disable=SC1090
    . "$PIN_FILE"
    break
  fi
done

if [ -n "${PROTON_MAIL_VERSION:-}${PROTON_MAIL_RPM_URL:-}${PROTON_MAIL_SHA512:-}" ]; then
  : "${PROTON_MAIL_VERSION:?CI pin missing PROTON_MAIL_VERSION}"
  : "${PROTON_MAIL_RPM_URL:?CI pin missing PROTON_MAIL_RPM_URL}"
  : "${PROTON_MAIL_SHA512:?CI pin missing PROTON_MAIL_SHA512}"
  VERSION="$PROTON_MAIL_VERSION"
  RPM_URL="$PROTON_MAIL_RPM_URL"
  SHA512="$PROTON_MAIL_SHA512"
  echo "[proton-mail] using CI-resolved stable version ${VERSION}"
else
  echo "[proton-mail] querying ${MANIFEST_URL}"
  RELEASE=$(
    "${CURL[@]}" "$MANIFEST_URL" | jq -r '
      [
        .Releases[]
        | select(.CategoryName == "Stable" and (.RolloutProportion // 0) > 0)
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
    echo "[proton-mail] ✗ no active stable RPM found in official manifest" >&2
    exit 1
  fi
  IFS=$'\t' read -r VERSION RPM_URL SHA512 <<< "$RELEASE"
fi

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+)+$ ]]; then
  echo "[proton-mail] ✗ invalid version from manifest: ${VERSION}" >&2
  exit 1
fi
if [[ ! "$RPM_URL" =~ ^https://proton\.me/download/mail/linux/[0-9]+(\.[0-9]+)+/ProtonMail-desktop-beta\.rpm$ ]]; then
  echo "[proton-mail] ✗ unexpected RPM URL: ${RPM_URL}" >&2
  exit 1
fi
if [[ ! "$SHA512" =~ ^[0-9a-fA-F]{128}$ ]]; then
  echo "[proton-mail] ✗ invalid SHA-512 from manifest" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
RPM_PATH="${WORKDIR}/ProtonMail-desktop-beta.rpm"

echo "[proton-mail] downloading ${RPM_URL}"
"${CURL[@]}" -o "$RPM_PATH" "$RPM_URL"
echo "${SHA512}  ${RPM_PATH}" | sha512sum --check --status
echo "[proton-mail] ✓ SHA-512 verified"

RPM_ID=$(rpm -qp --queryformat '%{NAME}\t%{VERSION}\t%{ARCH}\n' "$RPM_PATH")
IFS=$'\t' read -r RPM_NAME RPM_VERSION RPM_ARCH <<< "$RPM_ID"
if [ "$RPM_NAME" != "proton-mail" ] || [ "$RPM_VERSION" != "$VERSION" ] || [ "$RPM_ARCH" != "x86_64" ]; then
  echo "[proton-mail] ✗ unexpected RPM identity: ${RPM_NAME} ${RPM_VERSION} ${RPM_ARCH}" >&2
  exit 1
fi

rpm-ostree install "$RPM_PATH"

if [ ! -x /usr/bin/proton-mail ] || [ ! -f /usr/share/applications/proton-mail.desktop ]; then
  echo "[proton-mail] ✗ executable or desktop entry missing after RPM install" >&2
  exit 1
fi

echo "[proton-mail] ✓ installed ${RPM_NAME} ${RPM_VERSION} (${RPM_ARCH})"
