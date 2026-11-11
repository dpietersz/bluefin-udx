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
is not a Bluefin delta. The focused comparison found no NVIDIA/hybrid-named
file in `environment.d` or SELinux overlays which is absent from
`base-nvidia:44`:

```bash
podman run --rm --entrypoint /bin/bash ghcr.io/ublue-os/base-nvidia:44 -c 'for d in /usr/lib/environment.d /etc/environment.d /usr/lib/selinux /etc/selinux; do [ -d "$d" ] && find "$d" -type f \( -iname "*nvidia*" -o -iname "*vfio*" -o -iname "*gpu*" \) -print; done'
```

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
