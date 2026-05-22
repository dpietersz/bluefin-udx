# Maintenance — quarterly review checklist

This image is a thin layer on top of `bluefin-dx`, but it accumulates third-party supply-chain dependencies (vendor RPM repos, COPRs, Terra, AppImage extracts) that each have their own lifecycle. Run this checklist **once per quarter** to catch stale sources before they break the nightly build.

Set a recurring calendar reminder. Quick pass should take ~15 minutes.

## Checklist

### 1. CI smoke-boot status
- [ ] Are the latest nightly builds for **both** `bluefin-udx` and `bluefin-udx-nvidia` green on GitHub Actions?
- [ ] If red for > 3 consecutive nights, investigate immediately (don't wait for the quarterly review).

### 2. COPR liveness
For each COPR baked into `common.yml`, check it received at least one build in the last quarter:
- [ ] `sneexy/zen-browser` — https://copr.fedorainfracloud.org/coprs/sneexy/zen-browser/builds/
- [ ] `cosmicfusion/Obsidian` (Phase 3) — https://copr.fedorainfracloud.org/coprs/cosmicfusion/Obsidian/builds/
- [ ] `lionheartp/Hyprland` (Phase 2, for noctalia-shell-v5) — https://copr.fedorainfracloud.org/coprs/lionheartp/Hyprland/builds/

If any COPR has gone dormant (> 90 days without a build) and upstream has released a new version, switch to the documented fallback (see RECIPE.md "Fallback if source dies" column).

### 3. Vendor RPM repos
For each vendor `.repo` URL baked into `common.yml`, verify it still returns 200 and the GPG key still validates:
- [ ] Microsoft Teams — https://repo.teamsforlinux.de/rpm/teams-for-linux.repo
- [ ] Beekeeper Studio (Phase 3)
- [ ] Bruno (Phase 3)
- [ ] NVIDIA CUDA (Phase 4)

A 4xx on any of these breaks the image build. Renovate is configured to flag this, but eyeball it anyway.

### 4. Upstream movement
- [ ] Has Zen Browser stabilized enough to ship an official RPM? If yes, drop `sneexy/`.
- [ ] Has Helium graduated out of Terra into its own vendor repo?
- [ ] Has Polypane started shipping an RPM? If yes, drop the AppImage-extract pattern.

### 5. CUDA toolkit drift (NVIDIA variant)
- [ ] Does the baked `cuda-toolkit` version match what your active ML projects target?
- [ ] If not, bump the recipe — but coordinate with project requirements.txt / pyproject.toml first.

### 6. Bake-pruning
- [ ] List packages baked but **not launched in the last 90 days** (rough proxy: when did you last open the app?).
- [ ] Candidates → consider moving to `common-toolbox` (distrobox) or removing entirely.

### 7. Bluefin-DX base image cadence
- [ ] Is `bluefin-dx:stable` still the right channel? If you've been on `:latest` mentally but `:stable` in recipe, reconcile.
- [ ] Major Fedora version bump coming? Add to the next review's agenda.

### 8. macOS reality check
- [ ] Did anything in `dotfiles/.chezmoiscripts/run_once_before_01b-install-homebrew-packages.sh.tmpl` need a corresponding Linux update that didn't land?
- [ ] Goal: macOS and Linux deliver the same developer experience modulo OS-specific apps.

## When something breaks mid-quarter

1. Open issue using the "Package broken upstream" template.
2. Rebase the affected machine to the previous known-good image tag (`bootc rollback` or `bootc switch ghcr.io/dpietersz/bluefin-udx:<previous-sha>`).
3. Fix in a branch, validate locally with `./scripts/local-build-test.sh`, push, confirm CI green, then `bootc upgrade` again.
