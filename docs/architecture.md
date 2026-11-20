---
id: DOC-architecture
type: doc
title: Proxyctl hard base
status: current
visibility: public
date: 2026-11-17
summary: Separate presentation, profile policy and macOS service operations while maintaining a safe deployment path.
scope: []
tags: []
framework: project-foundation@0.1.0
---

## Plane

The product repository holds publishable code, tests and technical records. Node credentials and machine-local configuration stay outside the repository.

## Layers

Code lives in `Sources/`. `scripts/check.sh` builds the release and runs verification. `docs/` holds technical knowledge. `AGENTS.md` is the agent entry. The maintainer's local hooks scan secret and publication boundaries.

## Module rules

`CLI` orchestrates `Profiles` and `Host`. `Profiles` owns node inventory and selection constraints. `Host` owns process execution, control requests and launchd operations. Profile files form the contract between the profile and host capabilities. Test behavior through the executable and the bundled engine.

## Invariants

1. Product documents use only publishable references. The publication hook checks tracked content and commit messages.
2. Credentials live in user-controlled files outside the repository. Scan source at commit and push and use mock nodes in tests.
3. Outward text uses technical reasons and product IDs. Check commit messages and outgoing refs locally.
4. Knowledge documents use templates, stable IDs and an index. Review those fields together when the document changes.
5. Document behavior where it is implemented and update the current-state guide with behavior changes.
6. Run verification before completing a change. Preserve failing checks while correcting causes.
7. Only the maintainer changes the hard base. Propose and review changes to protected files.
8. The initial core is a macOS loopback proxy. A future protected system mode requires a validated data path, persistent protection independent of engine health, and an offline rollback before migration. Verify those conditions explicitly before enabling that mode.
9. A selection failure preserves the current policy and keeps traffic within the explicitly selected group. Exercise both healthy and unavailable nodes in integration tests.

## Protected files

`AGENTS.md`, `CLAUDE.md`, this file, the document core of `docs/conventions.md`, `scripts/check.sh`, release gate configuration, and future license, CI and scanning configuration. Changes require the maintainer's approval.

## Change rules

The hard base and module contracts describe the architecture. A change to their boundaries, invariants or publishing model requires a matching changed requirement and maintainer approval. Conventions can evolve with a recorded technical decision. Details belong in the module that uses them.
