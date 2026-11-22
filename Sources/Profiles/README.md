---
id: DOC-mod-profiles
type: doc
title: Nodes and configuration
status: current
visibility: public
date: 2026-11-17
summary: Manage the node inventory, candidate order, and configuration generation.
scope: ["Sources/Profiles/**"]
tags: []
---

## Responsibilities

Identify nodes in a client configuration or share links and validate each group's order. Generate loopback and system configurations with editable presets, hot rule files, direct and external forwarding, and DNS routes for groups and specified nodes.

## Non-responsibilities

Host owns service startup and node health checks. CLI presents terminal output.

## Public interface

`Profile` parses source configurations and builds candidates. `ManagedProfile` reads the selected nodes and listeners. `ProxyGroup` validates names and members and represents an ordered sing-box selector. `saveDefaultGroup` edits the local default selector. `Routing` generates sing-box routing and DNS policy. `RuleFiles` validates and updates local rule sets. `RuleCollection` represents editable presets and `ShareLink` translates supported URIs into native outbounds. `SystemProfile` builds a self-contained TUN profile. `RoutingUpdate` validates group, preset, and catch-all changes against the installed nodes while retaining single-rule files.

## Allowed dependencies

Foundation, Darwin, CryptoKit, and the file and process utilities from `Host`.
