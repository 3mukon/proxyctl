---
id: DOC-operations
type: doc
title: Proxyctl operations
status: current
visibility: public
date: 2026-11-17
summary: Configure nodes and presets, verify forwarding, and manage protection and recovery.
scope: ["Sources/**", "scripts/install.sh"]
tags: []
---

The system TUN captures public traffic for sing-box. Direct forwarding, the default proxy group, individual nodes, and an optional external proxy are outbound choices within that policy. The independent PF guard blocks ordinary public traffic that bypasses the tunnel.

## Nodes and routing

Use `/setup import` in the console or `proxyctl setup FILE` in the shell to import sing-box client JSON with an `outbounds` array. Select nodes by number or repeat `--node` in priority order. Use `--group NAME` to import the order from a source selector or URL-test group containing native nodes. The inventory shows recognized nodes. The selector includes the chosen nodes. Private configuration remains in `~/Library/Application Support/Proxyctl` with mode 700 on the directory and 600 on configuration files.

Open `/nodes group` to edit the existing group. Select a member to move it up, move it down, or remove it from the group. Select another imported node to add it, then choose **Save changes**. The shell command `proxyctl nodes group NODE...` accepts members in priority order. System profile preparation reads the saved local group.

Copy one or more individual share links, then choose `/nodes add`. The same import path accepts piped text with `proxyctl nodes add --stdin`. A new profile starts with both service presets enabled. Additional links append to the existing candidate order and preserve the routing policy. The bundled sing-box checks the generated profile before it is saved. Use native sing-box JSON for options or transports the link importer cannot represent.

Common imported schemes include Shadowsocks, VMess, VLESS, Trojan, Hysteria, Hysteria2, TUIC, AnyTLS, SOCKS, HTTP CONNECT, SSH, Snell, and Naive. Transport and authentication options still depend on the pinned engine. The importer reads clipboard text locally and keeps credentials in the private profile. [SIP002 share links](https://shadowsocks.org/doc/sip002.html) · [Xray share links](https://github.com/XTLS/Xray-core/discussions/716) · [Hysteria2 URI scheme](https://v2.hysteria.network/docs/developers/URI-Scheme/)

New imports enable both built-in domain presets and assign them to the default proxy group. Open `/presets route`, select a collection, then search by outbound or node name. Claude and OpenAI can use the default group or any imported node and run before user-created collections. Custom collections can also choose direct forwarding or the configured external proxy. Open `/presets edit` to create a collection, edit its members, change its outbound, or delete a custom collection. Enable or disable collections from the `/presets` completion menu. [Claude Code network configuration](https://code.claude.com/docs/en/network-config) · [OpenAI network recommendations](https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps)

Supplied preset labels follow the interface language. You can search or select a preset by its Chinese label, English label, or stable command identifier. Custom presets display the name you give them.

The catch-all appears as "Everything else" in `/rules`. It applies when no preceding rule matches and starts at DIRECT. Use `/rules default` to choose direct forwarding, the default proxy group, a specified node, or an external proxy. The console prompts for the address on the first selection of an external proxy. The rule view identifies pending changes when the running system uses a different catch-all. [sing-box route configuration](https://sing-box.sagernet.org/configuration/route/)

Within the system tunnel, DIRECT uses an independent TLS resolver. The same resolver bootstraps node hostnames. Proxied domains use synthetic A and AAAA addresses. Their other DNS queries go through the selected outbound, including the specified node for a rule with a node binding. DIRECT connections can continue during a proxy node failure as long as the engine and direct path are healthy.

An application or local proxy can hand an existing proxy connection to the managed sing-box. If the connection to the first proxy's remote server matches DIRECT, sing-box forwards that outer connection and the destination still sees the first proxy's exit. The managed route policy can match only the metadata visible on its own inbound connection. The system trial keeps one owner for macOS tunnel routing.

## Custom rules and upstream

Use `/rules` to view custom rules and the catch-all. Type a domain or IP/CIDR after `/rules add`, or press Enter to open guided entry. Both paths offer an outbound in the command menu. Completing `remove` in `/rules remove` lists the existing local rules with their outbounds. If system rules are active, press Enter to read them and complete any authentication. Select a rule and press Enter once the finished command is in the input to remove it.

```text
/rules add example.net proxy
/rules add files.example.net "node:US IPv6"
/rules add 203.0.113.0/24 direct
/rules remove example.net proxy
/presets route openai "node:US IPv6"
/rules default "node:US IPv6"
```

Enabled presets run first in the displayed order. Single rules check domain suffixes before IP ranges. Within each kind, specified nodes are checked in inventory order, followed by the default proxy group, the external proxy, and direct forwarding. Local rule-set files update the running core for new connections. On upgrade, the next profile save or preview startup prepares the per-node rule files and carries forward the existing rules. [sing-box local rule sets](https://sing-box.sagernet.org/configuration/rule-set/)

Open `/setup upstream` to view, change, or clear the external proxy address used by rules. Supply the address directly with `proxyctl setup upstream socks5://HOST:PORT` or an HTTP or HTTPS CONNECT URL. Use `proxyctl setup upstream off` to clear an address after removing its uses. Select an authenticated endpoint from a sing-box file with `setup FILE --upstream NODE`. Choose the external proxy for a single rule, a custom preset, or unmatched traffic. Use `/rules default upstream` to select it for all unmatched traffic. A failed upstream stays within that outbound policy. The endpoint can change while the loopback engine is stopped. The protected system profile takes a separate root-owned snapshot at preparation. SOCKS5 can forward UDP if the endpoint supports it. HTTP CONNECT is a TCP path. [SOCKS outbound](https://sing-box.sagernet.org/configuration/outbound/socks/) · [HTTP outbound](https://sing-box.sagernet.org/configuration/outbound/http/)

With Proxyctl's system tunnel active, a local upstream must expose its listening port with its own system tunnel disabled. The local profile's startup check rejects a loopback listener owned by a VPN packet tunnel and probes any external proxy used by the route policy. If the port and a proxy node are tied to the same application, import the node directly and choose it as an outbound. Give an independent local proxy's remote server an explicit route through DIRECT or the selected group so its own traffic cannot loop back into the catch-all. Check the complete path during the timed system trial. The PF rules keep the same egress permissions.

When the protected system engine is active, the console routes single-rule edits, `/use`, `/check`, and `/nodes` to it. Protected commands that edit settings or run probes may request local administrator authentication. Use `proxyctl system rules` to target the system copy from a script. Single-rule additions and removals update the live rule sets.

On an updated protected deployment, saving presets or the catch-all automatically applies the new policy to the system engine. PF guards the engine restart, so established connections may reconnect. The watchdog restores the previous policy if the update fails or is interrupted. `/system apply` applies pending routing settings to an earlier running deployment or retries a saved change. Changes to the node inventory, default group membership, or external proxy address require a fresh system deployment.

## Node checks and selection

`/check` or `proxyctl check` validates the running system path. Before the system tunnel starts, the same command can probe the first configured node in an isolated process. The console opens a list of imported nodes after you complete `node` in `/check node`. Select a node and press Enter once its name is in the input to run an isolated check. Run `proxyctl check node NODE` or `proxyctl test NODE` in the shell for the same check. The default proxy group starts in automatic mode. `/use NODE` selects its current member, and `/use --auto` resumes priority-based selection. A rule or preset assigned to a specified node continues to use that node. If it becomes unavailable, connections assigned to it fail. Established healthy connections keep their current paths during a group switch. The group selection and automatic or manual preference persist across restarts.

## Start the system proxy

Configure the nodes, presets, routing rules, and any external upstream. Run `/system start` in the console or `proxyctl start` in the shell. When a local profile is available for startup, the command checks it over the current network before requesting that you pause another active VPN. The console offers Enter to continue after the other VPN has stopped. In the shell, rerun the start command. Proxyctl checks the new network before taking over.

A first start or a changed local profile checks isolated node forwarding before requesting administrator authentication. One system operation saves the profile, starts the offline watchdog, verifies TUN routing and forwarding, and tests the independent PF rules. The startup commits when both checks pass. A failure during the trial rolls back the changes. The watchdog can recover an interrupted trial offline. Start from a verified, stopped profile reuses its protection when the local profile matches the saved revision.

When starting from a stopped deployment, the startup reads the current local profile. A verified profile with no recorded source revision can start with its existing settings. Use `/system apply` once it is running to apply local presets and the catch-all. Replacing the full snapshot requires preparing a new deployment.

## Manual system trial

1. Run `proxyctl system plan` for offline engine validation and PF syntax checks.
2. Run `proxyctl system prepare` with the current network available. It checks each pinned node and finds the first reachable member of the default proxy group through isolated forwarding. Each probe has an eight-second connection limit and a twelve-second total limit, with one retry on failure. Complete administrator authentication in the same terminal after the checks pass to save the system trial profile and engine.
3. After the operator pauses any competing system tunnel, run `proxyctl system trial`. A launchd watchdog starts a four-minute offline rollback timer before the TUN starts. The trial checks both routing families, DIRECT HTTPS when configured, and the selected node. Enabled presets also verify transparent HTTPS with A and AAAA synthetic addresses.
4. Run `proxyctl firewall on` to test independent protection. It checks the tunnel, applies the PF anchor, and verifies that PF blocks a physical-interface bypass while TUN traffic still works. It also checks IPv6 bypass when the uplink offers IPv6. This starts a fresh four-minute trial.
5. Run `proxyctl system keep` after trying the applications during the PF trial. This records the verified profile and keeps the tunnel and PF running.

## Lifecycle

| Console command | Shell command | Effect |
| --- | --- | --- |
| `/system start` | `proxyctl start` | Verify and start the system proxy and independent PF |
| `/system apply` | `proxyctl system apply` | Apply saved presets and the catch-all while PF guards the restart |
| `/system stop` | `proxyctl stop` | Stop the system tunnel and remove its PF rules and DNS entry for this boot |
| `/system enable` | `proxyctl enable` | Register the verified system proxy as a system LaunchDaemon for future boots |
| `/system disable` | `proxyctl disable` | Remove its boot registration |
| `/system rollback` | `proxyctl system rollback` | Undo deployment, verification, and startup at boot |

Use `proxyctl system status` for the active tunnel, PF, and boot registration state. Use `proxyctl system nodes`, `proxyctl system check`, and `proxyctl system use --auto` to inspect or select the node. Boot registration and current runtime are separate settings. The launchd job can start without an account login after the physical route is available. [Apple launchd jobs](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)

Use `proxyctl system use 'node name'` to switch between members of the running system proxy's default group.

## Independent PF protection

The packet filter drops ordinary public egress on interfaces outside the product TUN. The engine can originate TCP and UDP using a dedicated effective group ID, allowing both DIRECT and PROXY through sing-box. Loopback, local-network services, and basic interface configuration have local exceptions. The guard remains loaded if the engine exits. With autostart enabled for a verified setup, the watchdog waits for the macOS ruleset to load, then attaches its PF guard before checking the uplink or launching the TUN service. It retries startup after transient failures and retains any active PF rules. Enforcement begins when PF loads. Use the offline recovery command to release protection if recovery cannot complete.

Firewall activation checks live rules and refuses to replace a custom base ruleset or existing PF connection state. It uses a separate anchor and its own PF enable reference. Rollback releases that reference, clears its rules, and restores the original top filter when the top filter still matches what Proxyctl installed.

## Offline recovery

`proxyctl system rollback` stops the managed tunnel, removes its DNS entry, releases its PF rules, and clears boot registration and verification. Either unconfirmed trial expires offline, even after the terminal closes. If the PF trial fails, it removes the product rules and leaves the TUN trial on a timer.

Use the root-owned copy if the user command is unavailable.

```sh
sudo '/Library/Application Support/Proxyctl System/proxyctl' system rollback
```

The preceding network configuration resumes after rollback. Third-party VPN clients remain under the operator's control.

## Loopback diagnostics

`proxyctl preview` starts a foreground loopback listener for integration tests and accepts traffic from clients configured to use that listener. The default proxy port is 11082 and the default control port is 19082. Use `Ctrl-C` to stop it. The system capture and PF status reflect the actual system deployment during diagnostics.

For installations that registered the earlier loopback service, use `proxyctl service stop` or `proxyctl service remove` to manage that registration. Use `proxyctl start` and `proxyctl enable` for the verified system deployment.
