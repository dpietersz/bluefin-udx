# Vitta NVIDIA (P14s) Implementation Plan — Phases 0–4

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed `ghcr.io/dpietersz/vitta-nvidia:testing` image, plus the dotfiles changes it needs, that is ready for the owner-triggered switch of the ThinkPad P14s Gen 5 (Phase 5): same splash / LUKS prompt / greeter as the T580, password login at the greeter with fingerprint at the lock screen and sudo, NVIDIA and workstation parity gated in CI.

**Architecture:** `recipes/vitta-nvidia.yml` = `vitta.yml`'s module list on `ghcr.io/ublue-os/base-main:44`, plus the BlueBuild `akmods` module with `nvidia-driver: nvidia-open` and `nvtop` (rulings R42/R43 below; the plan first named the since-retired `base-nvidia:44`). Everything else stays shared in `files/vitta/` + `recipes/vitta-modules.yml`: the greeter pins cage to the GPU that drives the panel, and greetd gets its own password-only PAM auth stack so a machine's authselect fingerprint setting cannot hold up a typed password. CI has a fourth leg and the smoke gates use `IS_VITTA` / `IS_NVIDIA` flags.

**Tech Stack:** BlueBuild (files, rpm-ostree, akmods, os-release, initramfs modules), dracut, Plymouth script plugin, greetd 0.10 + cage 0.3 (wlroots 0.20) + Quickshell QML, Linux-PAM (`pam_unix`, `pam_fprintd`), Python 3.14 stdlib (`unittest`, `tomllib`, `ctypes`), chezmoi templates + `bun test`, GitHub Actions + podman + cosign.

**Spec:** `docs/superpowers/plans/2026-11-08-vitta-nvidia-plan.md` (approved plan, owner decisions D1–D5 in §6). Ledger and rulings: `.superpowers/sdd/2026-11-06-vitta/progress.md`.

## Measured facts this plan argues from (2026-11-11)

- `base-nvidia:44` (digest `sha256:35fc93e3…`, kernel 7.2.15, NVIDIA 620.70.06, signer `ublue kernel`) ships `/usr/lib/dracut/dracut.conf.d/99-nvidia.conf` = `force_drivers+=" i915 amdgpu nvidia nvidia_drm nvidia_modeset nvidia_peermem nvidia_uvm "`, and its **`/usr/lib/bootc/kargs.d/` is empty**. Bluefin adds `00-nvidia.toml` with the four args itself.
- Today's P14s initramfs has exactly that driver set (`rd.driver.pre=i915 … nvidia …`): `i915` framebuffer at 5.5 s, Plymouth at 10.7 s. The iGPU binds to `i915` (not `xe`). `card0` = Intel (`boot_vga=1`, all connectors incl. `eDP-1` and the dock's `DP-1..4`), `card1` = NVIDIA (no connectors, runtime-suspended).
- Panel 2560×1600 on 310×200 mm ≈ 210 DPI: Plymouth computes device scale 2 above 192 DPI.
- **Vitta has no `fprintd` / `fprintd-pam`** (the approved plan assumed it had). Its stock `system-auth` has no `pam_fprintd`; the P14s's own `/etc` (authselect `with-fingerprint`, `pam_fprintd.so sufficient` first) survives the rebase.
- `gnome-keyring-daemon.socket` is disabled on both images; the P14s keyring daemon is D-Bus activated (`--components=secrets`).
- `supergfxd` inactive; the VM has a USB hostdev only (no PCI passthrough); `nvidia-persistenced`, `switcheroo-control`, `bolt` active.
- dotfiles `image-identity.tmpl` matches `ghcr\.io/dpietersz/vitta(:|@|$)`, so `vitta-nvidia` is not recognised as a booted ref and `expectedImageFamily` would be `vitta`.

## Global Constraints

> **R42/R43 (2026-11-11):** `vitta-nvidia` uses `ghcr.io/ublue-os/base-main:44` with BlueBuild `akmods` `nvidia-driver: nvidia-open`; it has no own kargs file because that module writes the four arguments. These rulings supersede the `base-nvidia` and `files/vitta-nvidia/` kargs lines below.

- Image name `vitta-nvidia`; base `ghcr.io/ublue-os/base-nvidia`, `image-version: 44`; os-release `ID=vitta`, `ID_LIKE=fedora`, `NAME="Vitta"`, `PRETTY_NAME="Vitta 44 (NVIDIA)"`, `VARIANT_ID=vitta-nvidia`, `IMAGE_ID=vitta-nvidia` (D1).
- Kernel args, exactly and in this order: `rd.driver.blacklist=nouveau`, `modprobe.blacklist=nouveau`, `nvidia-drm.modeset=1`, `initcall_blacklist=simpledrm_platform_driver_init`.
- `bluefin-udx`, `bluefin-udx-nvidia` and their CI behaviour stay unchanged (D5). `files/system/` gets nothing new. Shared Vitta files: `files/vitta/` + `recipes/vitta-modules.yml`. NVIDIA-only files: `files/vitta-nvidia/`, applied only by `recipes/vitta-nvidia.yml`.
- CI publishes `vitta-nvidia` only as `:testing`, `:<YYYYMMDD>`, `:<sha7>`; cosign is installed and the signing key required **before** the push; `:stable` moves only through `promote-vitta.yml`.
- No `cuda-toolkit`, no Flatpak/AppImage, none of the packages the Vitta gate already forbids. `equibop` and `fuse-libs` stay local layers (D3). Same splash badge as the T580 (D4).
- **Owner decision 2026-11-12 (supersedes D2): the greeter takes the password only.** Fingerprint is for the lock screen (hyprlock) and sudo/polkit, as on the T580 model. Research behind it: nobody has password and finger in parallel under greetd; the ledger has the sources. The greeter is not changed. The greeter must never hang.
- **Nothing in this plan activates the image on this P14s.** No `rpm-ostree rebase`, `bootc switch`, `rpm-ostree kargs` edits, `authselect` changes, edits under `/etc`, or `chezmoi apply` on this machine; no `sudo`. Publishing `vitta-nvidia:testing` does not touch it: the P14s keeps following `bluefin-udx-nvidia:stable`. The switch is Phase 5, on the owner's word only.
- Smoke-gate shell inside `podman run … -c '…'` uses only double quotes; the smoke `run:` block contains no `${{ }}`; any `run:` block with an expression stays under 21000 chars; no `grep -x` against lines that end in `\`.
- No full local image builds. Verification of image content is CI on the PR (non-main runs never publish). A CI failure on an upstream network error (curl 5xx/56, Terra outage, kernel skew between `base-nvidia` and `akmods`) gets one re-run of the failed jobs before any debugging.
- Dotfiles work only in the worktree `~/dotfiles-vitta-nvidia` (branch `vitta-nvidia`). Never `chezmoi apply`. Rendered output for this P14s on `bluefin-udx-nvidia` must not change.
- Every subagent dispatch carries a time budget of 60 minutes and reports what is unfinished when it runs out.

## Execution notes

- Image work happens in the worktree `~/dev/Projects/bluefin-udx-vitta-nvidia`. Branch `vitta-nvidia` (Tasks 1–5, PR 1), then `vitta-nvidia-phase3` in the worktree `~/dev/Projects/bluefin-udx-vitta-nvidia-login` (Tasks 6, 9, PR 2; Task 7 was dropped). The main working tree is never switched.
- Implementers commit and run the local tests; the controller pushes, watches CI and dispatches fixes. Python tests: `python3 -m unittest tests/test_vitta_nvidia.py tests/test_vitta_overlay.py tests/test_vitta_bootsplash.py -v`.
- New smoke-gate lines are added to **both** `.github/workflows/build.yml` and `scripts/local-build-test.sh`. Check a new snippet's shell locally against `ghcr.io/dpietersz/vitta:stable` or `ghcr.io/ublue-os/base-nvidia:44` (both in the local store); the real verdict is the CI leg.
- **Hardware truth comes at the Phase 5 trial boot.** Nothing in Phases 0–4 runs on the P14s's GPU, panel or sensor. Each hardware risk below gets a CI gate where one is possible and a line in the acceptance runbook (Task 9) where it is not.
- **Stop points:** (S1) merge PR 1 = first publish of `vitta-nvidia:testing`; (S2) merge PR 2 and the dotfiles branch; (S3, optional, owner at the T580) password login on `vitta:testing` before `vitta:stable` is ever promoted past the new greetd PAM stack. Phase 5 is not in this plan.

## Review Focus

1. **Docked with the lid closed, or DRM card numbers swapped** (`card0` = NVIDIA): the greeter must still open on the GPU that has the connected display, and a single-GPU machine must get no pin at all → Task 5 fake-sysfs tests.
2. **Machine with enrolled fingerprints and authselect `with-fingerprint` in its `/etc` (P14s):** a typed password at the greeter must be checked at once, with no fingerprint prompt and no wait → Task 6 PAM stack test (no `system-auth`, no `pam_fprintd` on any greetd `auth` line) and probe.
3. **Empty password at the greeter:** a plain failure in about 2 s, fields usable again → Task 6 probe; the greeter's existing `badpass` selftest.
4. **Machine without fingerprints (T580):** zero behaviour change for a password login → Task 6 PAM probe on both Vitta legs; greeter files untouched.
5. **`/etc` carried over from Bluefin** (authselect `system-auth` with `pam_fprintd` first, no `/etc/pam.d/greetd`, kernel args already on the command line): greetd's auth must not depend on `system-auth`; the four args must appear once → Task 6 PAM stack test, Task 9 runbook pre-reboot check.

---

### Task 1: NVIDIA gap analysis (Phase 0)

**Files:**
- Create: `docs/research/2026-11-11-vitta-nvidia-gap-analysis.md`
- Modify: `scripts/vitta-gap-report.sh` (header comment only, if the `BASE_IMAGE` override needs documenting)

**Interfaces:**
- Produces: a table `| item | kind (rpm/file/unit/karg) | in bluefin-dx-nvidia-open | in base-nvidia:44 | used on P14s (evidence) | ADD / DROP / HAVE | where |`. Tasks 2, 6 and 9 apply its ADD rows.

- [ ] **Step 1:** Run `BLUEFIN_IMAGE=ghcr.io/ublue-os/bluefin-dx-nvidia-open:stable BASE_IMAGE=ghcr.io/ublue-os/base-nvidia:44 OUTPUT_DIR=/tmp/vitta-nvidia-gap scripts/vitta-gap-report.sh` (both images are in the local store; record their digests in the doc).
- [ ] **Step 2:** From the Bluefin-only list keep what is NVIDIA-, hybrid-GPU-, fingerprint-, Thunderbolt- or VM-related, or not already triaged in `docs/research/2026-11-06-vitta-gap-analysis.md`. Triage rule: **ADD** only if (a) a unit or process of it is active on this P14s (`systemctl is-active`, `ps`, `journalctl -b`), or (b) `~/dotfiles` references it (`git -C ~/dotfiles grep`), or (c) it is an NVIDIA/hybrid integration file (udev, modprobe.d, environment.d, kargs.d, dracut.conf.d) that Bluefin adds on top of `base-nvidia`. Otherwise **DROP** with the evidence. Anything undecidable goes in a section "ASK" for the controller.
- [ ] **Step 3:** The table must contain these rows, each re-verified: kargs.d four args → ADD (`files/vitta-nvidia`); `fprintd`, `fprintd-pam` → ADD (shared `vitta-modules.yml`, Task 6); `nvtop` → ADD (`vitta-nvidia.yml`); `bolt`, `ydotool`, `zenity`, `switcheroo-control` → HAVE; `supergfxctl` → DROP (inactive); `80-vfio.conf` → DROP (`virsh -c qemu:///system dumpxml windows-work` has no PCI hostdev); `99-nvidia.conf` force_drivers → HAVE (from `nvidia-kmod-common`); `nvidia-persistenced`, `nvidia-cdi-refresh.path` enablement → compare unit states.
- [ ] **Step 4:** Read-only dotfiles audit, in the same doc: every template condition on `hasNvidia`, `hasFingerprintReader` or a P14s `hardwareModel`, with its outcome on `isVitta`. Input for Task 8.
- [ ] **Step 5:** Commit `docs(research): vitta-nvidia gap analysis`.

### Task 2: Recipe and NVIDIA-only overlay (Phase 1)

**Files:**
- Create: `recipes/vitta-nvidia.yml`, `files/vitta-nvidia/usr/lib/bootc/kargs.d/10-vitta-nvidia.toml`, `tests/test_vitta_nvidia.py`
- Modify: `RECIPE.md` (rows: base-nvidia, `nvtop` for vitta-nvidia, kargs file; plus Task 1 ADD rows)

**Interfaces:**
- Consumes: Task 1 ADD rows marked `vitta-nvidia.yml` / `files/vitta-nvidia`.
- Produces: recipe name `vitta-nvidia`; overlay source `vitta-nvidia`; module order `files(system)` → `common.yml` → `vitta-modules.yml` → `files(vitta-nvidia)` → `rpm-ostree [nvtop + Task 1 NVIDIA-only ADDs]` → `os-release` → `initramfs` (last).

- [ ] **Step 1: Failing tests** in `tests/test_vitta_nvidia.py`, class `VittaNvidiaRecipeTests` (read files as text, like `tests/test_vitta_overlay.py`):
  - `test_identity`: `name: vitta-nvidia`, `base-image: ghcr.io/ublue-os/base-nvidia`, `image-version: 44`, and the six os-release values from Global Constraints.
  - `test_module_order`: the seven markers above appear in that order and `- type: initramfs` is the last module.
  - `test_kargs_exact`: `tomllib` load of the toml equals `{"kargs": [<the four args in order>]}`.
  - `test_overlay_is_nvidia_only`: the string `source: vitta-nvidia` occurs in `recipes/vitta-nvidia.yml` and in no other recipe; `recipes/vitta.yml` and `recipes/vitta-modules.yml` do not contain `vitta-nvidia` or `base-nvidia`.
  - `test_no_cuda_toolkit`: `cuda-toolkit` is not an install entry.
- [ ] **Step 2:** Run `python3 -m unittest tests/test_vitta_nvidia.py -v` → FAIL (files missing).
- [ ] **Step 3:** Write the recipe (header comment: why base-nvidia, that the four args also keep `bootc switch` from a Bluefin deployment from *removing* them, CUDA rationale pointer to `bluefin-udx-nvidia.yml`) and the toml.
- [ ] **Step 4:** Tests PASS. `bluebuild generate recipes/vitta-nvidia.yml -o /tmp/Containerfile.vitta-nvidia` succeeds (CLI bootstrap in CLAUDE.md).
- [ ] **Step 5:** Commit `feat(vitta-nvidia): recipe on base-nvidia with kargs overlay`.

### Task 3: CI leg, smoke gates, promotion (Phase 1)

**Files:**
- Modify: `.github/workflows/build.yml`, `scripts/local-build-test.sh`, `.github/workflows/promote-vitta.yml`, `tests/test_vitta_nvidia.py`, `tests/test_vitta_overlay.py` (only if an existing promotion assertion needs the new input), `README.md`, `CLAUDE.md`, `MAINTENANCE.md`

**Interfaces:**
- Consumes: recipe `vitta-nvidia` (Task 2).
- Produces, in both smoke gates right after the rpmdb check: `IS_VITTA` (1 for `vitta|vitta-nvidia`) and `IS_NVIDIA` (1 for `bluefin-udx-nvidia|vitta-nvidia`); later tasks add checks under `[ "$IS_VITTA" = 1 ]`, `[ "$IS_NVIDIA" = 1 ]` or both. Promotion: `gh workflow run promote-vitta.yml -f image=vitta-nvidia -f source=<tag|digest> -f confirm=promote`; `image` is a `choice` (`vitta`, `vitta-nvidia`), default `vitta`.

- [ ] **Step 1: Failing tests**, class `VittaNvidiaCiTests`:
  - `test_matrix_has_testing_leg`: `include:` contains `recipe: vitta-nvidia` with `stream: testing`.
  - `test_publish_allow_list`: the push `case` contains `vitta-nvidia:testing` and the workflow contains no `vitta-nvidia:stable`.
  - `test_gates_use_flags`: both gate files define `IS_VITTA` and `IS_NVIDIA` with the patterns above and contain no `"$RECIPE_NAME" = "vitta"` and no `"$RECIPE_NAME" = "bluefin-udx-nvidia"`.
  - `test_smoke_block_rules`: in `build.yml`, the text of the `Smoke-boot test` step has no `${{` after its `run: |`, and the body between `-c '` and the closing `'` has no single quote.
  - `test_fedora_next_covers_recipe`: the Vitta `RECIPES:` line includes `recipes/vitta-nvidia.yml` (resolved against `base-main`: the package delta is `nvtop`).
  - `test_promotion_takes_image`: input `image` with the two options and default; the registry path is built from the input; the fixed string `ghcr.io/${{ github.repository_owner }}/vitta` no longer appears without it.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement. Gate changes: os-release expectation becomes `VARIANT_ID=$RECIPE_NAME IMAGE_ID=$RECIPE_NAME`; every former Vitta branch runs for `IS_VITTA`; the former NVIDIA branch (`nvtop`, `nvidia-smi`, `nvidia-ctk`) runs for `IS_NVIDIA`. New under `IS_VITTA` + `IS_NVIDIA`: `check_rpm kmod-nvidia nvidia-driver nvidia-container-toolkit`; exactly one directory in `/usr/lib/modules`; `modinfo -k "$KVER" -F signer nvidia` is non-empty (print it); `check_file /usr/lib/bootc/kargs.d/10-vitta-nvidia.toml` and each of the four args is in it; `/usr/lib/modprobe.d/nvidia.conf` has `blacklist nouveau`; `systemctl is-enabled nvidia-cdi-refresh.path` prints `enabled`. Leave the `test_vitta_groups.sh` step on the `vitta` leg only.
- [ ] **Step 4:** Tests PASS; `bash -n scripts/local-build-test.sh`; extract the gate body and `bash -n` it.
- [ ] **Step 5:** Docs: README Vitta section (vitta-nvidia rebase and promote commands, P14s target), CLAUDE.md (four images, `files/vitta-nvidia/`, promote `image` input, `IS_VITTA`/`IS_NVIDIA`), MAINTENANCE.md (quarterly: `base-nvidia:44` freshness and NVIDIA driver branch).
- [ ] **Step 6:** Commit `feat(ci): vitta-nvidia leg, flag-based smoke gates, promotion by image`.

### Task 4: Boot splash and LUKS prompt without simpledrm (Phase 2) — passphrase-focused review

**Files:**
- Modify: `files/scripts/vitta-plymouth-theme.sh`, `tests/test_vitta_bootsplash.py`, `scripts/bootsplash-preview/render.sh`, both smoke gates

**Interfaces:**
- Produces: `DeviceScale=1` in `/usr/share/plymouth/plymouthd.defaults` (`[Daemon]`), in the image and in the initramfs, for both Vitta images.

Decisions: the initramfs driver set stays what `base-nvidia` configures (`99-nvidia.conf`), which is byte-for-byte what boots this P14s today; the plan's "NVIDIA modules not forced early" is dropped in favour of the proven set. The image does not add its own `force_drivers`; the gate fails if upstream ever drops `i915`. Plymouth's script plugin draws in logical pixels, so at device scale 2 the theme would lay out 1280×800 and upscale; `DeviceScale=1` keeps the 1600-px assets crisp. The T580 (141 DPI) already computes scale 1, so nothing changes there.

- [ ] **Step 1:** Confirm in the Plymouth 24.004.60 source (`src/main.c` `DeviceScale`, `src/libply-splash-core/ply-pixel-buffer.c` logical vs device size, `ply_get_device_scale`) that (a) the key is read from `plymouthd.defaults` and (b) the script plugin sees logical sizes. If (b) is false, skip the `DeviceScale` change, keep the tests for sizes, and record the finding in the ledger.
- [ ] **Step 2: Failing tests** in `tests/test_vitta_bootsplash.py`: add `(2560, 1600)` to `SIZES`; `test_theme_script_pins_device_scale`: `vitta-plymouth-theme.sh` sets exactly one `DeviceScale=1` line under `[Daemon]`, is idempotent on a second run against a temp copy of a stock defaults file, and fails if the key ends up outside `[Daemon]`.
- [ ] **Step 3:** Implement in `vitta-plymouth-theme.sh`; add `2560x1600` to `render.sh`'s default `EXTRA_SIZES`.
- [ ] **Step 4:** `MAIN_SIZE=2560x1600 ./scripts/vitta-bootsplash-preview.sh /tmp/splash-p14s` and once more with `FONTLESS=1`. The controller views the splash, prompt and wrong-passphrase frames.
- [ ] **Step 5:** Gates. `IS_VITTA`: `grep -q "^DeviceScale=1$"` in the image defaults and via `lsinitrd -f usr/share/plymouth/plymouthd.defaults`; the initramfs listing contains `/i915.ko`. `IS_VITTA` + `IS_NVIDIA`: `lsinitrd -f etc/cmdline.d/20-force_drivers.conf` has the line `rd.driver.pre=i915`; the listing contains `usr/lib/modprobe.d/nvidia.conf`.
- [ ] **Step 6:** Tests PASS. Commit `feat(vitta-splash): crisp splash on HiDPI panels, KMS-in-initramfs gate`.

### Task 5: Greeter on the GPU that drives the panel (Phase 2) — login-focused review

**Files:**
- Create: `files/vitta/usr/libexec/vitta/vitta-greeter-gpu`, `tests/test_vitta_greeter_gpu.py`
- Modify: `files/vitta/usr/libexec/vitta/vitta-greeter`, both smoke gates

**Interfaces:**
- Produces: `vitta-greeter-gpu` prints one DRM node (`/dev/dri/cardN`) or nothing, always exit 0; reads `${VITTA_SYSFS_ROOT:-/sys}/class/drm`. `vitta-greeter` exports `WLR_DRM_DEVICES` only when the output is non-empty and keeps its `exec cage -d -s -m last -- quickshell …` line unchanged (the gate and `vitta-greeter-preview` parse it).

Selection rule: fewer than two `card[0-9]+` entries → nothing. Else the card owning a connector `cardN-eDP-*` with `status` = `connected`; else the card with `device/boot_vga` = `1`; else nothing (wlroots' own default).

- [ ] **Step 1: Failing tests** (fake sysfs trees in a temp dir): `test_single_gpu_prints_nothing`; `test_p14s_topology` (card0 Intel eDP connected + boot_vga, card1 NVIDIA no connectors → `/dev/dri/card0`); `test_swapped_numbering` (card1 has the eDP → `/dev/dri/card1`); `test_lid_closed_docked` (eDP `disconnected`, boot_vga on card0 → `/dev/dri/card0`); `test_no_hint_prints_nothing`; `test_missing_sysfs_exits_zero`; `test_launcher_exports_only_when_set` (text check on `vitta-greeter`, and the `exec cage -d -s -m last -- quickshell ` line is still there).
- [ ] **Step 2:** Run `python3 -m unittest tests/test_vitta_greeter_gpu.py -v` → FAIL.
- [ ] **Step 3:** Implement helper (bash, `set -u`, no `set -e` exits before the final `exit 0`) and the launcher change.
- [ ] **Step 4:** Tests PASS; `VITTA_ROOT=$PWD/files/vitta files/vitta/usr/bin/vitta-greeter-preview --selftest` still passes; one preview screenshot at 2560×1600 for the controller (sizes follow screen height; no cage scale is set).
- [ ] **Step 5:** Gate (`IS_VITTA`): helper executable; launcher contains `WLR_DRM_DEVICES`; in the container (single or no DRM card) the helper prints nothing and exits 0.
- [ ] **Step 6:** Commit `feat(vitta-greeter): pin cage to the GPU that drives the panel`.

**After Task 5:** controller opens PR 1, watches the four legs, runs a whole-branch review, then **stops (S1)**. After the merge: `skopeo inspect docker://ghcr.io/dpietersz/vitta-nvidia:testing` without credentials and `cosign verify --key cosign.pub …`; a 401 means the new GHCR package is private and the owner makes it public.

### Task 6: Password-only greetd auth stack, fprintd for lock screen and sudo (Phase 3) — login-focused review

**Files:**
- Create: `tests/smoke/pam_probe.py`, `tests/test_vitta_pam_probe.py`
- Modify: `recipes/vitta-modules.yml` (`fprintd`, `fprintd-pam`), `files/vitta/etc/pam.d/greetd`, `tests/test_vitta_overlay.py`, `tests/test_vitta_nvidia.py`, both smoke gates (mount `tests/smoke` read-only at `/smoke`; local script adds `,z`), `RECIPE.md`
- Not touched: everything under `files/vitta/usr/share/vitta/greeter/` and `files/vitta/usr/bin/vitta-greeter-preview`.

**Interfaces:**
- Produces: PAM service `greetd` whose auth section is exactly, in this order:
  ```
  auth  required                    pam_env.so
  auth  required                    pam_faildelay.so delay=2000000
  auth  [success=1 default=ignore]  pam_unix.so nullok
  auth  requisite                   pam_deny.so
  auth  required                    pam_permit.so
  -auth optional                    pam_gnome_keyring.so
  -auth optional  pam_kwallet5.so
  -auth optional  pam_kwallet.so
  auth  include   postlogin
  ```
  Account, password and session sections stay as they are. No `system-auth` and no `pam_fprintd` on any `auth` line: on the P14s authselect's `with-fingerprint` puts `pam_fprintd` first in `system-auth`, and under greetd's single PAM conversation that would hold a typed password for the whole fingerprint timeout. Ruling R48: the stock-shaped jump form (`pam_unix` success skips `pam_deny` and lands on `pam_permit`) keeps every failure at the same result code as Fedora's stock stack (an unknown user must not look different from a wrong password), and success does not depend on the optional keyring modules.
- Produces: `fprintd` and `fprintd-pam` in the image, for hyprlock's fingerprint unlock and for sudo/polkit through the machine's own authselect profile. Inert without a reader.
- Produces: `python3 /smoke/pam_probe.py SERVICE USER PASSWORD --expect success|fail --max-seconds N [--expect-message TEXT] [--forbid-message TEXT]` (ctypes on `libpam.so.0`, answers every prompt with PASSWORD, prints each PAM message, never the password; hard stop at N plus a small grace; a conversation callback error is a failure; exit 0 only when result, duration and message conditions all hold).

The probe, its unit tests and the gate block exist on the archived local branch `vitta-nvidia-login` (commit 8e4ced0, reviewed there); take them from that branch and cut them down to this task: no marker, no `pam_exec` helper, no `pam_echo`.

- [ ] **Step 1: Failing tests** in `tests/test_vitta_overlay.py`: `test_greetd_auth_is_password_only` (the nine auth lines in order; no `system-auth`, `pam_fprintd`, `pam_exec` or `pam_echo` on any `auth` line; the `pam_unix` jump lands on `required pam_permit.so` right after `requisite pam_deny.so`); `test_greetd_other_sections_unchanged` (the account, password and session lines equal a list written out in the test, copied from today's file); In `tests/test_vitta_nvidia.py`: `test_fprintd_is_shared` (`fprintd`, `fprintd-pam` in `vitta-modules.yml`, not in `vitta-nvidia.yml`); `test_gates_probe_greetd_auth` (both gates mount `/smoke` without a GitHub expression and run the four probes below).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement PAM file (comment block: why self-contained, the owner decision, that fingerprint lives at the lock screen and sudo), packages, probe + its unit tests.
- [ ] **Step 4:** Gate (`IS_VITTA`), each probe under `timeout -k 5 25`: `check_rpm fprintd fprintd-pam`; create `vittaprobe` with a known password; correct → `success` within 5 s; wrong → `fail` within 10 s; empty → `fail` within 10 s; a copy of the service with every keyring/kwallet auth line removed, correct password → `success`. Prove the same four in a throwaway `ghcr.io/dpietersz/vitta:stable` container first, plus one more there: with `pam_permit.so` copied in as `pam_fprintd.so`, a wrong password still fails (nothing in the stack can reach a fingerprint module).
- [ ] **Step 5:** `RECIPE.md` rows for `fprintd`, `fprintd-pam` (bake reason `system-integration`). Commit `feat(vitta): password-only greetd auth stack, fprintd for lock screen and sudo`.

### Task 7: (dropped)

Fingerprint at the login screen was built and reviewed on the local branch `vitta-nvidia-login` (password first, Enter on an empty field for the finger) and then dropped by owner decision on 2026-11-12 in favour of password-only login. The greeter is unchanged from `main`.

### Task 8: Dotfiles for vitta-nvidia (Phase 3) — worktree `~/dotfiles-vitta-nvidia`

**Files (dotfiles repo):**
- Modify: `.chezmoitemplates/image-identity.tmpl`, `tests/image-identity.test.ts`, `.chezmoiscripts/run_onchange_before_00a-verify-image.sh.tmpl`, `AGENTS.md` (flag table)
- Create: `.chezmoiscripts/run_onchange_after_16a-keyring-passwordless-greetd.sh.tmpl`, `tests/keyring-greetd.test.ts`

**Interfaces:**
- Produces: `expectedImageFamily` = `vitta-nvidia` when os-release has `VARIANT_ID=vitta-nvidia` (quotes optional) or the booted ref matches `ghcr\.io/dpietersz/vitta-nvidia(:|@|$)`; that ref also sets `isMyImage`. Every other fixture result is unchanged, in particular this P14s on `bluefin-udx-nvidia`.
- Produces: greetd keyring guard, rendered to a no-op unless `isVitta` and `hasFingerprintReader` (and not remote/macOS/server). It rebuilds `/etc/pam.d/greetd` from the image's pristine `/usr/etc/pam.d/greetd` with the active `pam_gnome_keyring.so` lines commented (`# [keyring-pam disabled] …`), keeps a `.bak`, restores it if `pam_unix.so` is no longer active in the auth section, and re-fires through a rendered sha256 of `/usr/etc/pam.d/greetd`, so a later image change to the PAM file reaches the P14s instead of being shadowed by the local edit.

- [ ] **Step 1:** `git -C ~/dotfiles worktree add ~/dotfiles-vitta-nvidia -b vitta-nvidia main`; baseline `bun test tests/image-identity.test.ts tests/hyprlock-vitta.test.ts` and `python3 -m unittest discover -s tests -p 'test_windows_work*.py' -v`; note pre-existing failures.
- [ ] **Step 2: Failing tests:** identity fixtures (Vitta NVIDIA os-release with unknown ref; `vitta-nvidia:testing` ref via rpm-ostree and via bootc; plain `vitta` unchanged; `bluefin-udx-nvidia` + `hasNvidia` unchanged). `tests/keyring-greetd.test.ts` runs the rendered script body against a temp root (`PAM_SRC`, `PAM_DST` overridable, `sudo` stubbed): three keyring lines commented, other lines byte-identical to the source, second run is a no-op, the sanity failure restores the backup, and the gate renders `exit 0` for Bluefin with a reader and for Vitta without one.
- [ ] **Step 3:** Implement; apply Task 1 Step 4 findings that would regress on Vitta (each as its own test + change). Check that `run_once_after_10-enable-fingerprint-pam` cannot layer packages when `isMyImage`, and that the hyprlock `fingerprint {}` block renders with `isVitta` + `hasFingerprintReader` (extend `tests/hyprlock-vitta.test.ts` if no test pins it).
- [ ] **Step 4:** All tests PASS. No-change proof for this machine: `chezmoi diff -S ~/dotfiles-vitta-nvidia` equals `chezmoi diff -S <clean worktree of main>` (throwaway detached worktree; never the live `~/dotfiles`; `diff` only, never `apply`).
- [ ] **Step 5:** Commit(s) `feat(vitta): recognise vitta-nvidia`, `feat(vitta): passwordless keyring guard for greetd`. Not merged, not pushed to main: stop point S2.

### Task 9: Workstation parity gates and the P14s runbook (Phase 4)

**Files:**
- Create: `docs/how-to/vitta-p14s-acceptance.md`
- Modify: both smoke gates, `README.md`, `RECIPE.md`, `MAINTENANCE.md`, `CLAUDE.md`, `docs/superpowers/plans/2026-11-08-vitta-nvidia-plan.md` (status line + pointer here)

- [ ] **Step 1:** Gates under `IS_VITTA` + `IS_NVIDIA`, only what Task 1 found active on the P14s and Task 3 does not cover yet: `check_rpm libva-nvidia-driver nvidia-driver-cuda nvidia-persistenced`; unit state of `nvidia-persistenced.service` equals Task 1's finding; the existing `h264_nvenc` encoder assertion and the libvirt/`vitta-groups`/`vitta-libvirt-relabel` assertions run on this leg (verify in the CI log, do not duplicate them).
- [ ] **Step 2:** Runbook, derived from `docs/how-to/vitta-t580-acceptance.md`, each check as a command with its expected output. It opens with: the switch is the owner's decision and can be undone with `rpm-ostree rollback` or the previous GRUB entry.
  1. Before the switch: save `rpm-ostree status`, `rpm-ostree kargs`, `virsh -c qemu:///system dumpxml windows-work`, `authselect current`, `fprintd-list $USER`, `flatpak list | wc -l`; confirm the login keyring is passwordless.
  2. Rebase to `ostree-image-signed:docker://ghcr.io/dpietersz/vitta-nvidia:testing`; **before reboot**: `rpm-ostree kargs` shows each of the four args once; `LocalPackages` still lists `equibop` (D3).
  3. First boot: splash and styled LUKS prompt on the 2560×1600 panel, crisp; Esc gives the text prompt; greeter edge to edge on the internal panel; docked with lid closed as a second run.
  4. Login: password at the greeter is checked at once (no fingerprint prompt, no wait); wrong password fails within about 3 s; finger at the lock screen and for `sudo`; no keyring prompt; `login.keyring` not rewritten after the password login.
  5. `cd ~/dotfiles && git pull && chezmoi init && chezmoi apply`, then the greetd guard's result (`grep pam_gnome_keyring /etc/pam.d/greetd`).
  6. NVIDIA: `nvidia-smi` (620.x), dGPU `runtime_status` `suspended` when idle, `podman run --rm --device nvidia.com/gpu=all nvcr.io/nvidia/cuda:13.2-devel-fedora41 nvidia-smi`, toolbox with `nvidia=true`, `switcherooctl list`, an `h264_nvenc` test encode, OBS virtual camera on `/dev/video10`.
  7. Windows VM: `python3 -m unittest discover -s tests -p 'test_windows_work*.py' -v`, real boot, `Z:`/`Y:`/`X:`, camera, `windows-work-audio`.
  8. Dock (`boltctl list`, external displays), Telegram bot (R24), idle → lock → suspend, 5 min idle at the greeter.
  9. Recovery: previous deployment in GRUB, `rpm-ostree rollback`; promotion command for `vitta-nvidia`.
- [ ] **Step 3:** Docs pass over README / RECIPE / MAINTENANCE / CLAUDE.md for everything Tasks 4–6 added (password-only greetd stack, fprintd for lock screen and sudo, `tests/smoke/`, `DeviceScale`, GPU pin).
- [ ] **Step 4:** Commit `docs(vitta-nvidia): P14s acceptance runbook and parity gates`.

### Task 10: Branch review and hand-over

- [ ] **Step 1:** Controller opens PR 2 (`vitta-nvidia-phase3`), watches all four legs green, reads both Vitta legs' logs for the PAM probe and the greeter selftest.
- [ ] **Step 2:** Whole-branch review by a fresh reviewer with the Review Focus list and a login/passphrase brief (the greetd auth stack, what a rebased P14s and the T580 see).
- [ ] **Step 3:** Ledger updated; **stop (S2)**: owner merges PR 2 and the dotfiles branch. Phase 5 starts only on the owner's word.
