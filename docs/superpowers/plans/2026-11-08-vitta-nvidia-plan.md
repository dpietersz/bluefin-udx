# Vitta for the P14s (NVIDIA variant) — plan

Status: **implemented through Phase 4; owner switch and one-week acceptance remain** (2026-11-12). Builds on everything
proven on the T580 (`vitta`, spec `2026-11-06-vitta-design.md`, boot splash
`2026-11-07-…`, LUKS prompt `2026-11-08-…`). The executable record is
[`2026-11-11-vitta-nvidia-implementation.md`](2026-11-11-vitta-nvidia-implementation.md);
the owner follows [`vitta-p14s-acceptance.md`](../../how-to/vitta-p14s-acceptance.md)
before deciding to switch.

## What changed during implementation (2026-11-12)

- Upstream retired `base-nvidia`; `vitta-nvidia` now uses `base-main:44` plus
  BlueBuild's `akmods` module with `nvidia-driver: nvidia-open`.
- The module owns the four NVIDIA boot arguments in
  `/usr/lib/bootc/kargs.d/00-bluebuild-nvidia-kargs.toml`.
- D2 is superseded: greetd accepts a password only. Fingerprint remains for
  hyprlock and sudo through the host authselect profile.
- The executable plan and the P14s acceptance runbook above are authoritative
  for implementation and the owner-operated hardware switch.

## 1. Goal

A signed `ghcr.io/dpietersz/vitta-nvidia` image that replaces
`bluefin-udx-nvidia:stable` on the **ThinkPad P14s Gen 5** with zero loss of
function, the same login / lock / boot / LUKS look as the T580, and a rollback
path to `bluefin-udx-nvidia` until accepted.

## 2. What the P14s is (measured 2026-11-08)

| | P14s |
|---|---|
| CPU / iGPU | Intel Core Ultra 7 155H, Meteor Lake Arc iGPU (drives the panel, `card0-eDP-1`) |
| dGPU | NVIDIA RTX 500 Ada (AD107GLM), PRIME offload "3D controller", driver 615.78.08 |
| Panel | 2560×1600 @ 90 Hz, niri scale 1.5 |
| Kernel args | `rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1 initcall_blacklist=simpledrm_platform_driver_init rhgb quiet` |
| Fingerprint | Synaptics `06cb:00f9`, `fprintd` + `fprintd-pam`, authselect `with-fingerprint` (`pam_fprintd.so sufficient` in system-auth) |
| Keyring | **empty-password** login keyring; dotfiles `16-keyring-passwordless-gdm` strips `pam_gnome_keyring` from `gdm-password` so nothing re-encrypts it |
| VM | `windows-work` (system libvirt, 6 vCPU pinned to P-cores, 16 GiB, 3 VirtioFS shares + USB camera hostdev — see dotfiles `docs/how-to/windows-work-vm.html`) |
| Local layers | `equibop` (local RPM), `fuse-libs` |
| Role | Telegram bot host (R24), primary workstation |

## 3. Base and image shape

- **Base:** `ghcr.io/ublue-os/base-nvidia:44` (built 2026-11-07; ships
  `kmod-nvidia`, `nvidia-driver`, `nvidia-container-toolkit`; no kargs.d).
- **Recipe:** `recipes/vitta-nvidia.yml` = same modules as `vitta.yml`
  (common.yml + vitta-modules.yml + initramfs) on the NVIDIA base, plus an
  NVIDIA-only module list (as `bluefin-udx-nvidia.yml` does today: `nvtop`).
  Smoke gate: the Vitta branch plus today's Phase-4 NVIDIA checks
  (`nvidia-smi`, `nvidia-ctk`, kmod present and signed).
- **CI:** one more matrix leg `{recipe: vitta-nvidia, stream: testing}`,
  manual promotion via the new promote workflow (parameterised by image).
- **Kernel args:** ship `/usr/lib/bootc/kargs.d/10-vitta-nvidia.toml` with the
  four NVIDIA args so fresh installs get them; existing args on the P14s
  persist across rebase (bootc does not duplicate identical kargs from
  kargs.d — verify in a VM/CI before relying on it).

## 4. Phases

### Phase 0 — Gap analysis (½ day)
Rerun `scripts/vitta-gap-report.sh` against `bluefin-dx-nvidia-open:stable`
vs `base-nvidia:44`; triage NVIDIA/Bluefin-only packages (e.g. `supergfxctl`,
`nvidia-settings`, Xorg-for-NVIDIA bits) against what the P14s actually uses
(journal + dotfiles, same method as the T580 audit). Output: ADD/DROP table.

**Pre-checked 2026-11-10 against this P14s (must be in the ADD list):**
- `bolt` — Thunderbolt device authorisation; the P14s uses a Thunderbolt dock
  (`TBU405Pro`), `bolt.service` is active today. Missing in Vitta.
- `ydotool` — dotfiles `niri-idle-daemon.sh` starts `ydotoold` and
  `niri-lock.sh` uses it to reset niri's idle timer after unlock. Missing in
  Vitta, so this is also a **live bug on the T580** (fix in the shared Vitta
  module list, not only the NVIDIA one).
- `zenity` — prompt fallback in dotfiles `niri-fabric-popup`. Missing in Vitta.
- `switcheroo-control` — running today; hybrid-GPU launch-on-dGPU helper.
- Not needed (GNOME session pieces, unused): gdm, gnome-shell/-control-center/
  -tweaks/-system-monitor/-disk-utility, ptyxis, gsconnect, input-remapper
  (active but no config), rygel, gnome-user-share, malcontent, sysprof,
  setroubleshoot, ibus-mozc/unikey, zfs (zeditor link already in Vitta).
- NVIDIA userspace (`nvidia-persistenced`, `nvidia-settings`,
  `nvidia-driver-common`) comes from `base-nvidia` (driver 620.70.06 vs
  615.78.08 today — newer branch; verify CUDA/NVENC in Phase 4).

**Windows VM pre-check (2026-11-10): every requirement is already in the
Vitta image at identical versions** — QEMU 10.2.2 (`pc-q35-10.2`), libvirt
12.0.0 (qemu/network/storage drivers, `default` network), swtpm 0.10.2
(`tpm-crb`), OVMF 4M secboot code+vars, virtiofsd (3 shares), SPICE
(ui/char/audio, usb-redirect, usb-host, qxl, spice-server, usbredir),
virt-viewer/remote-viewer, dnsmasq/nftables/firewalld, libvirt sockets
enabled, `vitta-groups` (libvirt group) and `vitta-libvirt-relabel`. The VM's
disk, NVRAM, TPM state and domain XML live in `/var/lib/libvirt`,
`/var/lib/swtpm-localca` and `/etc/libvirt`, which a rebase keeps.
Flatpak apps (41, in `/var/lib/flatpak`) also survive the rebase.

### Phase 1 — Image builds and smoke-boots in CI (1 day)
Recipe, matrix leg, kargs.d, smoke gate. Acceptance: CI green, image signed as
`vitta-nvidia:testing`, gap table applied. No hardware yet.

### Phase 2 — Graphics stack on hybrid Intel + NVIDIA (1–2 days)
Risks to retire, in order:
1. **Boot splash / LUKS prompt with `initcall_blacklist=simpledrm`.** There is
   no early framebuffer; Plymouth only appears once the Intel KMS driver
   (`i915`/`xe`) is in the initramfs and loaded. Ensure the iGPU driver is in
   the initramfs (and NVIDIA modules are *not* forced early). Fallback: plain
   text prompt must still work.
2. **greetd → cage on hybrid graphics.** wlroots must render on the Intel GPU
   that drives the panel (`WLR_DRM_DEVICES` pinned to the iGPU card if cage
   picks the NVIDIA device); verify edge-to-edge and the 1.5 scale look.
3. **niri session unchanged** (already runs on this hardware today).
4. **Boot splash logo:** the P14s badge = Fedora + **Lenovo** wordmark, same as
   T580 (both are Lenovo) — no new art needed unless the owner wants a
   "ThinkPad" variant.

### Phase 3 — Fingerprint login and lock (1–2 days)
- **greetd PAM:** add fingerprint to the greeter's auth (the image already has
  `fprintd-pam`; authselect `with-fingerprint` lives in `/etc`, carried over on
  rebase). The Quickshell greeter must show fprintd's PAM messages ("Place
  your finger…", retries) — Auth.qml already handles info/error messages;
  add a "touch the sensor or type your password" state and test it in the
  preview harness with a fake fprintd conversation.
- **Keyring:** the P14s keyring is passwordless. On greetd, port
  `16-keyring-passwordless-gdm` to greetd: strip/keep `pam_gnome_keyring` in
  `/etc/pam.d/greetd` the same way, gated on `hasFingerprintReader` + Vitta.
  (On the T580 the keyring is password-synced and stays as is.)
- **Lock screen:** hyprlock fingerprint block already exists in dotfiles;
  verify with the Vitta theme include.

### Phase 4 — Workstation parity (1 day)
- Windows work VM: libvirt sockets, pinned vCPUs, VirtioFS shares (Z:/Y:/X:),
  camera hostdev, `windows-work-audio` — run the existing
  `windows-work` tests and a real boot of the VM.
- CUDA in containers: `podman run --device nvidia.com/gpu=all … nvidia-smi`
  (CDI spec regenerated by `nvidia-cdi-refresh`).
- OBS: NVENC encoder present (`h264_nvenc`), v4l2loopback on `/dev/video10`.
- `equibop` / `fuse-libs` local layers: rebuild state with `rpm-ostree
  rebase` (carries them) or move them into the image/toolbox — owner decision.
- Telegram bot (R24) keeps running on `p14`.

### Phase 5 — Switch the P14s (½ day + a working week of daily use)
1. `rpm-ostree status` (note rollback), rebase to
   `ostree-image-signed:docker://ghcr.io/dpietersz/vitta-nvidia:testing`.
2. Reboot: splash + styled LUKS prompt on the 2560×1600 panel, greeter with
   fingerprint, keyring unlocked, niri/Noctalia identical.
3. `cd ~/dotfiles && git pull && chezmoi init && chezmoi apply`.
4. Acceptance runbook (new `docs/how-to/vitta-p14s-acceptance.md`, derived from
   the T580 one + Phase 3/4 items). Promote `vitta-nvidia:stable` after a
   week without regressions.

### Phase 6 — Retire bluefin-udx (after both laptops are on Vitta stable)
Drop the `bluefin-udx*` recipes and their CI legs, rename the repo to `vitta`
(GitHub redirects), collapse the Bluefin-only smoke checks and docs, update
dotfiles (`isBluefin` gates become legacy-only).

## 5. Risks (most likely first)

| Risk | Mitigation |
|---|---|
| No splash / invisible LUKS prompt because of `initcall_blacklist=simpledrm` | Intel KMS in initramfs; Esc → text prompt; keep previous deployment in GRUB |
| cage picks the NVIDIA device → black or slow greeter | pin `WLR_DRM_DEVICES` to the iGPU; smoke-test with a fake DRM topology where possible, real check on P14s |
| Fingerprint PAM conversation hangs the greeter | preview harness with fake fprintd; password always works in parallel |
| Passwordless keyring gets re-encrypted by greetd PAM | port the gdm guard to greetd before first login; test with a throwaway keyring |
| VM regressions (libvirt group, SELinux relabel, VirtioFS) | reuse `vitta-groups` + `vitta-libvirt-relabel`; run VM before switching daily use |
| kargs duplication from kargs.d on a rebased machine | verify bootc behaviour in CI/VM first; else ship kargs only for fresh installs via ISO |

## 6. Owner decisions (2026-11-08)

| # | Decision |
|---|---|
| D1 | Image name **`vitta-nvidia`** (`ghcr.io/dpietersz/vitta-nvidia`, os-release `VARIANT_ID=vitta-nvidia`, `ID=vitta` so dotfiles `isVitta` stays true). |
| D2 | **Fingerprint at the login screen too** (greetd greeter), not only the lock screen. Password must always work in parallel. |
| D3 | `equibop` and `fuse-libs` stay **local rpm-ostree layers** (carried by `rpm-ostree rebase`). |
| D4 | **Same boot splash badge** as the T580 (grungy Fedora logo + Lenovo wordmark). |
| D5 | **Keep `bluefin-udx` / `bluefin-udx-nvidia` as a fallback for a while** after the P14s is on `vitta-nvidia:stable`; Phase 6 is deferred until the owner asks. |

## 7. Estimate
Phases 0–4 ≈ 5–7 working days of agent time with CI, plus owner time for the
hardware checks; Phase 5 is a short switch plus a week of daily use.
