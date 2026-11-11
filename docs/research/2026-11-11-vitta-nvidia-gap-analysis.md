# Vitta NVIDIA gap analysis — P14s against `base-nvidia:44`

**Scope:** Phase 0 research for `vitta-nvidia`, the P14s Gen 5 replacement for
`bluefin-udx-nvidia`. This is a read-only analysis; it changes no recipe,
overlay, dotfiles, host state, or image deployment. The non-NVIDIA Bluefin/DX
delta was already triaged in
[the 2026-11-06 Vitta gap analysis](2026-11-06-vitta-gap-analysis.md) and is
not repeated here.

## Method and captured inputs

I ran the required comparison exactly:

```bash
BLUEFIN_IMAGE=ghcr.io/ublue-os/bluefin-dx-nvidia-open:stable BASE_IMAGE=ghcr.io/ublue-os/base-nvidia:44 OUTPUT_DIR=/tmp/vitta-nvidia-gap scripts/vitta-gap-report.sh
```

It produced 861 Bluefin-only RPM names and 276 selected Bluefin-only
integration files. The images resolved to the following local digests:

| Image | Digest |
|---|---|
| `ghcr.io/ublue-os/bluefin-dx-nvidia-open:stable` | `sha256:a64d670f6111404d742ba3b4a5579cf8601f04af9642615f801b423080b40212` |
| `ghcr.io/ublue-os/base-nvidia:44` | `sha256:35fc93e3fbbba07e7b7fb859b15f0cbe274e8918cbafd29e015399751a4074ae` |
| `ghcr.io/dpietersz/vitta:stable` (current Vitta comparison) | `sha256:908b0b6daba94c382b6bca17d4f36a6501f35d2716a435f7ef5ce3a69fd5d2f6` |

The table uses the task's rule: retain an item only for an active P14s
process/unit, a `main` dotfiles reference, or an NVIDIA/hybrid integration
file which Bluefin adds beyond `base-nvidia`. `HAVE` means the target already
supplies it (directly or through the designated existing Vitta package);
`ADD` is the explicit input for later tasks.

## P14s NVIDIA and hardware delta

| item | kind (rpm/file/unit/karg) | in bluefin-dx-nvidia-open | in base-nvidia:44 | used on P14s (evidence) | ADD / DROP / HAVE | where | evidence command |
|---|---|---|---|---|---|---|---|
| `00-nvidia.toml`: `rd.driver.blacklist=nouveau`, `modprobe.blacklist=nouveau`, `nvidia-drm.modeset=1`, `initcall_blacklist=simpledrm_platform_driver_init` (in that order) | karg | Present, unowned `/usr/lib/bootc/kargs.d/00-nvidia.toml` | Absent; `/usr/lib/bootc/kargs.d` empty | All four are in the live P14s `/proc/cmdline`; Intel `i915` and NVIDIA `nvidia` bind the two GPUs | **ADD** | `files/vitta-nvidia/usr/lib/bootc/kargs.d/00-nvidia.toml` | `podman run --rm --entrypoint /bin/bash ghcr.io/ublue-os/bluefin-dx-nvidia-open:stable -c 'cat /usr/lib/bootc/kargs.d/00-nvidia.toml'`; `podman run --rm --entrypoint /bin/bash ghcr.io/ublue-os/base-nvidia:44 -c 'find /usr/lib/bootc/kargs.d -type f -print'`; `cat /proc/cmdline`; `lspci -nnk` |
| `fprintd` | rpm | `fprintd-1.94.5-5.fc44.x86_64` | Absent | P14s has the package and the dotfiles fingerprint template detects its `06cb:00f9` sensor; current Vitta lacks the package | **ADD** | shared `recipes/vitta-modules.yml` (Task 6) | `podman run --rm --entrypoint rpm ghcr.io/dpietersz/vitta:stable -q fprintd`; `rpm -q fprintd`; `git -C ~/dotfiles grep -n '06cb:00f9' main -- .chezmoi.toml.tmpl` |
| `fprintd-pam` | rpm | `fprintd-pam-1.94.5-5.fc44.x86_64` | Absent | P14s has it; dotfiles' fingerprint PAM script explicitly requires it; current Vitta lacks it | **ADD** | shared `recipes/vitta-modules.yml` (Task 6) | `podman run --rm --entrypoint rpm ghcr.io/dpietersz/vitta:stable -q fprintd-pam`; `rpm -q fprintd-pam`; `git -C ~/dotfiles grep -n 'fprintd-pam' main -- .chezmoiscripts/run_once_after_10-enable-fingerprint-pam.sh.tmpl` |
| `/usr/lib/udev/rules.d/70-libfprint-2.rules` | file | Present; owned by `libfprint` | Absent | It creates the P14s ELAN SPI fingerprint-device binding. `fprintd` requires `libfprint-2.so.2`, so the existing `fprintd` ADD brings this rule transitively. | **ADD** (covered by existing `fprintd` ADD) | shared `recipes/vitta-modules.yml` (Task 6) | `podman run --rm --entrypoint /bin/bash ghcr.io/ublue-os/bluefin-dx-nvidia-open:stable -c 'rpm -q --requires fprintd; rpm -qf /usr/lib/udev/rules.d/70-libfprint-2.rules'` |
| `nvtop` | rpm | `nvtop-3.3.2-1.fc44.x86_64` | `nvtop-3.3.2-1.fc44.x86_64` | Required explicit P14s NVIDIA tool contract; it is already supplied by the current base | **ADD** | `recipes/vitta-nvidia.yml` | `podman run --rm --entrypoint rpm ghcr.io/ublue-os/base-nvidia:44 -q nvtop` |
| `bolt` and `/usr/lib/udev/rules.d/90-bolt.rules` | rpm/file/unit | Present | RPM absent | `bolt.service` is active on P14s | **HAVE** | existing `recipes/vitta-modules.yml` | `systemctl is-active bolt.service`; `podman run --rm --entrypoint rpm ghcr.io/dpietersz/vitta:stable -q bolt` |
| `ydotool` and `ydotool.service` | rpm/unit | Present | RPM absent | Dotfiles start `ydotoold` and use `ydotool key` after lock release; system unit itself is intentionally disabled | **HAVE** | existing `recipes/vitta-modules.yml` | `git -C ~/dotfiles grep -n -E 'ydotoold|ydotool key' main -- dot_local/bin/scripts`; `podman run --rm --entrypoint rpm ghcr.io/dpietersz/vitta:stable -q ydotool` |
| `zenity` | rpm | Present | RPM absent | Dotfiles use it as the `niri-fabric-popup` prompt fallback | **HAVE** | existing `recipes/vitta-modules.yml` | `git -C ~/dotfiles grep -n 'zenity' main -- dot_local/bin/scripts/executable_niri-fabric-popup`; `podman run --rm --entrypoint rpm ghcr.io/dpietersz/vitta:stable -q zenity` |
| `switcheroo-control`, `switcheroo-control.service`, and `30-discrete-gpu.rules` | rpm/unit/file | Present | RPM absent | Service is active; its rule tags NVIDIA and the non-boot Intel DRM devices as discrete GPUs | **HAVE** | existing `recipes/vitta-modules.yml` | `systemctl is-active switcheroo-control.service`; `podman run --rm --entrypoint rpm ghcr.io/dpietersz/vitta:stable -q switcheroo-control`; `podman run --rm --entrypoint /bin/bash ghcr.io/ublue-os/bluefin-dx-nvidia-open:stable -c 'cat /usr/lib/udev/rules.d/30-discrete-gpu.rules'` |
| `supergfxctl`, `supergfxd.service`, and `90-supergfxd-nvidia-pm.rules` | rpm/unit/file | Present | Absent | `supergfxd.service` is inactive and disabled; no dotfiles reference | **DROP** | none | `systemctl is-active supergfxd.service`; `systemctl is-enabled supergfxd.service`; `git -C ~/dotfiles grep -n 'supergfx' main -- ':!*.md'` |
| `/usr/lib/dracut/dracut.conf.d/80-vfio.conf` | file | Present, unowned; forces `vfio vfio_iommu_type1 vfio-pci` | Absent | `windows-work` has a USB hostdev only, not a PCI hostdev | **DROP** | none | `podman run --rm --entrypoint /bin/bash ghcr.io/ublue-os/bluefin-dx-nvidia-open:stable -c 'cat /usr/lib/dracut/dracut.conf.d/80-vfio.conf'`; `virsh -c qemu:///system dumpxml windows-work` |
| `/usr/lib/dracut/dracut.conf.d/99-nvidia.conf` `force_drivers` | file | Present, owned by `nvidia-kmod-common` | Present, owned by `nvidia-kmod-common` | The live P14s uses `i915` and `nvidia`; base forces `i915 amdgpu nvidia nvidia_drm nvidia_modeset nvidia_peermem nvidia_uvm` | **HAVE** | `base-nvidia` / `nvidia-kmod-common` | `podman run --rm --entrypoint /bin/bash ghcr.io/ublue-os/base-nvidia:44 -c 'rpm -qf /usr/lib/dracut/dracut.conf.d/99-nvidia.conf; cat /usr/lib/dracut/dracut.conf.d/99-nvidia.conf'` |
| `nvidia-persistenced.service` | unit | Enabled | Enabled | Active and enabled on P14s | **HAVE** | `base-nvidia` | `podman run --rm --entrypoint /bin/bash ghcr.io/ublue-os/base-nvidia:44 -c 'systemctl is-enabled nvidia-persistenced.service'`; `systemctl is-active nvidia-persistenced.service` |
| `nvidia-cdi-refresh.path` and `nvidia-cdi-refresh.service` | unit | Both enabled | Both enabled | Path is active/enabled on P14s; its service is enabled and inactive between path-triggered refreshes | **HAVE** | `base-nvidia` | `podman run --rm --entrypoint /bin/bash ghcr.io/ublue-os/base-nvidia:44 -c 'systemctl is-enabled nvidia-cdi-refresh.path; systemctl is-enabled nvidia-cdi-refresh.service'`; `systemctl is-active nvidia-cdi-refresh.path`; `systemctl is-active nvidia-cdi-refresh.service` |
| `nvidia.conf`, NVIDIA udev rules (`60-nvidia*`, `71-nvidia-controllers.rules`, `99-nvidia-cdi-refresh.rules`), and NVIDIA CDI presets | file | Present | Present | Base owns the NVIDIA stack; no Bluefin-specific copy is needed | **HAVE** | `base-nvidia` | `podman run --rm --entrypoint /bin/bash ghcr.io/ublue-os/base-nvidia:44 -c 'rpm -qf /usr/lib/modprobe.d/nvidia.conf /usr/lib/udev/rules.d/60-nvidia.rules /usr/lib/systemd/system-preset/70-nvidia-cdi-refresh.preset'` |

`nvidia-powerd.service` is also present in both images and disabled in both; it
is not a Bluefin delta.

## Category-complete integration-file comparison

The earlier filename-only environment/SELinux check was insufficient. I
re-ran a content comparison for every requested category. The commands below
are the exact read-only capture: `scan_image` invokes **one** `podman run` for
each image, writes the `find -printf "%p %s\n"` inventory and per-file SHA-256
manifest under `/tmp`, then compares the two captured manifests. The third
local-image capture is solely the required current-Vitta equivalence check; no
image was pulled.

```bash
set -euo pipefail
export LC_ALL=C
work=/tmp/vitta-nvidia-integration-comparison
rm -rf "$work" && mkdir -p "$work"
cat > "$work/container-scan.sh" <<'CONTAINER'
set -euo pipefail
sizes=/tmp/category-file-sizes
{
  for d in \
    /usr/lib/bootc/kargs.d \
    /usr/lib/dracut/dracut.conf.d \
    /usr/lib/modprobe.d /etc/modprobe.d \
    /usr/lib/modules-load.d /etc/modules-load.d \
    /usr/lib/udev/rules.d /etc/udev/rules.d \
    /usr/lib/environment.d /etc/environment.d /etc/profile.d \
    /usr/lib/systemd/system-preset /usr/lib/systemd/user-preset \
    /usr/share/X11/xorg.conf.d /etc/X11/xorg.conf.d \
    /etc/nvidia-container-runtime /etc/cdi; do
    [ -d "$d" ] && find "$d" -type f -printf '%p %s\n'
  done
  [ -f /etc/environment ] && find /etc/environment -type f -printf '%p %s\n'
  for d in /usr/share/glvnd /usr/share/vulkan /etc/vulkan; do
    [ -d "$d" ] && find "$d" -type f -name '*.json' -printf '%p %s\n'
  done
  [ -d /usr/share/selinux ] && find /usr/share/selinux -type f -iname '*nvidia*' -printf '%p %s\n'
  for d in /usr/lib/systemd/system /usr/lib/systemd/user; do
    [ -d "$d" ] || continue
    while IFS= read -r -d '' f; do
      name=${f##*/}
      if [[ $name =~ (nvidia|nvctk|supergfx|switcheroo|prime|gpu|fprint|bolt|thunderbolt) ]] || grep -IqiE 'nvidia|nvctk|supergfx|switcheroo|prime|gpu|fprint|bolt|thunderbolt' "$f"; then
        find "$f" -type f -printf '%p %s\n'
      fi
    done < <(find "$d" -type f -print0)
  done
} | sort -u > "$sizes"
printf '%s\n' '--- SIZES ---'; cat "$sizes"
printf '%s\n' '--- SHA256 ---'
while IFS=' ' read -r path size; do sha256sum "$path"; done < "$sizes" | sort -k2,2
CONTAINER
scan_image() {
  local label=$1 image=$2
  podman run --rm --entrypoint /bin/bash "$image" -c "$(< "$work/container-scan.sh")" > "$work/$label.manifest"
  awk '/^--- SIZES ---/{s="sizes";next} /^--- SHA256 ---/{s="sha";next} s=="sizes"{print}' "$work/$label.manifest" > "$work/$label.sizes"
  awk '/^--- SHA256 ---/{s=1;next} s{print}' "$work/$label.manifest" > "$work/$label.sha256"
  awk '{print $1}' "$work/$label.sizes" > "$work/$label.paths"
  awk '{print $2 " " $1}' "$work/$label.sha256" > "$work/$label.path-sha"
}
scan_image bluefin ghcr.io/ublue-os/bluefin-dx-nvidia-open:stable
scan_image base ghcr.io/ublue-os/base-nvidia:44
scan_image vitta ghcr.io/dpietersz/vitta:stable
comm -23 "$work/bluefin.paths" "$work/base.paths" > "$work/bluefin-only.paths"
join -j 1 "$work/bluefin.path-sha" "$work/base.path-sha" |
  awk '$2 != $3 {print $1 "\tbluefin=" $2 "\tbase=" $3}' > "$work/differing.paths"
```

The capture contains 341 Bluefin, 296 base-NVIDIA, and 287 current-Vitta
candidate files. It found **89 Bluefin-only** paths and **12 same-path content
differences** (101 dispositions below). Against current Vitta, 18 are
byte-identical, 13 differ, and 70 are absent. Thus all requested
`kargs.d`, dracut, modprobe, modules-load, udev, environment/profile,
preset, selected system/user-unit, Xorg, GLVND/Vulkan, CDI, and NVIDIA SELinux
locations were considered. The scan found no candidate files in the requested
Xorg, GLVND/Vulkan JSON, NVIDIA-container/CDI, or NVIDIA-SELinux categories.

`exact` below means byte-identical to current `vitta:stable`; `different` means
Vitta has the path but different content. Every `DROP` follows the task rule:
it is neither an active P14s/dotfiles requirement nor an NVIDIA/hybrid
integration file needed by this P14s. Bluefin/GNOME baseline items retain the
already-recorded disposition in the [2026-11-06 gap analysis](2026-11-06-vitta-gap-analysis.md#non-rpm-integration-file-triage).

| Bluefin-only or differing file | Current Vitta result | Verdict and evidence |
|---|---|---|
| `/etc/modprobe.d/kvm.conf` | exact | **HAVE** — Vitta's existing KVM stack supplies it. |
| `/etc/modprobe.d/tuned.conf` | exact | **HAVE** — Vitta already supplies `tuned`. |
| `/etc/modprobe.d/vhost.conf` | exact | **HAVE** — Vitta's existing VM stack supplies it. |
| `/etc/modules-load.d/ip_tables.conf` | absent | **DROP** — Bluefin compatibility module; no P14s evidence. |
| `/etc/profile.d/90-bluefin-starship.sh` | absent | **DROP** — Bluefin branding; 2026-11-06 baseline triage. |
| `/etc/profile.d/91-bluefin-aliases.sh` | absent | **DROP** — Bluefin branding; 2026-11-06 baseline triage. |
| `/etc/profile.d/brew-bash-completion.sh` | absent | **DROP** — Vitta's brew module owns its own profile integration. |
| `/etc/profile.d/brew.sh` | different | **DROP** — Vitta's brew module provides the target-specific variant. |
| `/etc/profile.d/ccache.csh` | absent | **DROP** — no P14s/dotfiles evidence. |
| `/etc/profile.d/ccache.sh` | absent | **DROP** — no P14s/dotfiles evidence. |
| `/etc/profile.d/gnome-ssh-askpass.csh` | absent | **DROP** — GNOME baseline; 2026-11-06 triage. |
| `/etc/profile.d/gnome-ssh-askpass.sh` | absent | **DROP** — GNOME baseline; 2026-11-06 triage. |
| `/etc/profile.d/guestfish.sh` | absent | **DROP** — no P14s/dotfiles evidence. |
| `/etc/profile.d/open.sh` | absent | **DROP** — Bluefin baseline; 2026-11-06 triage. |
| `/etc/profile.d/ublue-fastfetch.sh` | absent | **DROP** — Bluefin branding; 2026-11-06 triage. |
| `/etc/profile.d/ublue-motd.sh` | absent | **DROP** — Bluefin branding; 2026-11-06 triage. |
| `/etc/profile.d/uutils.sh` | absent | **DROP** — no P14s/dotfiles evidence. |
| `/etc/profile.d/vte.csh` | exact | **HAVE** — equivalent Vitta profile exists. |
| `/etc/profile.d/vte.sh` | exact | **HAVE** — equivalent Vitta profile exists. |
| `/etc/environment` | different | **DROP** — Bluefin session environment delta, not NVIDIA/hybrid integration. |
| `/usr/lib/bootc/kargs.d/00-nvidia.toml` | absent | **ADD** — required P14s NVIDIA arguments; `files/vitta-nvidia/usr/lib/bootc/kargs.d/00-nvidia.toml`. |
| `/usr/lib/dracut/dracut.conf.d/80-vfio.conf` | absent | **DROP** — no PCI hostdev in `windows-work`; covered by the VFIO row above. |
| `/usr/lib/dracut/dracut.conf.d/90-passkeys-tpm.conf` | absent | **DROP** — no active P14s/dotfiles evidence. |
| `/usr/lib/modprobe.d/98-v4l2loopback.conf` | exact | **HAVE** — existing shared Vitta virtual-camera configuration. |
| `/usr/lib/modprobe.d/amd-legacy.conf` | absent | **DROP** — P14s uses Intel `i915` plus NVIDIA, not legacy AMD. |
| `/usr/lib/modprobe.d/i2c-dev.conf` | exact | **HAVE** — equivalent Vitta configuration exists. |
| `/usr/lib/modules-load.d/ddcutil.conf` | exact | **HAVE** — equivalent Vitta configuration exists. |
| `/usr/lib/modules-load.d/i2c-tools.conf` | exact | **HAVE** — equivalent Vitta configuration exists. |
| `/usr/lib/modules-load.d/pkcs8.conf` | absent | **DROP** — no P14s/dotfiles evidence. |
| `/usr/lib/modules-load.d/scsi_dh.conf` | absent | **DROP** — no P14s/dotfiles evidence. |
| `/usr/lib/modules-load.d/v4l2loopback.conf` | exact | **HAVE** — existing shared Vitta virtual-camera configuration. |
| `/usr/lib/modules-load.d/zfs.conf` | absent | **DROP** — ZFS is excluded. |
| `/usr/lib/systemd/system-preset/01-homebrew.preset` | absent | **DROP** — Vitta's brew module owns its own target preset. |
| `/usr/lib/systemd/system-preset/01-uupd.preset` | absent | **DROP** — Bluefin updater baseline; 2026-11-06 triage. |
| `/usr/lib/systemd/system-preset/50-zfs.preset` | absent | **DROP** — ZFS is excluded. |
| `/usr/lib/systemd/system-preset/80-workstation.preset` | absent | **DROP** — Bluefin workstation baseline; 2026-11-06 triage. |
| `/usr/lib/systemd/system-preset/81-desktop.preset` | absent | **DROP** — Bluefin desktop baseline; 2026-11-06 triage. |
| `/usr/lib/systemd/system-preset/99-supergfxd.preset` | absent | **DROP** — `supergfxd` is inactive/disabled; no dotfiles reference. |
| `/usr/lib/systemd/system/bolt.service` | exact | **HAVE** — Vitta's `bolt` is active on the P14s. |
| `/usr/lib/systemd/system/fprintd.service` | absent | **ADD** — supplied by the existing shared `fprintd` ADD (Task 6). |
| `/usr/lib/systemd/system/supergfxd.service` | absent | **DROP** — inactive/disabled P14s service; no dotfiles reference. |
| `/usr/lib/systemd/system/switcheroo-control.service` | exact | **HAVE** — Vitta's active hybrid-GPU service is byte-identical. |
| `/usr/lib/udev/rules.d/10-osbuild-inhibitor.rules` | absent | **DROP** — Bluefin build baseline; 2026-11-06 triage. |
| `/usr/lib/udev/rules.d/10-switch.rules` | different | **DROP** — Bluefin release delta, not NVIDIA/hybrid integration. |
| `/usr/lib/udev/rules.d/11-dm-mpath.rules` | absent | **DROP** — multipath is unused. |
| `/usr/lib/udev/rules.d/30-discrete-gpu.rules` | exact | **HAVE** — Vitta's `switcheroo-control` rule tags the P14s NVIDIA device. |
| `/usr/lib/udev/rules.d/50-framework16.rules` | different | **DROP** — unrelated laptop hardware rule. |
| `/usr/lib/udev/rules.d/50-steam-horipad-controller.rules` | different | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/50-usb-realtek-net.rules` | different | **DROP** — unrelated USB-network rule. |
| `/usr/lib/udev/rules.d/60-arduino-mbed.rules` | different | **DROP** — no P14s/dotfiles evidence. |
| `/usr/lib/udev/rules.d/60-ddcutil-i2c.rules` | exact | **HAVE** — equivalent Vitta display-I²C rule exists. |
| `/usr/lib/udev/rules.d/60-mdevctl.rules` | exact | **HAVE** — existing Vitta VM stack supplies it. |
| `/usr/lib/udev/rules.d/60-zvol.rules` | absent | **DROP** — ZFS is excluded. |
| `/usr/lib/udev/rules.d/61-gnome-settings-daemon-rfkill.rules` | absent | **DROP** — GNOME baseline; 2026-11-06 triage. |
| `/usr/lib/udev/rules.d/61-mutter.rules` | absent | **DROP** — GNOME baseline; 2026-11-06 triage. |
| `/usr/lib/udev/rules.d/62-multipath.rules` | absent | **DROP** — multipath is unused. |
| `/usr/lib/udev/rules.d/69-bcache.rules` | absent | **DROP** — bcache is unused. |
| `/usr/lib/udev/rules.d/69-input-remapper-forwarded.rules` | absent | **DROP** — input-remapper is unused. |
| `/usr/lib/udev/rules.d/69-libmtp.rules` | exact | **HAVE** — Vitta's retained `gvfs-mtp` supplies it. |
| `/usr/lib/udev/rules.d/69-vdev.rules` | absent | **DROP** — no P14s/dotfiles evidence. |
| `/usr/lib/udev/rules.d/70-libfprint-2.rules` | absent | **ADD** (covered) — `fprintd` pulls `libfprint`; see its main-table row. |
| `/usr/lib/udev/rules.d/70-titan-key.rules` | different | **DROP** — no P14s/dotfiles evidence. |
| `/usr/lib/udev/rules.d/70-u2f.rules` | different | **DROP** — no P14s/dotfiles evidence. |
| `/usr/lib/udev/rules.d/70-wooting.rules` | different | **DROP** — unrelated keyboard rule. |
| `/usr/lib/udev/rules.d/71-8bitdo-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-alpha_imaging_technology_co-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-astro_gaming-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-betop-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-bigscreen-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-cypress_semiconductor_corp-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-google-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-hori-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-htc-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-logitech-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-mad_catz-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-microsoft-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-nacon-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-nintendo-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-nvidia-gdu.rules` | absent | **DROP** — NVIDIA Shield controller only, not NVIDIA GPU integration. |
| `/usr/lib/udev/rules.d/71-pdp-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-personal_communication_systems_inc-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-pid_codes-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-powera-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-raspberry_pi_ltd-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-razer-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-sony-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-thrustmaster-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-uinput-dev-early-creation.rules` | different | **HAVE** — Vitta has the equivalent static `/dev/uinput` + `uaccess` rule used by `ydotool`; Bluefin additionally guards `ACTION!="remove"`. |
| `/usr/lib/udev/rules.d/71-valve-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-vkb_sim-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/71-zeroplus_technology_corporation-gdu.rules` | absent | **DROP** — unrelated controller rule. |
| `/usr/lib/udev/rules.d/80-iio-sensor-proxy.rules` | absent | **DROP** — no P14s/dotfiles evidence. |
| `/usr/lib/udev/rules.d/88-neutron_hifi_dac.rules` | different | **DROP** — unrelated audio-device rule. |
| `/usr/lib/udev/rules.d/90-bolt.rules` | exact | **HAVE** — Vitta's active Thunderbolt authorisation rule is byte-identical. |
| `/usr/lib/udev/rules.d/90-supergfxd-nvidia-pm.rules` | absent | **DROP** — owned by inactive `supergfxctl`; base NVIDIA already supplies its own stack. |
| `/usr/lib/udev/rules.d/90-zfs.rules` | absent | **DROP** — ZFS is excluded. |
| `/usr/lib/udev/rules.d/92-viia.rules` | different | **DROP** — unrelated USB-device rule. |
| `/usr/lib/udev/rules.d/98-trace-cmd.rules` | absent | **DROP** — diagnostics tooling is unused. |
| `/usr/lib/udev/rules.d/99-input-remapper.rules` | absent | **DROP** — input-remapper is unused. |
| `/usr/lib/udev/rules.d/99-qat-vfio.rules` | exact | **HAVE** — existing Vitta VM stack supplies the identical Intel QAT/VFIO rule. |
| `/usr/lib/udev/rules.d/99-z-dm-mpath-late.rules` | absent | **DROP** — multipath is unused. |

This comparison adds no independent NVIDIA/hybrid ADD beyond the existing
`00-nvidia.toml` row. The two fingerprint paths above are covered by the
already-required shared `fprintd` package ADD; `fprintd`'s `libfprint`
dependency supplies the ELAN rule. No item is undecidable, so the ASK section
remains empty.

## Final ADD input for later tasks

| item | destination |
|---|---|
| `00-nvidia.toml` with the four kernel args above, in order | `files/vitta-nvidia/usr/lib/bootc/kargs.d/00-nvidia.toml` |
| `fprintd` | shared `recipes/vitta-modules.yml` (Task 6) |
| `fprintd-pam` | shared `recipes/vitta-modules.yml` (Task 6) |
| `nvtop` | `recipes/vitta-nvidia.yml` |

## Dotfiles audit for Task 8

The following inspection is intentionally against `~/dotfiles` `main` blobs,
not its live working tree:

```bash
git -C ~/dotfiles grep -n -E 'hasNvidia|hasFingerprintReader|hardwareModel' main -- ':!*.md'
```

On this P14s, `hasNvidia=true`, `hasFingerprintReader=true` (Synaptics
`06cb:00f9`), and the model value is `21G2CTO1WW`. On Vitta,
`.isVitta=true`, `.isMyImage=true`, `.isBluefin=false`, and `.remote=false`.
There is no source template condition comparing `hardwareModel` to the P14s
model; it is detected and printed by `verify-image` only. Test fixtures are
not deployment conditions.

| main template condition / consumer | P14s outcome on Vitta | Task 8 implication |
|---|---|---|
| `.chezmoi.toml.tmpl`: USB fingerprint and `lspci` probes; exports `hardwareModel`, `hasFingerprintReader`, and `hasNvidia` | All P14s values remain true/current; Vitta is treated as local (`remote=false`) because `isVitta=true` | Keep the hardware probes; they are image-independent. |
| `.chezmoitemplates/image-identity.tmpl`: `isVitta` takes precedence over `hasNvidia`; only `ghcr.io/dpietersz/vitta(:|@|$)` is a Vitta booted ref | `ID=vitta` still makes `isMyImage=true`, but `vitta-nvidia` is not recognised as a Vitta ref and `expectedImageFamily` is `vitta`, not `vitta-nvidia` | Extend the identity/ref and expected-family rule for `vitta-nvidia`. |
| `.chezmoitemplates/image-flags.tmpl`: fallback `hasNvidia -> bluefin-udx-nvidia` | Not reached with current Vitta data, whose `expectedImageFamily` is already present | Update only if the identity data contract changes; do not use the fallback to identify Vitta NVIDIA. |
| `run_once_after_10-enable-fingerprint-pam.sh.tmpl`: exits only for remote/macOS/no-reader; package branch treats `isMyImage` as atomic | It runs on Vitta P14s. After Task 6 provides the packages, it proceeds to `authselect` instead of layering; before that it would try forbidden layering | Preserve the baked package prerequisite and decide separately how/when the existing PAM state is reconciled. |
| `run_once_after_11-install-hyprlock-stack.sh.tmpl`: `$img.isMyImage` exit is before the fingerprint branch | Exits: Vitta already bakes `hyprlock` and `swayidle` | No package installer change required. |
| `run_onchange_after_16-keyring-passwordless-gdm.sh.tmpl`: fingerprint guard then `or .isBluefin .isFedora` | Exits because Vitta is neither Bluefin nor `ID=fedora`; Vitta uses greetd, not GDM | Leave it GDM-only. |
| `run_onchange_before_00a-verify-image.sh.tmpl`: renders NVIDIA/model facts and uses `$img.isVitta` | Runs because `isMyImage=true`. A nonempty `vitta-nvidia` ref still contains `ghcr.io/dpietersz/vitta`, so the loose match reports the Vitta family as correct | Tighten expected identity/ref handling so the displayed family is explicitly `vitta-nvidia`. |
| `insta360-toolbox.ini.tmpl` and `udx-toolbox.ini.tmpl`: `nvidia={{ if .hasNvidia }}` | Render `nvidia=true` | Preserve NVIDIA passthrough. |
| `hyprlock.conf.tmpl`, `hyprlock-pre-vitta.conf.tmpl`, and `hyprlock-classic-visuals.tmpl`: fingerprint block/placeholder | Enable the fingerprint block and retain password PAM fallback; Vitta selects generated theme with a static fallback | Preserve both authentication paths; password remains available during a fingerprint wait. |
| `executable_niri-lock.sh.tmpl`: Vitta renderer branch plus fingerprint visual input and unconditional `ydotool` reset | Uses the Vitta theme/fallback and executes the post-unlock `ydotool` reset | Keep `ydotool` baked; it is needed after a fingerprint unlock to re-arm niri idle timers. |

## ASK

None. Every retained or dropped P14s-specific item meets the stated triage rule
with command evidence above.

## Follow-up boundary

Tasks 2, 6, and 9 apply only the four ADD entries. In particular, do not copy
Bluefin's VFIO or supergfx configuration, and do not reproduce base NVIDIA
configuration already owned by `nvidia-kmod-common` / `base-nvidia`.
