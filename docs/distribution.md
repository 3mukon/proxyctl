---
id: DOC-distribution
type: doc
title: Release packaging and corresponding source
status: current
visibility: public
date: 2026-11-25
summary: Build the macOS archive and provide license notices and the exact source of its bundled engine.
scope: ["scripts/build.sh", "scripts/package-release.sh", "licenses/**"]
tags: []
supersedes: []
superseded_by:
---

## macOS archive

The archive contains two separate executables: Proxyctl and an unmodified, pinned sing-box release. It also contains the installer and license materials. The installer copies both executables and `licenses/` to a versioned directory under `~/.local/share/proxyctl`. It does not start the system proxy.

Run `sh scripts/check.sh` on Apple Silicon and then `sh scripts/package-release.sh` to package the checked build. The script prints the archive path under `.build/`. The archive contains only the installer, the two executables, and their license materials. Test a fresh extraction with `PROXYCTL_INSTALL_ROOT` set to a temporary directory. For a public Release, pass the verified dependency notice file as the first argument to `scripts/package-release.sh`. Publish the archive and source assets together with their SHA-256 values.

## Licenses

Proxyctl code and documentation are under the [MIT License](../LICENSE). The separate sing-box binary is under GPL-3.0-or-later. The archive includes the upstream notice, the GNU GPL version 3 text, and this source information. The public release includes notices for the linked Go modules and NaiveProxy. The source archives retain the upstream license notices.

## sing-box v1.14.4 for macOS ARM64

| Item | Pinned upstream input |
| --- | --- |
| Binary | [SagerNet release archive](https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-darwin-arm64.tar.gz) |
| Exact revision | [`c005f35300ce76427dc285481ec5695f5b179cd2`](https://github.com/SagerNet/sing-box/tree/c005f35300ce76427dc285481ec5695f5b179cd2) |
| Release archive SHA-256 | `0d8c7f5ed5d587b0f1a5e9772a708ec3bfa4ac4c9329604b01d8d9c2ba406838` |
| Installed binary SHA-256 | `6546126c1759683fe85798da92409215d53c50e0f2b346b4f74a61babc8dbec2` |
| Go modules | [Exact module versions and checksums](https://github.com/SagerNet/sing-box/blob/c005f35300ce76427dc285481ec5695f5b179cd2/go.sum); the binary's linked modules are listed in the source companion |
| ARM64 build | [Upstream workflow](https://github.com/SagerNet/sing-box/blob/c005f35300ce76427dc285481ec5695f5b179cd2/.github/workflows/build.yml#L471-L570), Go 1.26.10, and the Darwin build tags and linker flags under `release/` |
| Cronet Go bindings | [`0d28acc44093df24b2526dea3d6ffefd6b0a54f0`](https://github.com/SagerNet/cronet-go/tree/0d28acc44093df24b2526dea3d6ffefd6b0a54f0) |
| Cronet static library build | [`049f2909701ca088c9569f6b303bba5376a2b2ff`](https://github.com/SagerNet/cronet-go/tree/049f2909701ca088c9569f6b303bba5376a2b2ff); output published at [`c10c03c318db6d47bec8705c8290bad34bc32b64`](https://github.com/SagerNet/cronet-go/commit/c10c03c318db6d47bec8705c8290bad34bc32b64) |
| NaiveProxy and Chromium | [`72a06c9fca0e2d228588c7f3074bf7efff3ff686`](https://github.com/SagerNet/naiveproxy/tree/72a06c9fca0e2d228588c7f3074bf7efff3ff686), with its build dependencies pinned in [`src/DEPS`](https://github.com/SagerNet/naiveproxy/blob/72a06c9fca0e2d228588c7f3074bf7efff3ff686/src/DEPS) |

For the engine source, select the release matching the archive you downloaded on the [Proxyctl Releases page](https://github.com/3mukon/proxyctl/releases). The companion for this engine is named `sing-box-1.14.4-corresponding-source.tar.gz`. Its README maps the pinned source trees, linked dependency archives, and build instructions. The source is available without installing Proxyctl or signing in. The download page also identifies the source archive for the exact linked NaiveProxy revision.
