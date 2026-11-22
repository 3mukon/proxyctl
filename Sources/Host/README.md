---
id: DOC-mod-host
type: doc
title: macOS runtime layer
status: current
visibility: public
date: 2026-11-17
summary: Run the local engine, call its control API, and manage the system service.
scope: ["Sources/Host/**"]
tags: []
---

## Responsibilities

Run the bundled engine and call its control API. Select the first healthy member independently in each group during background health checks. Existing scripts can still pin a member of the default group. Manage loopback service registration, timed TUN and PF trials, and offline rollback through independent launchd jobs.

## Non-responsibilities

Callers decide node priority and render the interface.

## Public interface

`Engine` queries, tests, and selects nodes. `SystemService` manages the loopback job. `ProtectedService` manages the TUN and watchdog jobs. It verifies a routing update after restarting the engine under PF. `RoutingRollback` keeps the previous configuration available until verification commits, allowing the watchdog to restore it after an interruption. `TunnelCheck` checks routes, reachability, and whether a loopback upstream is supplied by another packet tunnel. `PacketFilter` owns its anchor and enable reference. `Host.swift` provides file utilities. `Command.swift` runs child processes and keeps interactive administrator commands attached to the foreground terminal.

Authenticated management commands use the current CLI with the installed system profile. They wait for the profile lock for up to 15 seconds before executing. The watchdog uses the root-owned driver and leaves a busy lock for its next scheduled check.

## Allowed dependencies

macOS system tools, the bundled sing-box engine, and the read-only configuration interface of `Profiles.ManagedProfile`.
