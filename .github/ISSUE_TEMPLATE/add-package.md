---
name: Add package to udx
about: Propose adding a new package to the baked image
title: "[add] <package-name>"
labels: ["enhancement"]
---

## Package
<!-- name -->

## Bake/keep criteria (all three must be yes)
- [ ] Stable: I've used this > 6 months without churn
- [ ] Integration-sensitive: needs Wayland portal / MIME / fingerprint / polkit / native theme / screen-share
- [ ] Has a maintainable Fedora source (vendor RPM / Fedora repo / Terra / long-lived COPR)

If any "no", strongly consider distrobox `common-toolbox` instead.

## Source
<!-- Specific URL / COPR / repo. Must be a real, reachable source today. -->

## Bake reason (taxonomy from RECIPE.md)
<!-- bootstrap | screen-share | system-integration | system-tool | dev-system-deps | nvidia -->

## Fallback if source dies
<!-- What's plan B in 12 months when this COPR/vendor disappears? -->

## RECIPE.md row to add
<!-- Paste the proposed table row here -->

## Smoke-test additions
<!-- What new command/file check needs to go into local-build-test.sh + .github/workflows/build.yml? -->
