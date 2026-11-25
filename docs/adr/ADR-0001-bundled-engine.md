---
id: ADR-0001
type: adr
title: Bundle a separate engine with the CLI
status: proposed
visibility: public
date: 2026-11-17
summary: Keep interaction, privileges, and traffic handling in separate processes.
scope: ["Sources/**", "scripts/**"]
tags: []
supersedes: []
superseded_by: []
---

## Context

Users need a macOS console that works after installation and a proxy that can keep running after the terminal closes. An existing client may own routing, system DNS, and independent protection. Each needs verification before the new service takes over.

## Decision

Ship a native Swift CLI with a pinned sing-box executable. The CLI runs as the current user. The boot services run the same engine version under launchd. The loopback API and selector handle node changes at runtime. A parallel loopback preview verifies forwarding. A timed TUN trial and a separate PF trial precede protected system mode. The product owns its service lifecycle and rollback.

## Alternatives

- Using the system `sing-box` command requires a separate installation and creates version differences.
- Editing JSON and restarting for each node change interrupts connections and makes outages harder to distinguish from routine switches.
- Launching the engine from a GUI client introduces a dependency on a login session and another application.

## Consequences

The release can be installed offline. The loopback service runs across login sessions and can be tested alongside the active VPN. Transparent TUN, routing, and firewall takeover have separate acceptance checks. The release preserves the upstream notice and includes the GPL text. The [distribution guide](../distribution.md) identifies the exact engine source and build inputs.

## References

- [sing-box selector](https://sing-box.sagernet.org/configuration/outbound/selector/)
- [sing-box Clash API](https://sing-box.sagernet.org/configuration/experimental/clash-api/)
- The console adapts the public Grok Build pager's bottom composer, contextual slash-command list, and separate status row. Proxyctl uses fixed result pages with an explicit return shortcut. [Session layout](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-pager/src/app/agent_view/render.rs), [Prompt widget](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-pager/src/views/prompt_widget/mod.rs)
