#!/usr/bin/env bash
# Resolve every package our recipes layer against a future Fedora release,
# BEFORE upstream Bluefin publishes an image on it.
#
# Why this exists: bluefin-dx:stable flips Fedora majors on upstream's schedule
# and our nightly build inherits the flip the same night. Third-party repos
# (COPRs, Terra, RPM Fusion, vendor repos) and baked per-release GPG keys are
# the usual casualties. A full bluebuild needs a bluefin-dx image on the new
# release, which upstream only publishes once its own build is green. This
# check needs only upstream's *base* (silverblue-main:<N>), which exists weeks
# earlier, and answers "would rpm-ostree find and solve every package?".
#
# What it does NOT cover (only the full build + smoke gate can):
#   - conflicts with Bluefin's own layer (zfs vs zed, kmod-v4l2loopback, ...)
#   - script modules (nushell, nwg-displays, Proton RPMs, Teams patch)
#
# Usage:
#   scripts/check-fedora-next.sh            # next major after bluefin-dx:stable
#   scripts/check-fedora-next.sh 45         # explicit Fedora major
#   BASE_IMAGE=quay.io/fedora/fedora scripts/check-fedora-next.sh 45
#   RECIPES="recipes/common.yml recipes/vitta.yml recipes/vitta-modules.yml" \
#     BASE_IMAGE=ghcr.io/ublue-os/base-main scripts/check-fedora-next.sh
#
# Environment:
#   RECIPES     space-separated recipe files whose rpm-ostree and files modules are
#               resolved. from-file includes are NOT followed, so list the
#               shared module file too. Default: common.yml + both bluefin-udx.
#   BASE_IMAGE  image resolved against, tagged :<major>.
#               Default: ghcr.io/ublue-os/silverblue-main.
#   ENGINE      container engine command, may carry a prefix ("sudo podman").
#
# Without an explicit major, N+1 is derived from the first recipe that pins a
# numeric image-version (vitta.yml: 44 -> 45); recipes on a floating stream
# (bluefin-udx: stable) fall back to bluefin-dx:stable's Fedora major.
#
# Exit codes: 0 = all packages resolve (or no N+1 base published yet),
#             1 = resolution failed, 2 = usage/setup error.

set -euo pipefail

cd "$(dirname "$0")/.."

BASE_IMAGE="${BASE_IMAGE:-ghcr.io/ublue-os/silverblue-main}"
read -r -a RECIPE_FILES <<< "${RECIPES:-recipes/common.yml recipes/bluefin-udx.yml recipes/bluefin-udx-nvidia.yml}"
# ENGINE may carry a prefix, e.g. ENGINE="sudo podman" in CI.
read -r -a ENGINE_CMD <<< "${ENGINE:-podman}"

for tool in "${ENGINE_CMD[@]: -1}" yq skopeo jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not found" >&2
    exit 2
  fi
done

if [ "${#RECIPE_FILES[@]}" -eq 0 ]; then
  echo "ERROR: RECIPES is empty" >&2
  exit 2
fi
for recipe in "${RECIPE_FILES[@]}"; do
  if [ ! -f "$recipe" ]; then
    echo "ERROR: recipe $recipe not found" >&2
    exit 2
  fi
done

PINNED=$(yq -r '.["image-version"] // ""' "${RECIPE_FILES[@]}" | grep -E '^[0-9]+$' | head -n1 || true)

if [ $# -ge 1 ]; then
  FEDORA="$1"
elif [ -n "$PINNED" ]; then
  FEDORA=$((PINNED + 1))
else
  CURRENT=$(skopeo inspect --no-tags docker://ghcr.io/ublue-os/bluefin-dx:stable \
    | jq -r '.Labels["org.opencontainers.image.version"]' | cut -d. -f1)
  if [[ ! "$CURRENT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: could not read Fedora major from bluefin-dx:stable (got '$CURRENT')" >&2
    exit 2
  fi
  FEDORA=$((CURRENT + 1))
fi
if [[ ! "$FEDORA" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Fedora major must be numeric, got '$FEDORA'" >&2
  exit 2
fi

IMAGE="${BASE_IMAGE}:${FEDORA}"

# Same selectors bluebuild's rpm-ostree module consumes. Comments are stripped
# by yq; %OS_VERSION% is bluebuild's substitution token.
mapfile -t PKGS < <(yq -r '.modules[] | select(.type == "rpm-ostree") | .install[]?' "${RECIPE_FILES[@]}" | grep -vx -- "---" | sort -u)
mapfile -t REPO_URLS < <(yq -r '.modules[] | select(.type == "rpm-ostree") | .repos[]?' "${RECIPE_FILES[@]}" | grep -vx -- "---" \
  | sed "s/%OS_VERSION%/${FEDORA}/g" | sort -u)
mapfile -t KEY_URLS < <(yq -r '.modules[] | select(.type == "rpm-ostree") | .keys[]?' "${RECIPE_FILES[@]}" | grep -vx -- "---" | sort -u)

if [ "${#PKGS[@]}" -eq 0 ]; then
  echo "ERROR: no packages parsed from ${RECIPE_FILES[*]}" >&2
  exit 2
fi

# Baked .repo files and keys come from the recipes' `files` modules, not from
# a fixed overlay: bluefin-udx copies files/system to /, Vitta additionally
# copies files/vitta (whose VS Code repo has to exist for `code` to resolve).
# Each entry is either a whole overlay mirrored at / or a directory copied
# straight into /etc/yum.repos.d or /etc/pki/rpm-gpg.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/repos" "$STAGE/keys"
while IFS=$'\t' read -r src dest; do
  dest="/${dest#/}"
  dest="${dest%/}"
  case "$dest" in
    "") repo_dir="files/$src/etc/yum.repos.d"; key_dir="files/$src/etc/pki/rpm-gpg" ;;
    /etc/yum.repos.d) repo_dir="files/$src"; key_dir="" ;;
    /etc/pki/rpm-gpg) repo_dir=""; key_dir="files/$src" ;;
    *) continue ;;
  esac
  if [ -n "$repo_dir" ] && [ -d "$repo_dir" ]; then
    find "$repo_dir" -maxdepth 1 -name '*.repo' -exec cp -t "$STAGE/repos" {} +
  fi
  if [ -n "$key_dir" ] && [ -d "$key_dir" ]; then
    find "$key_dir" -maxdepth 1 -type f -exec cp -t "$STAGE/keys" {} +
  fi
done < <(yq -r '.modules[] | select(.type == "files") | .files[] | [.source, .destination] | @tsv' "${RECIPE_FILES[@]}" | grep -vx -- "---")

echo "==> Fedora ${FEDORA} resolution check against ${IMAGE}"
echo "    ${#PKGS[@]} packages, ${#REPO_URLS[@]} remote .repo files, ${#KEY_URLS[@]} remote keys"
echo "    baked: $(cd "$STAGE/repos" && ls | tr '\n' ' ')"

# No N+1 base yet (e.g. right after a Fedora flip) is a normal state, not a
# failure: there is simply nothing to check against.
if ! skopeo inspect --no-tags "docker://${IMAGE}" >/dev/null 2>&1; then
  echo "SKIP: ${IMAGE} is not published yet — nothing to check against"
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::notice::Fedora ${FEDORA} base ${IMAGE} not published yet; resolution check skipped"
  exit 0
fi

# podman understands --pull=newer; docker only always|missing|never.
if [ "$(basename "${ENGINE_CMD[-1]}")" = docker ]; then PULL=always; else PULL=newer; fi

# Inside the container: install the baked repos/keys exactly where the image's
# files module puts them, fetch the remote repos/keys the rpm-ostree module
# would fetch, then let dnf solve the full transaction without downloading it.
# dnf5 exits non-zero on --assumeno even when solving succeeded, so success is
# judged on the solver output, not the exit code.
set +e
OUTPUT=$("${ENGINE_CMD[@]}" run --rm --pull="$PULL" \
  -v "$STAGE/repos:/in/repos:ro,z" \
  -v "$STAGE/keys:/in/keys:ro,z" \
  -e REPO_URLS="${REPO_URLS[*]}" \
  -e KEY_URLS="${KEY_URLS[*]}" \
  -e PKGS="${PKGS[*]}" \
  --entrypoint /bin/bash "$IMAGE" -c '
    set -euo pipefail
    cp /in/keys/* /etc/pki/rpm-gpg/
    cp /in/repos/*.repo /etc/yum.repos.d/
    for url in $REPO_URLS; do
      curl -fsSL --retry 3 --retry-all-errors -o "/etc/yum.repos.d/$(basename "$url")" "$url"
    done
    for url in $KEY_URLS; do
      curl -fsSL --retry 3 --retry-all-errors -o /tmp/key.asc "$url"
      rpm --import /tmp/key.asc
    done
    echo "--- releasever: $(rpm -E %fedora)"
    # Fail loudly on a baked key that does not exist for this release instead
    # of letting skip_if_unavailable=True quietly drop the whole repo. Only
    # OUR baked repos: the base image owns its own Fedora repo keys.
    MISSING=0
    for f in /in/repos/*.repo; do
      while read -r key; do
        key="${key//\$releasever/$(rpm -E %fedora)}"
        key="${key//\$basearch/$(uname -m)}"
        path="${key#file://}"
        if [ ! -e "$path" ]; then echo "MISSING-KEY $path (from $f)"; MISSING=1; fi
      done < <(grep -hoE "^gpgkey=file://[^ ]+" "$f" | cut -d= -f2-)
    done
    [ "$MISSING" -eq 0 ] || exit 3
    dnf -y makecache >/dev/null
    dnf install --assumeno --setopt=install_weak_deps=False $PKGS 2>&1 || true
  ' 2>&1)
RC=$?
set -e

printf "%s\n" "$OUTPUT" | grep -E "^--- |MISSING-KEY|No match for argument|Problem|nothing provides|conflicts with|Failed to|Error|Transaction Summary|Installing:|Upgrading:|Downgrading:" | head -60 || true

if [ "$RC" -ne 0 ]; then
  echo "FAIL: setup inside ${IMAGE} failed (exit $RC)"
  printf "%s\n" "$OUTPUT" | tail -20
  exit 1
fi
if printf "%s\n" "$OUTPUT" | grep -qE "No match for argument|^Problem|nothing provides|Failed to resolve"; then
  echo "FAIL: Fedora ${FEDORA} cannot resolve the recipe package set"
  exit 1
fi
if ! printf "%s\n" "$OUTPUT" | grep -q "Transaction Summary"; then
  echo "FAIL: dnf produced no transaction — unexpected output:"
  printf "%s\n" "$OUTPUT" | tail -20
  exit 1
fi

# Per-package versions for the packages we pin behaviour on. A repo that
# trails the current release shows up here as a downgrade candidate.
echo "==> Resolved versions (selected)"
printf "%s\n" "$OUTPUT" | grep -E "^ (noctalia|niri|zed|espanso-wayland|helium-browser-bin|zen-browser|hyprlock|gpu-screen-recorder|showmethekey|telegram-desktop|teams-for-linux|beekeeper-studio) " \
  | awk '{printf "    %-22s %s  (%s)\n", $1, $3, $4}' || true

echo "PASS: all ${#PKGS[@]} packages resolve on Fedora ${FEDORA}"
