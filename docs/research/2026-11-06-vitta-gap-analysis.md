# Vitta gap analysis — Bluefin/DX beyond `base-main:44`

**Scope:** Intel Vitta image. This records the exact package and integration-file
Delta from `ghcr.io/ublue-os/bluefin-dx-nvidia-open:stable` to
`ghcr.io/ublue-os/base-main:44`; it is not a request to retain the NVIDIA
stack.

## Method

`scripts/vitta-gap-report.sh` pulls both images, writes C-locale sorted package
and selected integration-file lists to `/tmp/vitta-gap-report` (override with
`OUTPUT_DIR`), and writes the two Bluefin-only `comm -13` results there. The
run for this analysis used `OUTPUT_DIR=/tmp/vitta-gap` and found:

| List | Bluefin/DX | base-main | Bluefin-only |
|---|---:|---:|---:|
| RPM names | 2,238 | 1,356 | 895 |
| systemd, profile.d, sysusers, udev files | 1,014 | 756 | 290 |

The supplied `/tmp/layers/*.names` inputs were not C-sorted (`adw-gtk3-theme`
followed an out-of-order entry), so the script deliberately sorts its own
`rpm -qa` output before calling `comm`.

I checked the audit's command/service evidence and searched
`~/dotfiles` excluding `.git`, `.ai`, and Markdown. Direct evidence supports
Docker, the Windows Work VM (`virsh`, `virt-viewer`), Tailscale, Android SDK,
GNOME keyring, the portal/files stack, Noto Serif's fontconfig canary, and
`tuned-ppd`. The owner-decided defaults below are recorded unchanged.

## Final RPM ADD line for Task 4

Paste this as the explicitly requested RPM install set (not the `akmods`
module input):

```text
android-tools code containerd.io docker-buildx-plugin docker-ce docker-ce-cli docker-ce-rootless-extras docker-compose-plugin edk2-ovmf gcc gnome-keyring gnome-keyring-pam google-noto-sans-fonts google-noto-serif-fonts google-noto-color-emoji-fonts gvfs gvfs-gphoto2 gvfs-mtp libvirt-client libvirt-daemon-kvm make nautilus podman-compose qemu-kvm swtpm tailscale tuned tuned-ppd virt-install virt-manager virt-viewer virtiofsd xdg-desktop-portal-gnome xdg-user-dirs
```

`kmod-v4l2loopback` / `v4l2loopback` are also **ADD**, but through the
BlueBuild `akmods` module, not that RPM install line. Its existing modprobe and
modules-load files stay in the image.

> **Package-name concern:** the required owner-default names
> `google-noto-sans-fonts` and `google-noto-serif-fonts` are in neither current
> image; `google-noto-color-emoji-fonts` is already in `base-main:44`. They are
> deliberately kept verbatim above as required by the task brief. Task 4 must
> resolve the exact names against its Fedora repositories before building; do
> not silently substitute the current `*-vf-fonts` names.

## RPM triage

Rows are evaluated in order. They are mutually exclusive; the final
catch-all is the set difference of the generated `bluefin-only.names` file and
all preceding rows. Thus every one of the 895 package names has an explicit
status without making the triage an 895-row catalogue. Counts are from the
recorded run.

| Package set (count) | Status | Decision |
|---|---|---|
| `git`, `wtype` (2) | ALREADY-IN-COMMON | Both are already in `recipes/common.yml`. |
| `android-tools`, `gcc`, `make`, `gnome-keyring`, `gnome-keyring-pam`, `gvfs`, `gvfs-gphoto2`, `gvfs-mtp`, `nautilus`, `tuned`, `tuned-ppd`, `xdg-desktop-portal-gnome`, `xdg-user-dirs` (13) | ADD | Owner defaults: Android setup/Homebrew builds; keyring; portal; file/device handling; power D-Bus API; user directories. |
| `containerd.io`, `docker-buildx-plugin`, `docker-ce`, `docker-ce-cli`, `docker-ce-rootless-extras`, `docker-compose-plugin`, `podman-compose` (7) | ADD | Daily Docker workloads and dotfiles container scripts. |
| `edk2-ovmf`, `libvirt-client`, `libvirt-daemon-kvm`, `qemu-kvm`, `swtpm`, `virt-install`, `virt-manager`, `virt-viewer`, `virtiofsd` (9) | ADD | Windows Work VM needs x86 KVM, `virsh`/viewer, TPM, OVMF, and VirtIO-FS; selecting `libvirt-daemon-kvm` avoids Bluefin's broad hypervisor set. |
| `code`, `tailscale` (2) | ADD | Audit shows light VS Code use and active Tailscale nodes; the dotfiles use `tailscale serve`. |
| `kmod-v4l2loopback`, `v4l2loopback` (2) | ADD (akmods) | Required OBS virtual camera; recreate with BlueBuild's ublue-signed `akmods` module rather than copying Bluefin's kernel package. |
| `egl-*`, `kmod-nvidia`, `libnvidia-*`, `libva-nvidia-driver`, `nvidia-*`, `nvidia-container-toolkit*`, `supergfxctl`, `ublue-os-nvidia-addons`, `xorg-x11-nvidia` (26) | DROP | NVIDIA phase. |
| GNOME/Flatpak/session stack: `gdm`, `gnome-*` (except retained keyring), `flatpak-*`, `mutter*`, `gcr*`, `vte*`, `nautilus-*`, `ptyxis`, GNOME backgrounds/theme helpers (64) | DROP | GDM and every GNOME session/shell package are explicitly absent; retained Nautilus is the file manager only. |
| `cockpit-*` (8), `incus*`, `lxc*`, `cowsql`, `raft` (17) | DROP | Cockpit and Incus/LXC are explicitly absent and unused. |
| `zfs`, `kmod-zfs`, `lib{nvpair3,uutil3,zfs7,zpool7}`, `python3-pyzfs` (7) | DROP | ZFS is explicitly absent and has no pools. |
| `qemu-*` except `qemu-kvm`, plus `ipxe-roms-qemu`, firmware, display, user-static, and ancillary packages (109) | DROP | Preserve only x86 KVM; all-architecture emulators are explicitly excluded. |
| `libvirt*` except `libvirt-client` and `libvirt-daemon-kvm`, plus `libtpms` (36) | DROP | The selected KVM daemon resolves its own minimal runtime dependencies; do not pull Bluefin's LXC, Xen, vbox, gluster, iSCSI, and broad driver set. |
| remaining `lib*` packages (99) | DROP | Transitive libraries of dropped desktop, VM, storage, diagnostics, and enterprise stacks; selected ADD packages pull their own dependencies. |
| `perl-*` (67) and remaining `python3-*` (34) | DROP | Interpreters/modules pulled by omitted tooling, not direct Vitta requirements. |
| `NetworkManager-*` VPN/PPP/team plugins, `openconnect`, `openvpn`, `vpnc*`, `nm-connection-editor`, `teamd` (19) | DROP | No evidence for these enterprise/legacy connection types. |
| `glusterfs*` (4), `samba*` (8), iSCSI, multipath, NBD/guestfs, HTTPD, autofs, davfs, `wsdd` and related storage/network packages (39) | DROP | No server, AD join, distributed storage, or block-storage workload. |
| bcc/bpftrace/systemtap/trace-cmd, kernel headers/devel, LLVM/Clang, ccache and other build/debug helpers (40) | DROP | No usage evidence; `gcc` and `make` are the decided developer build dependencies. |
| Adobe Source Code Pro, Cascadia, JetBrains, Montserrat, Nerd, and OpenDyslexic font packages (8) | DROP | The chosen fonts are owner-mandated Noto plus separately supplied Monaspace. |
| Bluefin optional tools/services including `borgbackup`, `rclone`, `restic`, `fish`, `zsh`, `fprintd*`, `input-remapper`, `lm_sensors`, `setroubleshoot-*`, `sysstat`, `uupd`, and `waypipe` (32) | DROP | Audit marks these unused or Vitta explicitly replaces/removes them; fingerprint work is a later P14s phase. |
| Every remaining name in `bluefin-only.names` after the rows above (263) | DROP | Unselected Bluefin/DX application roots or their dependencies (for example AD/auth, media preview, Qt/KDE, source-control extras, osbuild, SPICE, and legacy X11 tools). Search found no dotfiles or audit usage requiring an individual exception. |

The three mandated font packages are outside this RPM delta: two are absent
from both current images and one is already in the base. They are nevertheless
ADD by owner decision and are present in the final line exactly as supplied.

## Non-RPM integration-file triage

The 290 files are also covered in ordered, exhaustive rows below. **ADD via
package/module** means install the package/module and retain its generated
unit/rule; do not copy a Bluefin-owned file verbatim.

| File set (count) | Status | Decision |
|---|---|---|
| `/etc/profile.d/brew{,-bash-completion}.sh` and `brew-{setup,update,upgrade}.{service,timer}` (7) | ADD | BlueBuild `brew` module / `ghcr.io/ublue-os/brew` layer replaces Bluefin's brew setup and timers. |
| `bluefin-dx-groups.service` (1) | ADD (replacement) | Implement `vitta-groups.service` for `docker` and `libvirt`; do not retain the Bluefin name or Incus group. |
| `libvirt-workaround.service` (1) | ADD (reimplement) | Preserve the workaround's behavior for the Windows Work VM after inspecting the source unit; never copy it blindly. |
| `containerd.service`, `docker.service`, `docker.socket` (3) | ADD via package | Required Docker runtime. |
| `libvirtd*`, `virtqemud*`, `virtnetworkd*`, `virtlogd*`, `virtlockd*`, `virtproxyd*`, `qemu-{pr-helper,vmsr-helper}*`, `virt-guest-shutdown.target`, and `libvirt{,-qemu}.conf` (33) | ADD via package | Selected VM packages own these core KVM files. Do not re-add the Bluefin-only LXC, Xen, vbox, or storage-backend daemons. |
| `tailscale-{online.target,wait-online.service}`, `tailscaled.service` (3) | ADD via package | Active Tailscale service. |
| `tuned.service`, `tuned-ppd.service` (2) | ADD via package | Dotfiles call the power-profiles D-Bus API. |
| `/usr/lib/udev/rules.d/69-libmtp.rules` (1) | ADD via package | Comes from retained `gvfs-mtp`. |
| Every other Bluefin-only profile, unit, sysusers file, and udev rule (remaining files) | DROP | Belongs to the dropped GNOME/GDM, Flatpak, NVIDIA, ZFS, Incus/LXC, Cockpit, enterprise storage, diagnostics, or optional Bluefin feature set. |

## Follow-up boundaries

This task adds no recipe entries. Task 4 owns the new Vitta recipe, repository
sources, `akmods` configuration, smoke checks, and the replacement group and
libvirt-workaround units. It must resolve the owner-mandated Noto package names
before the first build.
