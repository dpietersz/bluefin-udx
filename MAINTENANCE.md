# Maintenance — quarterly review checklist

This image is a thin layer on top of `bluefin-dx`, but it accumulates third-party supply-chain dependencies (vendor RPM repos, COPRs, Terra, AppImage extracts) that each have their own lifecycle. Run this checklist **once per quarter** to catch stale sources before they break the nightly build.

Set a recurring calendar reminder. Quick pass should take ~15 minutes.

## Checklist

### 1. CI smoke-boot status
- [ ] Are the latest nightly `(stable)` builds for **both** `bluefin-udx` and `bluefin-udx-nvidia` green on GitHub Actions?
- [ ] If red for > 3 consecutive nights, investigate immediately (don't wait for the quarterly review).
- [ ] Are the `(latest)` canary legs green? They build the same recipes on upstream `bluefin-dx:latest`, run the full smoke gate, and never push. Upstream `:latest` takes a new Fedora major (and other upstream changes) before `:stable`, so a red canary is your lead time to fix things before `:stable` moves. Run on schedule/dispatch only, not on PRs.
- [ ] Is the `Fedora N+1 package resolution` job green? It resolves every recipe package on upstream's next-release base (`silverblue-main:<N+1>`) via `scripts/check-fedora-next.sh`. A `SKIP` notice just means no N+1 base exists yet.

### 2. COPR package freshness
Check the **specific package page**, never only the parent project. Active multi-package projects can hide an abandoned package—the old `noctalia-shell-v5` setup stayed green this way for months.

- [ ] `lionheartp/Hyprland :: hyprlock` — https://copr.fedorainfracloud.org/coprs/lionheartp/Hyprland/package/hyprlock/ — compare with https://github.com/hyprwm/hyprlock/releases/latest and confirm `hyprlock.repo` remains limited to hyprlock plus its ABI-matched Hypr libraries
- [ ] `lionheartp/Hyprland :: gpu-screen-recorder` — https://copr.fedorainfracloud.org/coprs/lionheartp/Hyprland/package/gpu-screen-recorder/ — compare the latest successful build for the current base Fedora release (x86_64) with the version in https://git.dec05eba.com/gpu-screen-recorder/plain/meson.build, confirm it was built within 90 days, and confirm `gpu-screen-recorder.repo` still has exact `includepkgs=gpu-screen-recorder` and `terra.repo` retains `excludepkgs=gpu-screen-recorder` to prevent competing-source overrides. Inspect the RPM spec for changes to the privileged `gsr-kms-server` helper; `/usr/bin/gsr-kms-server` must retain only `cap_sys_admin=ep` after composition.
- [ ] `sneexy/zen-browser :: zen-browser` — https://copr.fedorainfracloud.org/coprs/sneexy/zen-browser/package/zen-browser/ — compare its latest successful version with https://github.com/zen-browser/desktop/releases/latest
- [ ] `barsnick/non-fed :: showmethekey` — https://copr.fedorainfracloud.org/coprs/barsnick/non-fed/package/showmethekey/ — compare with https://github.com/AlynxZhou/showmethekey/releases/latest and confirm `files/system/etc/yum.repos.d/showmethekey.repo` still limits the broad project to `showmethekey*`

If a package is behind upstream—not merely old because upstream itself is quiet—switch to the documented fallback. Never infer package freshness from a COPR project's newest unrelated build. `scripts/audit-copr-freshness.sh` enforces this comparison in nightly CI after a seven-day packaging grace period; keep its package map aligned with every baked COPR.

The `gpu-screen-recorder` audit selects the package's `fedora-<N>-x86_64` entry from COPR's monitor API, where `<N>` is read from `bluefin-dx:stable`'s version label (override with `FEDORA_MAJOR=<N>`, e.g. `FEDORA_MAJOR=45 scripts/audit-copr-freshness.sh` to audit the next release ahead of a flip), and verifies that build's chroot status and completion time. Do not use `builds.latest`: a newer Rawhide-only rebuild caused false failures on 2026-09-10/11 despite a current, successful Fedora 44 build. The seven-day version grace and 90-day build-age limit still apply. Run offline regression checks with `python3 -m unittest discover -s tests -p 'test_audit_copr_freshness.py'` (also run in CI).

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
- [ ] Terra — baked `files/system/etc/yum.repos.d/terra.repo`. Terra signs **each Fedora release with a different key** and `gpgkey=` uses `$releasever`, so `files/system/etc/pki/rpm-gpg/RPM-GPG-KEY-terra-<N>` must exist for the current **and next** release. Fetch from `https://repos.fyralabs.com/terra<N>/key.asc`, record fingerprint + SHA-256 in `terra.repo`, cross-check the fingerprint against an independent source. Without it, `skip_if_unavailable=True` silently drops Terra and the build dies on `No match` for zed/espanso-wayland/helium-browser-bin. `scripts/check-fedora-next.sh` fails on a missing N+1 key.

A failure breaks the image build. Renovate does **not** understand COPR or vendor-repository freshness; this review owns it.

**Standalone vendor artifacts (no package repository):**
- [ ] Proton Authenticator — compare the first active stable x86_64 RPM in https://proton.me/download/authenticator/linux/version.json with `rpm -q proton-authenticator` on both laptops. Confirm URL remains under `https://proton.me/download/authenticator/linux/`, SHA-512 is still present, and package identity remains `proton-authenticator` / `x86_64`.
- [ ] Proton Mail — compare the first active `Stable` x86_64 RPM in https://proton.me/download/mail/linux/version.json with `rpm -q proton-mail` on both laptops. Never select `Alpha` or `EarlyAccess`; confirm URL remains a versioned `https://proton.me/download/mail/linux/<version>/ProtonMail-desktop-beta.rpm`, SHA-512 remains present, and `mailto:` handling remains in `proton-mail.desktop`.
- [ ] Re-check whether Proton now signs either RPM or offers a DNF repository. If so, replace the corresponding standalone unsigned-artifact flow with the signed repository. Until then, keep checksum and RPM identity validation in both Proton installer scripts.
- [ ] Launch Proton Authenticator on both laptops. Its desktop entry intentionally sets Proton's app-scoped `WEBKIT_DISABLE_DMABUF_RENDERER=1` workaround so WebKit renders reliably on the NVIDIA P14s; confirm the launcher patch survives package-layout changes and do not disable acceleration globally.
- [ ] Launch Proton Mail on both laptops and verify notifications, `mailto:` links, Calendar navigation, and GPU rendering. Keep the vendor launcher unchanged unless a reproducible GPU failure requires an app-scoped workaround.
- [ ] Monaspace Neon (Vitta only) — confirm `https://github.com/githubnext/monaspace/releases/download/v1.400/monaspace-static-v1.400.zip` remains available and its SHA-256 is `ab66d71be751495f679727332a3345597943bd4d7beebca03f5cde04bf994de7`; when updating the pinned release, verify it still contains exactly 42 `Static Fonts/Monaspace Neon/*.otf` files before changing the installer and smoke gate together. The Plymouth preview harness (`scripts/bootsplash-preview/Containerfile`) pins the same URL and SHA-256 plus a REST API asset fallback; `tests/test_vitta_bootsplash.py` fails if the URL or SHA-256 drift.

The nightly workflow pre-resolves both Proton products' current stable URL and checksum into `build-pins.env`, so a new release changes the build context and refreshes both images automatically. A malformed or empty manifest must fail the build rather than silently retain an old package.

**RPM Fusion Free (package-scoped):**
- [ ] `telegram-desktop` — compare the Fedora package in the base and updates repositories with https://github.com/telegramdesktop/tdesktop/releases/latest. Confirm `files/system/etc/yum.repos.d/rpmfusion-free-telegram.repo` still limits both sections to `includepkgs=telegram-desktop*`, package vendor remains `RPM Fusion`, and baked key fingerprint remains `E9A4 91A3 DE24 7814 E7E0 67EA E06F 8ECD D651 FF2E`. A modest packaging delay is acceptable; investigate prolonged lag or a missing package for the current Fedora release.

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

### 8. Upstream Bluefin Classic health

Since September 2026 upstream's core team ships **Dakota** (BuildStream, Flatpak-first), **Utah** (Bluefin on Fedora Hummingbird, pre-alpha) and **Bluefin Server**. `ublue-os/bluefin` — what `bluefin-dx` is built from — was rebranded **Bluefin Classic** and handed to new maintainers ([handoff discussion #4951](https://github.com/ublue-os/bluefin/discussions/4951), [blog: Still Roaring](https://docs.projectbluefin.io/blog/still-roaring-bluefin-classic-and-lts/)). Layering, which this whole repo is, is officially unsupported on every variant. Our base is still alive, but it is no longer the flagship, so watch it like a third-party dependency.

Check monthly-ish, not only quarterly — subscribe to https://docs.projectbluefin.io/blog/rss.xml:

- [ ] **`:stable` freshness.** `skopeo inspect --no-tags docker://ghcr.io/ublue-os/bluefin-dx:stable | jq -r '.Created, .Labels["org.opencontainers.image.version"]'`. Upstream ships weekly (Tuesdays). Older than ~3 weeks without a blog/issue explanation = investigate.
- [ ] **Fedora major bump.** Track the Renovate `silverblue-main` major PR in `ublue-os/bluefin` (F45: [#5016](https://github.com/ublue-os/bluefin/pull/5016); its first builds failed on an akmods kernel-pin mismatch, 2026-10-24). When it merges, `:latest` flips first → our `(latest)` canary legs flip with it. Before `:stable` follows: canary green, `check-fedora-next.sh` green, next Terra key baked.
- [ ] **"Pull directly from Fedora" base swap.** Announced for Classic (drop the `ghcr.io/ublue-os/silverblue-main` layer, build on Fedora's own Silverblue). Not landed as of 2026-11-06 — watch `ARG BASE_IMAGE` in https://github.com/ublue-os/bluefin/blob/main/Containerfile and `image-versions.yml`. When it lands, re-verify the things we inherit from the Universal Blue layer and assume in our recipe:
  - `kmod-v4l2loopback` pre-built and signed with the ublue MOK (Phase 3d; Secure Boot loading)
  - the Negativo17 multimedia stack (why `rpmfusion-free-telegram.repo` is package-scoped; `h264_vaapi`/`h264_nvenc` ffmpeg encoders in the smoke gate)
  - `zfs` owning `/usr/bin/zed` (Terra `zed` packaging choice + smoke assertion)
  - NVIDIA open driver, `nvidia-container-toolkit`, `nvidia-smi` in `bluefin-dx-nvidia-open`
- [ ] **DX content drift.** Skim `ublue-os/bluefin` merged PRs touching `build_files/dx/` (e.g. `docker-model-plugin` replaced by brew `llmman`, [#4937](https://github.com/ublue-os/bluefin/pull/4937), 2026-10). Anything we rely on that leaves DX must be re-homed (recipe, dotfiles, or boxkit).
- [ ] **Maintainer pulse.** Non-Renovate commits to `ublue-os/bluefin` in the last 60 days, open-issue response, blog posts mentioning Classic. Silence is the earliest signal that a fallback base decision is due.
- [ ] Is `bluefin-dx:stable` still the right channel? If you've been on `:latest` mentally but `:stable` in recipe, reconcile.

Vitta `:stable` is an owner-promoted release. The Vitta/base-main checks below replace this Bluefin-Classic watch for the T580; retain the Bluefin checks while either bluefin-udx image still uses that upstream base.

**Vitta promotion (only after owner review of a known-good testing, date, or SHA tag):**
- [ ] Confirm the candidate digest is one that passed the T580 acceptance checklist and remains available in ghcr.
- [ ] Run `gh workflow run promote-vitta.yml -f source=testing -f confirm=promote` (replace `testing` with the reviewed date tag, seven-character SHA tag, or full `sha256:` digest when pinning a specific candidate).
- [ ] Confirm the workflow reports `source digest == stable digest`, including successful source and stable cosign verification.
- [ ] Never promote from `build.yml`: CI continues to publish only `:testing`, date, and commit-SHA Vitta tags. Do not dispatch promotion merely to test it.

**Vitta / `base-main` health (quarterly after promotion; useful while testing):**
- [ ] Check `ghcr.io/ublue-os/base-main:44` freshness and its Fedora-major cadence with `skopeo inspect --no-tags docker://ghcr.io/ublue-os/base-main:44`; keep Vitta pinned to an intentional major and run the Vitta leg of `scripts/check-fedora-next.sh` before changing it.
- [ ] Check `ghcr.io/ublue-os/base-nvidia:44` freshness and record the NVIDIA driver branch it ships before rebuilding or promoting `vitta-nvidia`; investigate an unexpected driver-branch change with the Vitta-NVIDIA smoke gate before the owner switches the P14s.
- [ ] On Vitta, record `rpm -q greetd cage quickshell` and run the image smoke gate or `vitta-greeter-preview --selftest`; investigate Fedora updates that change the login-stack versions or break the headless greeter check.
- [ ] Verify the baked VS Code signing key still hashes to `2fa9c05d591a1582a9aba276272478c262e95ad00acf60eaee1644d93941e3c6` (`sha256sum /etc/pki/rpm-gpg/microsoft.asc`) and that `files/vitta/etc/yum.repos.d/vscode.repo` still resolves `code` with GPG checking enabled.
- [ ] Verify the Docker CE and Tailscale Fedora repositories still return signed metadata and resolve their Vitta package sets; do not replace their package-managed keys or repositories with unpinned downloads.

### 9. macOS reality check
- [ ] Did anything in `dotfiles/.chezmoiscripts/run_once_before_01b-install-homebrew-packages.sh.tmpl` need a corresponding Linux update that didn't land?
- [ ] Goal: macOS and Linux deliver the same developer experience modulo OS-specific apps.

## When something breaks mid-quarter

1. Open issue using the "Package broken upstream" template.
2. Rebase the affected machine to the previous known-good image tag (`bootc rollback` or `bootc switch ghcr.io/dpietersz/bluefin-udx:<previous-sha>`).
3. Fix in a branch, validate locally with `./scripts/local-build-test.sh`, push, confirm CI green, then `bootc upgrade` again.
