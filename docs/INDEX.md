# Documentation index

Start here and open the documents whose summary matches your task.

## Foundation

| ID | Status | Title | Summary |
| --- | --- | --- | --- |
| [DOC-architecture](architecture.md) | current | Proxyctl hard base | Separate presentation, profile policy and macOS service operations while maintaining a safe deployment path. |
| [DOC-conventions](conventions.md) | current | Proxyctl conventions | Document rules, tags, naming, commit format, checks, agent tools and exemplars |
| [DOC-glossary](glossary.md) | current | Proxyctl glossary | Shared technical terms |

## Modules

| ID | Status | Title | Summary |
| --- | --- | --- | --- |
| [DOC-mod-cli](../Sources/CLI/README.md) | current | Terminal interface | Provide the interactive console, diagnostics, and scripting interface. |
| [DOC-mod-profiles](../Sources/Profiles/README.md) | current | Nodes and configuration | Manage the node inventory, candidate order, and configuration generation. |
| [DOC-mod-host](../Sources/Host/README.md) | current | macOS runtime layer | Run the local engine, call its control API, and manage the system service. |

## Decisions

| ID | Status | Title | Summary |
| --- | --- | --- | --- |
| [ADR-0001](adr/ADR-0001-bundled-engine.md) | proposed | Bundle a separate engine with the CLI | Keep interaction, privileges, and traffic handling in separate processes. |

## Current state

| ID | Status | Title | Summary |
| --- | --- | --- | --- |
| [DOC-operations](operations.md) | current | Proxyctl operations | Configure nodes and presets, verify forwarding, and manage protection and recovery. |
| [DOC-distribution](distribution.md) | current | Release packaging and corresponding source | Build the macOS archive and provide license notices and the exact source of its bundled engine. |
