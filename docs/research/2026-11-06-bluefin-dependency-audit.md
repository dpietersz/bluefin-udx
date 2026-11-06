# What does bluefin-dx actually give us? — dependency audit, 2026-11-06

Evidence base: package/unit/file diffs of five images, ~4 weeks of journal on the
P14s (16 boots, 2026-10-10 → 2026-11-06), shell history (last 2000 lines),
container/VM inventories, loaded modules, update logs, and the dotfiles source.
NVIDIA track compared (P14s); the Intel track differs only by the NVIDIA stack.

## 1. The stack, layer by layer

| Layer | Image | Adds (RPMs) | What it really is |
|---|---|---|---|
| L0 | `quay.io/fedora/fedora-silverblue:44` | 1522 total | Fedora Atomic + GNOME |
| L1 | `ghcr.io/ublue-os/silverblue-nvidia:44` | +152 / −14 | **Universal Blue main**: NVIDIA open kmod (signed, ublue MOK), negativo17 ffmpeg/codecs (replaces `*-free`), `nvidia-container-toolkit`, distrobox, just, u2f/yubikey, udev rules, Xorg-for-NVIDIA |
| L2 | `ghcr.io/ublue-os/bluefin-nvidia-open:stable` | +214 / −15 | **Bluefin**: GNOME extensions/tweaks, Homebrew (`brew-setup`), `uupd`, `kmod-v4l2loopback`, **`kmod-zfs`+`zfs`** (stable only), tailscale, samba/AD join, fish/zsh, gcc/make, sysstat, lm_sensors, input-remapper, borg/restic/rclone, ~43 preinstalled Flatpaks, removes Firefox RPM |
| L3 | `ghcr.io/ublue-os/bluefin-dx-nvidia-open:stable` | +381 / −2 | **DX**: docker-ce, libvirt + qemu (**every** arch emulator), virt-manager, incus/lxc, cockpit, VS Code, bpftrace/bcc/systemtap, android-tools, podman-compose/tui, osbuild, glusterfs/iscsi, setroubleshoot |
| L4 | `ghcr.io/dpietersz/bluefin-udx-nvidia:stable` | +116 | **Ours**: niri stack, apps, vendor repos (see RECIPE.md) |

## 2. What the last month says you actually use

### Interactive commands (shell history, top 250, by provider)
- **Homebrew (31 tools)**: yazi 81, chezmoi 58, nvim 32, uv, vault, bash (login shell!), tuios, bun, dbt, az, btop, kubectl, databricks, gh, codex, aws, mpv, zellij…
- **~/.local/bin + mise (17)**: pi 455, claude 91, just 45, mise 21, …
- **Fedora base**: git, rpm-ostree, podman, ssh, wl-copy
- **Our layer**: pass 53, zeditor 25
- **DX**: docker, podman-compose · **Bluefin**: `zed` once (that was the *ZFS event daemon* by accident) · **ublue**: tmux
- `ujust`: **zero** invocations.

→ Your daily toolbox is Homebrew + your own scripts. The image layers mostly
supply *plumbing*, not tools you type.

### Services that actually ran (system journal, 30 d)
| Provider | Ran | Verdict |
|---|---|---|
| ublue (L1) | nvidia-persistenced/powerd/cdi-refresh, smartd | **needed** (NVIDIA + CDI for GPU containers) |
| Bluefin (L2) | `uupd` (36), `tailscaled` (17), `zfs-zed` + zfs-mount/share (74), sysstat-collect (3251), lm_sensors, input-remapper | uupd + tailscale **used**; zfs **dead weight** (module loaded, `zpool list` = no pools); sysstat/input-remapper unused |
| DX (L3) | docker/containerd (11), virtqemud/virtnetworkd/virtlogd (~60), **setroubleshootd 14 839 starts** | docker + libvirt **used**; setroubleshoot is noise (2320× Garage container AVC, 58× virtqemud cache) |
| image non-RPM | ublue-system-setup, bluefin-dx-groups, flatpak-preinstall, flatpak-nuke-fedora, dconf-update, libvirt-workaround | groups + libvirt-workaround **used** (you're in docker/libvirt/incus-admin groups via bluefin-dx-groups) |

### Workloads
- **docker**: 293 images, daily containers (postgres, test runners) — **heavy use** (DX)
- **libvirt system**: `windows-work` VM — **critical** (DX: libvirt, qemu-kvm, swtpm, edk2-ovmf, virtiofsd)
- **podman/distrobox**: udx-toolbox, playwright, ubuntu-gui-toolbox, sfe-pg — **heavy** (L0 podman + L1 distrobox)
- **incus**: never initialised — **unused** (DX)
- **tailscale**: two nodes up — **used** (Bluefin RPM; you also run a user-level `tailscaled-factory`)
- **VS Code** (`code`, DX repo): launched 11× — **light use**
- **Flatpaks**: 43 installed, all from Bluefin preinstall (GNOME apps, Bazaar, Firefox, Thunderbird). Launch evidence: NautilusPreviewer 31, Loupe 4. Your "no Flatpak" rule is already violated *by the base*, not by you.
- **Loaded modules**: nvidia (L1), zfs (L2, unused), v4l2loopback (L2, OBS virtual cam), kvm_intel, uinput.

## 3. Hidden couplings between dotfiles and Bluefin

1. **`isBluefin` = "our image".** `.chezmoi.toml.tmpl` detects `VARIANT_ID=bluefin…`. 15 uses in 6 files gate the hyprlock/idle stack, noctalia config, insta360/equibop installers, toolbox creation. Any base whose os-release isn't Bluefin silently disables them.
2. **`zeditor` exists only because of Bluefin's ZFS.** Terra's `zed` installs `zed-cli-compat-zfs` (→ `zeditor`) *only if* `zfs` is present; otherwise `/usr/bin/zed` is the editor. Bluefin ships ZFS only on `:stable`. Dotfiles hardcode `zeditor` (workspace templates, notebook wrapper). Found by the new `:latest` canary on 2026-11-06.
3. **Login shell is Homebrew bash** (`/home/linuxbrew/.linuxbrew/bin/bash`), plus 32 hardcoded `/home/linuxbrew` paths. Homebrew arrives via Bluefin's `brew-setup` service (ublue-os/brew OCI layer). No brew → no login shell.
4. **Group membership** (docker, libvirt, incus-admin) comes from `bluefin-dx-groups.service`, not from dotfiles.
5. **Signed v4l2loopback** comes from Bluefin, not ublue main (L1 lacks it). Our recipe deliberately does not add it.

## 4. Operational costs we are paying today

- **94.5 GB of OS downloads in 30 days**: 33 image pulls, average 2.86 GB. Upstream rechunks (chunkah) for small deltas; our ~19 non-rechunked custom layers re-download whole on nearly every nightly.
- **11 failed automatic updates** in 30 days:
  - 5× `repomd.xml GPG signature verification error` on **Terra** — caused by the *host-side* repo refresh that rpm-ostree must do because two packages are **layered locally** (`equibop` local RPM + `fuse-libs`).
  - 6× `min-free-space-percent '3%' would be exceeded` (transient disk pressure; same as upstream issue #4973).
- **Two update agents enabled**: `uupd.timer` (Bluefin) *and* `rpm-ostreed-automatic.timer` (stage).
- Image size ~17.7 GB, of which ~380 DX packages are largely unused (all-arch qemu-user-static, glusterfs, iscsi, cockpit, osbuild, systemtap…).

## 5. Why upstream is moving (sourced)

From *Bluefin 2025* (castrojo) and later posts:
- **GNOME is the product, distro is plumbing.** Dakota = Bluefin on GNOME OS, "assembled entirely from source" with BuildStream; work "with our critical upstreams directly instead of waiting for traditional distributions to catch up"; testing branches tracking dev GNOME.
- **No system package manager at all** in Dakota; local layering unsupported everywhere. Apps = Flatpak, CLI = Homebrew.
- **Build economics**: from-source builds in ~8 min, "4 minutes faster than assembling RPMs" (Dakota Alpha 5); one BuildStream source yields bootc *or* DDI artefacts (Server).
- **Secure Boot via systemd-boot**, OGC kernels "only patches with a path upstream", smaller updates via chunkah.
- **Shared OCI layers** (`projectbluefin/common`, `ublue-os/brew`) so custom images compose pieces instead of inheriting a whole distro.
- **Agentic factory** (Hive, testsuite, Prow) to scale review/testing.
- **Utah** = Bluefin on Red Hat's *Project* Hummingbird: Rawhide-based, rolling, hardened/near-zero-CVE goal, chunkah, Konflux hermetic builds. "Fedora Hummingbird" naming is disputed by Fedora contributors; Utah is pre-alpha.

## 6. What is NOT going away
Universal Blue's base layer is healthy and shared beyond Bluefin: `ublue-os/main`
and `ublue-os/akmods` pushed today; **Bazzite already builds on
`ghcr.io/ublue-os/kinoite-main:45`**; akmods has `main-45-7.2.15` kernels.
Desktop-less ublue bases exist and are current: `ghcr.io/ublue-os/base-main:{44,45}`,
`ghcr.io/ublue-os/base-nvidia:{44,45}` (built 2026-11-06).
Community niri bootc images exist on these patterns (zirconium, ublue-niri,
atomic-niri, fila, kumaOS).
