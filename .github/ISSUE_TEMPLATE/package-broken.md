---
name: Package broken upstream
about: A baked package's source (Fedora repo, vendor RPM, COPR, Terra) is broken or unavailable
title: "[broken] <package-name>"
labels: ["broken-upstream"]
---

## Affected package
<!-- e.g. teams-for-linux, zen-browser, helium-browser-bin -->

## Source
<!-- Vendor RPM URL / COPR path / Terra / AppImage URL — the value that appears in RECIPE.md -->

## Failure mode
<!-- Build error log line, 4xx on .repo URL, missing dependency, GPG verification fail, etc. -->

## CI build link
<!-- Link to the failed GH Actions run -->

## Workaround in place?
<!-- Did you rebase to a previous good tag? Disable the package temporarily? -->

## Fix path
<!-- Per RECIPE.md "Fallback if source dies" column -->
