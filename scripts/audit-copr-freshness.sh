#!/bin/bash
# Fail when a baked COPR package trails its upstream release for seven days.
# Compare exact packages, not parent-project activity: unrelated builds once hid
# abandoned noctalia-shell-v5 for months while CI stayed green.

set -euo pipefail

GRACE_DAYS=7
CURL=(curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 20 --max-time 120)
GITHUB_CURL=("${CURL[@]}")
if [ -n "${GH_TOKEN:-}" ]; then
  # Never send the GitHub token to COPR or other upstream hosts.
  GITHUB_CURL+=(-H "Authorization: Bearer ${GH_TOKEN}")
fi

normalize_version() {
  sed -E 's/^v//; s/-[0-9].*$//'
}

check_package() {
  local owner=$1 project=$2 package=$3 upstream=$4
  local upstream_json copr_json upstream_tag upstream_version upstream_published
  local copr_version copr_normalized age_days

  upstream_json=$("${GITHUB_CURL[@]}" "https://api.github.com/repos/${upstream}/releases/latest")
  upstream_tag=$(jq -r '.tag_name // empty' <<< "$upstream_json")
  upstream_published=$(jq -r '.published_at // empty' <<< "$upstream_json")
  upstream_version=$(normalize_version <<< "$upstream_tag")

  copr_json=$("${CURL[@]}" \
    "https://copr.fedorainfracloud.org/api_3/package?ownername=${owner}&projectname=${project}&packagename=${package}&with_latest_build=true")
  # COPR marks a multi-chroot build failed when any architecture fails even if
  # Fedora 44 x86_64 succeeded. Compare latest submitted source version here;
  # the image transaction + smoke gate separately prove our chroot is usable.
  copr_version=$(jq -r '.builds.latest.source_package.version // empty' <<< "$copr_json")
  copr_normalized=$(normalize_version <<< "$copr_version")

  if [ -z "$upstream_version" ] || [ -z "$upstream_published" ] || [ -z "$copr_normalized" ]; then
    echo "ERROR: could not resolve freshness metadata for ${owner}/${project} :: ${package}" >&2
    return 1
  fi

  if [ "$copr_normalized" = "$upstream_version" ]; then
    echo "ok: ${package} COPR=${copr_version} upstream=${upstream_tag}"
    return 0
  fi

  age_days=$(( ($(date +%s) - $(date -d "$upstream_published" +%s)) / 86400 ))
  if [ "$age_days" -ge "$GRACE_DAYS" ]; then
    echo "ERROR: ${owner}/${project} :: ${package} is stale: COPR=${copr_version}, upstream=${upstream_tag}, release_age=${age_days}d" >&2
    return 1
  fi

  echo "WARNING: ${package} COPR=${copr_version} trails upstream=${upstream_tag}; ${age_days}d into ${GRACE_DAYS}d grace period" >&2
}

check_cgit_meson_package() {
  local owner=$1 project=$2 package=$3 meson_url=$4 atom_url=$5
  local meson atom upstream_version upstream_published copr_json copr_version
  local copr_normalized build_state has_f44 build_ended build_age_days release_age_days

  meson=$("${CURL[@]}" "$meson_url")
  upstream_version=$(sed -nE "s/^project\\('gpu-screen-recorder', 'c', version : '([^']+)'.*/\\1/p" <<< "$meson")
  atom=$("${CURL[@]}" "$atom_url")
  upstream_published=$(awk -v wanted="$upstream_version" '
    index($0, "<title>" wanted "</title>") { found=1; next }
    found && /<published>/ {
      sub(/^.*<published>/, "")
      sub(/<\/published>.*$/, "")
      print
      exit
    }
  ' <<< "$atom")

  copr_json=$("${CURL[@]}" \
    "https://copr.fedorainfracloud.org/api_3/package?ownername=${owner}&projectname=${project}&packagename=${package}&with_latest_build=true")
  copr_version=$(jq -r '.builds.latest.source_package.version // empty' <<< "$copr_json")
  copr_normalized=$(normalize_version <<< "$copr_version")
  build_state=$(jq -r '.builds.latest.state // empty' <<< "$copr_json")
  has_f44=$(jq -r '.builds.latest.chroots | index("fedora-44-x86_64") != null' <<< "$copr_json")
  build_ended=$(jq -r '.builds.latest.ended_on // empty' <<< "$copr_json")

  if [ -z "$upstream_version" ] || [ -z "$upstream_published" ] || [ -z "$copr_normalized" ] || [ -z "$build_ended" ]; then
    echo "ERROR: could not resolve freshness metadata for ${owner}/${project} :: ${package}" >&2
    return 1
  fi
  if [ "$build_state" != "succeeded" ] || [ "$has_f44" != "true" ]; then
    echo "ERROR: latest ${package} build is not a successful Fedora 44 x86_64 build" >&2
    return 1
  fi

  build_age_days=$(( ($(date +%s) - build_ended) / 86400 ))
  if [ "$build_age_days" -gt 90 ]; then
    echo "ERROR: ${package} latest successful build is ${build_age_days}d old (maximum 90d)" >&2
    return 1
  fi

  if [ "$copr_normalized" = "$upstream_version" ]; then
    echo "ok: ${package} COPR=${copr_version} upstream=${upstream_version} build_age=${build_age_days}d"
    return 0
  fi

  release_age_days=$(( ($(date +%s) - $(date -d "$upstream_published" +%s)) / 86400 ))
  if [ "$release_age_days" -ge "$GRACE_DAYS" ]; then
    echo "ERROR: ${owner}/${project} :: ${package} is stale: COPR=${copr_version}, upstream=${upstream_version}, release_age=${release_age_days}d" >&2
    return 1
  fi

  echo "WARNING: ${package} COPR=${copr_version} trails upstream=${upstream_version}; ${release_age_days}d into ${GRACE_DAYS}d grace period" >&2
}

FAIL=0
check_package lionheartp Hyprland hyprlock hyprwm/hyprlock || FAIL=1
check_cgit_meson_package lionheartp Hyprland gpu-screen-recorder \
  https://git.dec05eba.com/gpu-screen-recorder/plain/meson.build \
  https://git.dec05eba.com/gpu-screen-recorder/atom/ || FAIL=1
check_package sneexy zen-browser zen-browser zen-browser/desktop || FAIL=1
check_package barsnick non-fed showmethekey AlynxZhou/showmethekey || FAIL=1

exit "$FAIL"
