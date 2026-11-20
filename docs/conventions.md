---
id: DOC-conventions
type: doc
title: Proxyctl conventions
status: current
visibility: public
date: 2026-11-17
summary: Document rules, tags, naming, commit format, checks, agent tools and exemplars
scope: []
tags: []
---

## Document core

Technical decisions use `ADR-NNNN`, lessons use `L-NNNN`, and current state uses `DOC-<slug>`. Module documents use `DOC-mod-<module>`. Use the matching status and required sections in `docs/templates/`. The core fields are id, type, title, status, visibility, date, summary, scope and tags. Keep an accepted decision intact and supersede it with a new decision if needed.

## Documents

Add each document to `docs/INDEX.md`. Use technical prose and product identifiers in the product plane. Section names follow the templates.

## Tags

None yet.

## Naming

Use Swift type naming conventions and lowercase command verbs. Test inputs use explicit loopback hosts and disposable paths.

## Commits

Use `type: describe the technical change`, with an optional body and `Refs:` using product identifiers. Typical types are feat, fix, refactor, docs, test and chore.

## Checks

| Check | When it runs | What it covers | How to run it by hand |
| --- | --- | --- | --- |
| Build and integration | Before completing a change | Packaged core, CLI, install, loopback traffic and failure modes | `sh scripts/check.sh` |
| Maintainer hooks | On local commit and push | Secrets and publication rules | Run through Git |

## Agent tools

Use `AGENTS.md` as the entry. Tool-specific entries import it.

## Language

Write all project documentation in English, including README files, indexes, technical decisions, operational guides, and template guidance. Use English for source identifiers and comments. The language of user-facing CLI messages is an independent product choice.

## Exemplars

`Sources/Profiles/` owns its behavior, documentation and integration coverage in the executable smoke test.
