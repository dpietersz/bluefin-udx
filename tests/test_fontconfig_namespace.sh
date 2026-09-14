#!/usr/bin/env bash
# Exercise the shipped directory salt in a private mount namespace.  In
# particular, do not use the caller's ~/.cache/fontconfig or /var/cache.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONF_FILE="${REPO_ROOT}/files/system/etc/fonts/conf.d/06-bluefin-host-font-dir-salt.conf"
SALT="bluefin-udx-host"
FC_BIN_DIR=${FC_BIN_DIR:-/usr/bin}
FC_CACHE="${FC_BIN_DIR}/fc-cache"
FC_LIST="${FC_BIN_DIR}/fc-list"
FC_MATCH="${FC_BIN_DIR}/fc-match"
FC_CAT="${FC_BIN_DIR}/fc-cat"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for bin in bwrap python3 "${FC_CACHE}" "${FC_LIST}" "${FC_MATCH}" "${FC_CAT}"; do
  command -v "${bin}" >/dev/null 2>&1 || fail "missing required command: ${bin}"
done

[ -f "${CONF_FILE}" ] || fail "missing host font namespace config"
if grep -Eq '^[[:space:]]*<reset-dirs' "${CONF_FILE}"; then
  fail "the namespace config must not reset stock or user font directories"
fi
for dir in /usr/share/fonts /usr/local/share/fonts /usr/share/X11/fonts/Type1 /usr/share/X11/fonts/TTF; do
  grep -Fqx "  <dir salt=\"${SALT}\">${dir}</dir>" "${CONF_FILE}" || \
    fail "missing salted system font directory: ${dir}"
done

# Use actual host font files, but mount them below the same canonical path with
# epoch mtimes.  A complete copy makes the collision reproducible on Ubuntu too:
# its package directories do not normally have the immutable-image epoch mtime.
mapfile -t HOST_FONTS < <(find /usr/share/fonts -type f \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \) -print | head -n 2)
[ "${#HOST_FONTS[@]}" -ge 2 ] || fail "need two host fonts under /usr/share/fonts"
FOREIGN_SOURCE=${HOST_FONTS[0]}
ACTUAL_ONLY_SOURCE=${HOST_FONTS[1]}

HOST_TREE="${TMP}/host-tree"
FOREIGN_TREE="${TMP}/foreign-tree"
FIXTURE_DESCENDANT=/usr/share/fonts/X11/opentype/truetype
FIXTURE_DESCENDANT_REL=X11/opentype/truetype
FOREIGN_FONT="${FIXTURE_DESCENDANT}/foreign.ttf"
USER_HOME="${TMP}/home"
USER_FONT="${USER_HOME}/.local/share/fonts/user.ttf"
CUSTOM_DIR="${USER_HOME}/custom-fonts"
CUSTOM_FONT="${CUSTOM_DIR}/custom.ttf"

mkdir -p "${HOST_TREE}" "${FOREIGN_TREE}/${FIXTURE_DESCENDANT_REL}" \
  "${USER_HOME}/.local/share/fonts" "${USER_HOME}/.config/fontconfig" "${CUSTOM_DIR}"
cp -a /usr/share/fonts/. "${HOST_TREE}/"
mkdir -p "${HOST_TREE}/${FIXTURE_DESCENDANT_REL}"
cp "${ACTUAL_ONLY_SOURCE}" "${HOST_TREE}/${FIXTURE_DESCENDANT_REL}/host-descendant.ttf"
cp "${FOREIGN_SOURCE}" "${FOREIGN_TREE}/${FIXTURE_DESCENDANT_REL}/foreign.ttf"
cp "${FOREIGN_SOURCE}" "${USER_FONT}"
cp "${ACTUAL_ONLY_SOURCE}" "${CUSTOM_FONT}"
cat > "${USER_HOME}/.config/fontconfig/fonts.conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>${CUSTOM_DIR}</dir>
</fontconfig>
EOF
# Do not follow a copied absolute symlink back into the live host tree.
find "${HOST_TREE}" "${FOREIGN_TREE}" -type d -exec touch -d @0 {} +
find "${HOST_TREE}" "${FOREIGN_TREE}" -type f -exec touch -d @0 {} +

# Each namespace gets a complete stock /etc/fonts tree.  The only difference is
# whether the exact config shipped by this repository is installed at its real
# /etc/fonts/conf.d path.  Do not use a synthetic FONTCONFIG_FILE.
make_etc_fonts() {
  local destination=$1 salted=$2
  mkdir -p "${destination}"
  cp -a /etc/fonts/. "${destination}/"
  rm -f "${destination}/conf.d/06-bluefin-host-font-dir-salt.conf"
  if [ "${salted}" = yes ]; then
    cp "${CONF_FILE}" "${destination}/conf.d/06-bluefin-host-font-dir-salt.conf"
  fi
}

UNSALTED_ETC="${TMP}/etc-unsalted/fonts"
SALTED_ETC="${TMP}/etc-salted/fonts"
make_etc_fonts "${UNSALTED_ETC}" no
make_etc_fonts "${SALTED_ETC}" yes

# These are every writable cache location used by the fixture: the stock XDG
# and legacy-home locations are below USER_HOME, while the shipped 05 config
# selects /var/cache/fontconfig.  The optional legacy baked-cache location is
# hidden too, so the read-only root bind can never service a cache write.
VAR_CACHE="${TMP}/var-cache"
XDG_CACHE="${TMP}/xdg-cache"
LIB_CACHE="${TMP}/lib-cache"
mkdir -p "${VAR_CACHE}" "${XDG_CACHE}" "${LIB_CACHE}" "${USER_HOME}/.fontconfig"

clear_caches() {
  find "${VAR_CACHE}" "${XDG_CACHE}" "${LIB_CACHE}" "${USER_HOME}/.fontconfig" \
    -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

cache_files() {
  find "${VAR_CACHE}" "${XDG_CACHE}" "${LIB_CACHE}" "${USER_HOME}/.fontconfig" \
    -type f -name '*.cache-*' -print | sort
}

# Cache version is an on-disk format value at byte 4, not a version inferred
# from a binary name.  Thus FC_BIN_DIR=/usr/bin validates cache-9 on this host,
# while a Homebrew override validates only the format it really produces.
assert_genuine_cache_headers() {
  python3 - "$@" <<'PY'
from pathlib import Path
import re
import sys

paths = [Path(path) for path in sys.argv[1:]]
if not paths:
    raise SystemExit("no cache files were produced")
versions = set()
for path in paths:
    match = re.search(r"\.cache-(\d+)$", path.name)
    if not match:
        raise SystemExit(f"cache name has no format suffix: {path}")
    data = path.read_bytes()
    if len(data) < 8:
        raise SystemExit(f"cache header is too short: {path}")
    header_version = int.from_bytes(data[4:8], byteorder=sys.byteorder)
    suffix_version = int(match.group(1))
    if header_version != suffix_version:
        raise SystemExit(
            f"cache header/suffix mismatch: {path} has header {header_version}, "
            f"suffix {suffix_version}"
        )
    versions.add(suffix_version)
if len(versions) != 1:
    raise SystemExit(f"fixture generated multiple cache formats: {sorted(versions)}")
print(next(iter(versions)))
PY
}

cache_for_directory() {
  local tree=$1 etc_fonts=$2 directory=$3 cache first_line
  while IFS= read -r cache; do
    first_line=$(fixture_fc "${tree}" "${etc_fonts}" "${FC_CAT}" -v "${cache}" 2>/dev/null | head -n 1 || true)
    if [ "${first_line}" = "Directory: ${directory}" ]; then
      printf '%s\n' "${cache}"
    fi
  done < <(cache_files)
}

single_cache_for_directory() {
  local tree=$1 etc_fonts=$2 directory=$3
  mapfile -t matches < <(cache_for_directory "${tree}" "${etc_fonts}" "${directory}")
  [ "${#matches[@]}" -eq 1 ] || \
    fail "expected one cache for ${directory}, found ${#matches[@]}"
  printf '%s\n' "${matches[0]}"
}

# The root is read-only.  Only explicit binds below can receive writes.  Bind
# TMP itself after the read-only root so HOME/XDG and all generated config files
# remain available inside the namespace.
run_fixture() {
  local tree=$1 etc_fonts=$2
  shift 2
  bwrap --die-with-parent --ro-bind / / \
    --bind "${TMP}" "${TMP}" \
    --bind "${tree}" /usr/share/fonts \
    --bind "${etc_fonts}" /etc/fonts \
    --bind "${VAR_CACHE}" /var/cache/fontconfig \
    --bind "${LIB_CACHE}" /usr/lib/fontconfig/cache \
    --clearenv \
    --setenv HOME "${USER_HOME}" \
    --setenv XDG_CACHE_HOME "${XDG_CACHE}" \
    --setenv FONTCONFIG_FILE fonts.conf \
    --setenv FONTCONFIG_PATH /etc/fonts \
    --setenv PATH "${FC_BIN_DIR}:/usr/bin:/bin" \
    --setenv LC_ALL C \
    "$@"
}

fixture_fc() {
  local tree=$1 etc_fonts=$2 command=$3
  shift 3
  run_fixture "${tree}" "${etc_fonts}" "${command}" "$@"
}

font_matches() {
  local tree=$1 etc_fonts=$2 generic=$3
  fixture_fc "${tree}" "${etc_fonts}" "${FC_MATCH}" -f '%{family}\t%{style}\t%{file}\n' "${generic}" | head -n 1
}

# Compare clean unsalted stock matching with the actual shipped configuration.
# This also catches directory-order tie-break regressions from duplicate dirs.
clear_caches
for generic in serif sans-serif monospace emoji; do
  font_matches "${HOST_TREE}" "${UNSALTED_ETC}" "${generic}" > "${TMP}/stock-${generic}"
done

# Baseline on the actual host font tree and full stock config plus the shipped
# duplicate entries.  There must be one (salted) cache per directory: this
# proves the duplicate <dir> updates the stock unsalted directory instead of
# registering a second one.
clear_caches
fixture_fc "${HOST_TREE}" "${SALTED_ETC}" "${FC_CACHE}" --force >/dev/null
mapfile -t baseline_cache_files < <(cache_files)
CACHE_FORMAT=$(assert_genuine_cache_headers "${baseline_cache_files[@]}")
[ -n "${CACHE_FORMAT}" ] || fail "could not determine genuine cache format"
SALTED_ROOT_CACHE=$(single_cache_for_directory "${HOST_TREE}" "${SALTED_ETC}" /usr/share/fonts)
SALTED_DESCENDANT_CACHE=$(single_cache_for_directory "${HOST_TREE}" "${SALTED_ETC}" "${FIXTURE_DESCENDANT}")

for generic in serif sans-serif monospace emoji; do
  match=$(font_matches "${HOST_TREE}" "${SALTED_ETC}" "${generic}")
  [ -n "${match}" ] || fail "${generic} has no baseline match"
  printf '%s\n' "${match}" > "${TMP}/baseline-${generic}"
  cmp -s "${TMP}/stock-${generic}" "${TMP}/baseline-${generic}" || \
    fail "${generic} changed from clean unsalted stock matching"
done
baseline_fonts=$(fixture_fc "${HOST_TREE}" "${SALTED_ETC}" "${FC_LIST}" -f '%{file}\n')
grep -Fxq "${USER_FONT}" <<< "${baseline_fonts}" || fail "stock user font directory was not loaded"
grep -Fxq "${CUSTOM_FONT}" <<< "${baseline_fonts}" || fail "user custom font directory was not loaded"

# Populate exactly the same cache namespace from a foreign /usr/share/fonts
# tree.  It deliberately contains a nested X11/opentype/truetype descendant and
# has epoch mtimes, as immutable container image trees do.
clear_caches
fixture_fc "${FOREIGN_TREE}" "${UNSALTED_ETC}" "${FC_CACHE}" --force >/dev/null
mapfile -t foreign_cache_files < <(cache_files)
FOREIGN_FORMAT=$(assert_genuine_cache_headers "${foreign_cache_files[@]}")
[ "${FOREIGN_FORMAT}" = "${CACHE_FORMAT}" ] || \
  fail "one binary produced inconsistent cache formats (${FOREIGN_FORMAT} vs ${CACHE_FORMAT})"
UNSALTED_ROOT_CACHE=$(single_cache_for_directory "${FOREIGN_TREE}" "${UNSALTED_ETC}" /usr/share/fonts)
UNSALTED_DESCENDANT_CACHE=$(single_cache_for_directory "${FOREIGN_TREE}" "${UNSALTED_ETC}" "${FIXTURE_DESCENDANT}")
[ "${UNSALTED_ROOT_CACHE}" != "${SALTED_ROOT_CACHE}" ] || \
  fail "duplicate salted /usr/share/fonts did not replace the stock unsalted cache key"
[ "${UNSALTED_DESCENDANT_CACHE}" != "${SALTED_DESCENDANT_CACHE}" ] || \
  fail "directory salt was not inherited by ${FIXTURE_DESCENDANT}"

# Negative control: without the shipped salt, the valid epoch foreign cache is
# accepted at the canonical path and hides a real font from the actual host tree.
unsalted_fonts=$(fixture_fc "${HOST_TREE}" "${UNSALTED_ETC}" "${FC_LIST}" -f '%{file}\n')
grep -Fxq "${FOREIGN_FONT}" <<< "${unsalted_fonts}" || \
  fail "unsalted negative control did not consume the foreign cache"
ACTUAL_ONLY_PATH=${ACTUAL_ONLY_SOURCE}
if grep -Fxq "${ACTUAL_ONLY_PATH}" <<< "${unsalted_fonts}"; then
  fail "unsalted negative control did not lose an actual host font"
fi

# Record the actual foreign bytes, not only the existence of their filenames.
sha256sum "${UNSALTED_ROOT_CACHE}" "${UNSALTED_DESCENDANT_CACHE}" > "${TMP}/foreign.sha256"

# The real shipped config has a different cache key, so it ignores the foreign
# cache and restores the actual tree, its descendants, and user configuration.
salted_fonts=$(fixture_fc "${HOST_TREE}" "${SALTED_ETC}" "${FC_LIST}" -f '%{file}\n')
grep -Fxq "${ACTUAL_ONLY_PATH}" <<< "${salted_fonts}" || \
  fail "salted config did not restore actual host fonts"
grep -Fxq "${USER_FONT}" <<< "${salted_fonts}" || fail "salted config removed the user font directory"
grep -Fxq "${CUSTOM_FONT}" <<< "${salted_fonts}" || fail "salted config removed the custom font directory"
for generic in serif sans-serif monospace emoji; do
  match=$(font_matches "${HOST_TREE}" "${SALTED_ETC}" "${generic}")
  cmp -s "${TMP}/baseline-${generic}" <(printf '%s\n' "${match}") || \
    fail "${generic} differs from the actual-config baseline after salting"
done

sha256sum --check --status "${TMP}/foreign.sha256" || fail "salted lookup modified foreign caches"
grep -Fxq "${FIXTURE_DESCENDANT}/host-descendant.ttf" <<< "${salted_fonts}" || \
  fail "salted lookup did not restore the actual descendant font"

mapfile -t final_cache_files < <(cache_files)
FINAL_FORMAT=$(assert_genuine_cache_headers "${final_cache_files[@]}")
[ "${FINAL_FORMAT}" = "${CACHE_FORMAT}" ] || fail "salted lookup changed cache format"
[ -n "$(cache_for_directory "${HOST_TREE}" "${SALTED_ETC}" /usr/share/fonts)" ] || \
  fail "salted lookup did not cache /usr/share/fonts"
[ -n "$(cache_for_directory "${HOST_TREE}" "${SALTED_ETC}" "${FIXTURE_DESCENDANT}")" ] || \
  fail "salted lookup did not cache the descendant directory"

echo "ok: genuine cache-${CACHE_FORMAT} headers; salt isolates foreign epoch caches and preserves host configuration"
