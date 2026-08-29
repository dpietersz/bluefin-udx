# Maintenance — quarterly review checklist

This image is a thin layer on top of `bluefin-dx`, but it accumulates third-party supply-chain dependencies (vendor RPM repos, COPRs, Terra, AppImage extracts) that each have their own lifecycle. Run this checklist **once per quarter** to catch stale sources before they break the nightly build.

Set a recurring calendar reminder. Quick pass should take ~15 minutes.

## Checklist

### 1. CI smoke-boot status
- [ ] Are the latest nightly builds for **both** `bluefin-udx` and `bluefin-udx-nvidia` green on GitHub Actions?
- [ ] If red for > 3 consecutive nights, investigate immediately (don't wait for the quarterly review).

### 2. COPR package freshness
Check the **specific package page**, never only the parent project. Active multi-package projects can hide an abandoned package—the old `noctalia-shell-v5` setup stayed green this way for months.

- [ ] `lionheartp/Hyprland :: hyprlock` — https://copr.fedorainfracloud.org/coprs/lionheartp/Hyprland/package/hyprlock/ — compare with https://github.com/hyprwm/hyprlock/releases/latest and confirm `hyprlock.repo` remains limited to hyprlock plus its ABI-matched Hypr libraries
- [ ] `lionheartp/Hyprland :: gpu-screen-recorder` — https://copr.fedorainfracloud.org/coprs/lionheartp/Hyprland/package/gpu-screen-recorder/ — compare the latest successful Fedora 44 x86_64 build with the version in https://git.dec05eba.com/gpu-screen-recorder/plain/meson.build, confirm it was built within 90 days, and confirm `gpu-screen-recorder.repo` still has exact `includepkgs=gpu-screen-recorder`. Inspect the RPM spec for changes to the privileged `gsr-kms-server` helper; `/usr/bin/gsr-kms-server` must retain only `cap_sys_admin=ep` after composition.
- [ ] `sneexy/zen-browser :: zen-browser` — https://copr.fedorainfracloud.org/coprs/sneexy/zen-browser/package/zen-browser/ — compare its latest successful version with https://github.com/zen-browser/desktop/releases/latest
- [ ] `barsnick/non-fed :: showmethekey` — https://copr.fedorainfracloud.org/coprs/barsnick/non-fed/package/showmethekey/ — compare with https://github.com/AlynxZhou/showmethekey/releases/latest and confirm `files/system/etc/yum.repos.d/showmethekey.repo` still limits the broad project to `showmethekey*`

If a package is behind upstream—not merely old because upstream itself is quiet—switch to the documented fallback. Never infer package freshness from a COPR project's newest unrelated build. `scripts/audit-copr-freshness.sh` enforces this comparison in nightly CI after a seven-day packaging grace period; keep its package map aligned with every baked COPR.

**Direct upstream release installs:**
- [ ] `nushell` — https://github.com/nushell/nushell/releases/latest — confirm the release still ships `nu-<version>-x86_64-unknown-linux-gnu.tar.gz` plus `SHA256SUMS`, GitHub's asset digest matches that manifest, and CI/local installs report the same version. Nushell currently publishes no independent artifact signature; re-check quarterly and adopt one if offered.
- [ ] `nwg-displays` — https://github.com/nwg-piotr/nwg-displays/tags — confirm latest tag still builds into `/usr/bin`, `/usr/lib/pythonX.Y/site-packages`, and `/usr/share`. Re-check whether `tofik/nwg-shell` has caught up to ≥0.4.0; prefer Fedora packaging once it is current.

**Noctalia Screen Toolkit runtime proof:**
- [ ] On both laptops, confirm `gpu-screen-recorder --info` reports H.264 support. The T580 must use Intel VAAPI; the P14s may use Intel VAAPI for an Intel-driven panel or NVENC for an NVIDIA-driven output.
- [ ] With Noctalia configured for H.264, 30 FPS, visible cursor, system audio, and microphone, record at least 10 seconds fullscreen while playing a clearly identifiable system sound and speaking a different phrase. Save the recording, play it, and confirm both sources are audible.
- [ ] Run `ffprobe -v error -show_entries stream=codec_type,codec_name,avg_frame_rate -of default=noprint_wrappers=1 <recording.mp4>` and confirm H.264 video at 30 FPS plus AAC audio. `default_output|default_input` is intentionally mixed into one audio track, so stream count alone cannot prove both sources; the listening test is required.
- [ ] Test one region recording through `wf-recorder`. Treat one default audio source as the supported behavior. Simultaneous system+microphone region audio remains unsupported by the plugin; do not mark this fixed based only on a successful file.

### 3. Vendor RPM repos
Verify every non-Fedora repository still resolves metadata and validates its GPG key:
- [ ] Microsoft Teams — https://repo.teamsforlinux.de/rpm/teams-for-linux.repo
- [ ] Beekeeper Studio — baked `files/system/etc/yum.repos.d/beekeeper-studio.repo`
- [ ] Terra — baked `files/system/etc/yum.repos.d/terra.repo`

A failure breaks the image build. Renovate does **not** understand COPR or vendor-repository freshness; this review owns it.

**Standalone vendor artifacts (no package repository):**
- [ ] Proton Authenticator — compare the first active stable x86_64 RPM in https://proton.me/download/authenticator/linux/version.json with `rpm -q proton-authenticator` on both laptops. Confirm URL remains under `https://proton.me/download/authenticator/linux/`, SHA-512 is still present, and package identity remains `proton-authenticator` / `x86_64`.
- [ ] Proton Mail — compare the first active `Stable` x86_64 RPM in https://proton.me/download/mail/linux/version.json with `rpm -q proton-mail` on both laptops. Never select `Alpha` or `EarlyAccess`; confirm URL remains a versioned `https://proton.me/download/mail/linux/<version>/ProtonMail-desktop-beta.rpm`, SHA-512 remains present, and `mailto:` handling remains in `proton-mail.desktop`.
- [ ] Re-check whether Proton now signs either RPM or offers a DNF repository. If so, replace the corresponding standalone unsigned-artifact flow with the signed repository. Until then, keep checksum and RPM identity validation in both Proton installer scripts.
- [ ] Launch Proton Authenticator on both laptops. Its desktop entry intentionally sets Proton's app-scoped `WEBKIT_DISABLE_DMABUF_RENDERER=1` workaround so WebKit renders reliably on the NVIDIA P14s; confirm the launcher patch survives package-layout changes and do not disable acceleration globally.
- [ ] Launch Proton Mail on both laptops and verify notifications, `mailto:` links, Calendar navigation, and GPU rendering. Keep the vendor launcher unchanged unless a reproducible GPU failure requires an app-scoped workaround.

The nightly workflow pre-resolves both Proton products' current stable URL and checksum into `build-pins.env`, so a new release changes the build context and refreshes both images automatically. A malformed or empty manifest must fail the build rather than silently retain an old package.

### 4. Upstream movement
- [ ] Has Zen Browser stabilized enough to ship an official RPM? If yes, drop `sneexy/`.
- [ ] Has Helium graduated out of Terra into its own vendor repo?
- [ ] Has Polypane started shipping an RPM? If yes, drop the AppImage-extract pattern.

### 5. CUDA workflow sanity (NVIDIA variant)
The bluefin-udx-nvidia image **does not bake `cuda-toolkit`** (Bluefin's atomic FS redirects `/usr/local` → `/var/usrlocal` which is stripped on image commit; CUDA RPMs install to /usr/local/cuda-XX.Y, so files are physically gone after commit).

The base bluefin-dx-nvidia-open image already provides everything to **run** CUDA workloads: driver, `libcuda.so`, `nvidia-container-toolkit`, `nvidia-smi`, `nvidia-ctk`. For development with `nvcc`/headers, use containers per project:

```bash
podman run --rm -it --device nvidia.com/gpu=all -v $PWD:/work -w /work \
    nvcr.io/nvidia/cuda:<version>-devel-fedora41 nvcc your_code.cu
```

Quarterly checks:
- [ ] `nvidia-smi` reports the GPU correctly on the P14s
- [ ] `podman run --device nvidia.com/gpu=all nvcr.io/nvidia/cuda:13.2.1-base-fedora41 nvidia-smi` succeeds
- [ ] CDI spec is present: `ls /etc/cdi/ /var/run/cdi/` (generated by `nvidia-ctk cdi generate` if missing)

### 6. Bake-pruning
- [ ] List packages baked but **not launched in the last 90 days** (rough proxy: when did you last open the app?).
- [ ] Candidates → consider moving to `common-toolbox` (distrobox) or removing entirely.

### 7. GitHub runner container tooling

The build host is not a stable dependency. `actions/runner-images` has broken this repo's nightly three times in three months, always by changing the container stack under us, and always with a staged rollout that makes the same commit pass and fail minutes apart. Treat it as a supply-chain source like any COPR.

- [ ] Skim the last quarter's Ubuntu 24.04 image release notes for **Podman / crun / conmon / buildah / skopeo / fuse-overlayfs** rows: https://github.com/actions/runner-images/releases
- [ ] Confirm the `Pin Podman to the distro build on kernel overlay` step in `build.yml` still holds. Its assertions are the canary:
  - `fuse-overlayfs` must not resolve on `PATH`
  - `/var/lib/containers/storage/overlay/.has-mount-program` must not read `true`
  - runtime `/usr/bin/crun`, conmon `/usr/bin/conmon`, driver `overlay`
- [ ] If GitHub drops the fuse-overlayfs binary (tracked in actions/runner-images#14597) the removals become no-ops and can eventually be retired — but only after a green build proves the graphroot is no longer pre-seeded.

**Do not assert `Native Overlay Diff: true` or read `GraphOptions` to detect this.** Both are blind to it: `GraphOptions` is empty when the mount program is auto-detected rather than configured, and `Native Overlay Diff` reads `false` on these runners even on a healthy kernel-overlay build. Measured on both the slow and fast paths in probe run 32368262988.

Background, if this ever regresses:
- containers/fuse-overlayfs#475 — silent rpmdb SQLite corruption on Fedora bootc builds
- actions/runner-images#14597 — the image change that introduced fuse-overlayfs 1.16
- Symptom pair to recognise: `database disk image is malformed` / `Error -1 running transaction`, **or** a uniform ~11 min per layer commit regardless of what the layer does. Both mean the same thing.

### 8. Bluefin-DX base image cadence
- [ ] Is `bluefin-dx:stable` still the right channel? If you've been on `:latest` mentally but `:stable` in recipe, reconcile.
- [ ] Major Fedora version bump coming? Add to the next review's agenda.

### 9. macOS reality check
- [ ] Did anything in `dotfiles/.chezmoiscripts/run_once_before_01b-install-homebrew-packages.sh.tmpl` need a corresponding Linux update that didn't land?
- [ ] Goal: macOS and Linux deliver the same developer experience modulo OS-specific apps.

## When something breaks mid-quarter

1. Open issue using the "Package broken upstream" template.
2. Rebase the affected machine to the previous known-good image tag (`bootc rollback` or `bootc switch ghcr.io/dpietersz/bluefin-udx:<previous-sha>`).
3. Fix in a branch, validate locally with `./scripts/local-build-test.sh`, push, confirm CI green, then `bootc upgrade` again.
