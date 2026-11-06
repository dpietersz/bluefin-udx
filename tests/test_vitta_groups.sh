#!/usr/bin/env bash
# Regression test for Vitta's first-boot docker/libvirt group reconciliation.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="${REPO_ROOT}/files/vitta/usr/libexec/vitta/vitta-groups"

[ -x "${HELPER}" ] || {
  echo "FAIL: missing executable helper: ${HELPER}" >&2
  exit 1
}

podman run --rm \
  -v "${HELPER}:/usr/libexec/vitta/vitta-groups:ro,z" \
  registry.fedoraproject.org/fedora:44 \
  bash -c '
    set -euo pipefail

    fail() {
      echo "FAIL: $*" >&2
      exit 1
    }

    assert_member() {
      local user=$1 group=$2
      id -nG "$user" | tr " " "\n" | grep -Fxq "$group" ||
        fail "$user is not a member of $group"
    }

    mkdir -p /etc/vitta
    touch /usr/lib/group
    sed -i "/^\(docker\|libvirt\):/d" /etc/group
    sed -i "/^\(docker\|libvirt\):/d" /etc/gshadow
    sed -i "/^\(docker\|libvirt\):/d" /usr/lib/group
    printf "%s\n" \
      "docker:x:2499:" \
      "libvirt:x:2500:" >> /usr/lib/group

    useradd -m alice
    usermod -aG wheel alice
    useradd -m -g wheel bob

    /usr/libexec/vitta/vitta-groups

    for user in alice bob; do
      for group in docker libvirt; do
        assert_member "$user" "$group"
      done
    done
    [ "$(< /etc/vitta/groups-version)" = 1 ] ||
      fail "groups-version is not 1"

    before=$(sha256sum /etc/group /etc/gshadow /etc/vitta/groups-version)
    /usr/libexec/vitta/vitta-groups
    after=$(sha256sum /etc/group /etc/gshadow /etc/vitta/groups-version)
    [ "$before" = "$after" ] || fail "second run changed group state"

    useradd -m carol
    usermod -aG wheel carol
    /usr/libexec/vitta/vitta-groups
    for group in docker libvirt; do
      assert_member carol "$group"
    done

    echo "ok: docker/libvirt reconciled for supplementary and primary wheel members"
  '
