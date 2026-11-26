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

The system TUN captures public traffic for sing-box. Direct forwarding, proxy groups, individual nodes, and an optional external proxy are outbound choices within that policy. The independent PF guard blocks ordinary public traffic that bypasses the tunnel.

## Nodes and routing

Use `/nodes import` in the console or `proxyctl nodes import FILE` in the shell to import sing-box client JSON with an `outbounds` array. Select nodes by number or repeat `--node` in priority order. Use `--group NAME` to import the order from a source selector or URL-test group containing native nodes. Private configuration remains in `~/Library/Application Support/Proxyctl` with mode 700 on the directory and 600 on configuration files.

Open `/groups edit` to select an existing group or create a named group. Select a member to move it up, move it down, or remove it. Select another imported node to add it, then choose **Save changes**. `proxyctl groups set NAME NODE...` and `proxyctl groups default NODE...` take members in priority order. To remove a named group, first change any rule or preset using it, including disabled presets. `/groups` shows configured priorities and the selected members of running selectors.

Open `/nodes add` and paste one share link per line into its masked field. Press Enter to add the links. Enter on a blank field imports the copied links from the clipboard. The same import path accepts piped text with `proxyctl nodes add --stdin`. A new profile starts with the Claude, OpenAI, and Gemini presets enabled. Additional links append to the existing candidate order and preserve the routing policy. The bundled sing-box checks the generated profile before it is saved. Use native sing-box JSON for options or transports the link importer cannot represent.

Common imported schemes include Shadowsocks, VMess, VLESS, Trojan, Hysteria, Hysteria2, TUIC, AnyTLS, SOCKS, HTTP CONNECT, SSH, Snell, and Naive. Transport and authentication options still depend on the pinned engine. The importer reads clipboard text locally and keeps credentials in the private profile. [SIP002 share links](https://shadowsocks.org/doc/sip002.html) · [Xray share links](https://github.com/XTLS/Xray-core/discussions/716) · [Hysteria2 URI scheme](https://v2.hysteria.network/docs/developers/URI-Scheme/)

New profiles assign the built-in domain presets to the default proxy group. Open `/presets route`, select a collection, then choose its group or outbound. Claude, OpenAI, and Gemini can use any group or imported node and run before user-created collections. Custom collections can also choose direct forwarding or the configured external proxy. Complete `/presets edit` to select an existing collection or **New preset**. Run the completed command to open the editor. An existing preset's editor can change members and the outbound or delete a custom collection. Enable or disable collections from the `/presets` completion menu. [Claude Code network configuration](https://code.claude.com/docs/en/network-config) · [OpenAI network recommendations](https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps)

Gemini covers dedicated production hosts for the web and macOS apps, Google AI Studio, the Gemini Developer API, and the default Gemini CLI and Code Assist services. Shared Google Account, Workspace, media, and Vertex AI hosts follow the rest of your routing policy. In an existing profile, Gemini starts disabled and can be enabled with `/presets enable`. A pre-existing preset named Gemini keeps its members and outbound. [Gemini app hosts](https://knowledge.workspace.google.com/admin/generative-ai/gemini-app/gemini-app-firewall-settings) · [Gemini API](https://aistudio.google.com/api-reference) · [Gemini Code Assist endpoints](https://docs.cloud.google.com/gemini/docs/codeassist/set-up-gemini#configure_the_firewall_for_api_traffic_between_your_ide_and_google)

Supplied preset labels follow the interface language. You can search or select a preset by its Chinese label, English label, or stable command identifier. Custom presets display the name you give them.

The catch-all appears as "Everything else" in `/rules`. It applies when no preceding rule matches and starts at DIRECT. Use `/rules default` to choose direct forwarding, a group, a specific node, or an external proxy. The console prompts for the address on the first selection of an external proxy. The rule view identifies pending changes when the running system uses a different catch-all. [sing-box route configuration](https://sing-box.sagernet.org/configuration/route/)

Within the system tunnel, DIRECT uses an independent TLS resolver. The same resolver bootstraps node hostnames. Proxied domains use synthetic A and AAAA addresses. Their other DNS queries go through the selected outbound, including the specified node for a rule with a node binding. DIRECT connections can continue during a proxy node failure as long as the engine and direct path are healthy.

An application or local proxy can hand an existing proxy connection to the managed sing-box. If the connection to the first proxy's remote server matches DIRECT, sing-box forwards that outer connection and the destination still sees the first proxy's exit. The managed route policy can match only the metadata visible on its own inbound connection. The system trial keeps one owner for macOS tunnel routing.

## Custom rules and upstream

Use `/rules` to view custom rules and the catch-all. Type a domain or IP/CIDR after `/rules add`, or press Enter to open guided entry. Both paths offer an outbound in the command menu. Completing `remove` in `/rules remove` lists the existing local rules with their outbounds. If system rules are active, press Enter to read them and complete any authentication. Select a rule and press Enter once the finished command is in the input to remove it.

```text
/rules add example.net proxy
/rules add work.example.net "group:Work"
/rules add files.example.net "node:US IPv6"
/rules add 203.0.113.0/24 direct
/rules remove example.net proxy
/presets route openai "node:US IPv6"
/rules default "node:US IPv6"
```

Enabled presets run first in the displayed order. To give a domain in an existing preset its own group, move the domain to a separate preset and assign that group. Single rules check domain suffixes before IP ranges. Within each kind, the order is specified nodes in inventory order, named groups in creation order, the default group, the external proxy, and direct forwarding. Local rule-set files update the running core for new connections. A profile update adds rule files for new groups and carries forward existing rules. [sing-box local rule sets](https://sing-box.sagernet.org/configuration/rule-set/)

Open `/rules upstream` to view, change, or clear the external proxy address used by rules. Supply the address directly with `proxyctl rules upstream socks5://HOST:PORT` or an HTTP or HTTPS CONNECT URL. Use `proxyctl rules upstream off` to clear an address after removing its uses. Select an authenticated endpoint from a sing-box file with `proxyctl nodes import FILE --upstream NODE`. Choose the external proxy for a single rule, a custom preset, or unmatched traffic. Use `/rules default upstream` to select it for all unmatched traffic. A failed upstream stays within that outbound policy. The endpoint can change while the loopback engine is stopped. The protected system profile takes a separate root-owned snapshot at preparation. SOCKS5 can forward UDP if the endpoint supports it. HTTP CONNECT is a TCP path. [SOCKS outbound](https://sing-box.sagernet.org/configuration/outbound/socks/) · [HTTP outbound](https://sing-box.sagernet.org/configuration/outbound/http/)

With Proxyctl's system tunnel active, a local upstream must expose its listening port with its own system tunnel disabled. The local profile's startup check rejects a loopback listener owned by a VPN packet tunnel and probes any external proxy used by the route policy. If the port and a proxy node are tied to the same application, import the node directly and choose it as an outbound. Give an independent local proxy's remote server an explicit route through DIRECT or the selected group so its own traffic cannot loop back into the catch-all. Check the complete path during the timed system trial. The PF rules keep the same egress permissions.

When the protected system engine is active, the console shows system state for `/nodes` and `/groups`. It targets the system for single-rule edits and route checks. Protected commands that edit settings or run probes may request local administrator authentication. After authentication a command can wait briefly for the watchdog to finish before it runs. Use `proxyctl system rules` to target the system copy from a script. Single-rule additions and removals update the live rule sets.

On a protected deployment, saving group, preset, or catch-all edits applies the policy after administrator authentication. PF guards the engine restart, so established connections may reconnect. The watchdog restores the previous policy if the update fails or is interrupted. Use `/system apply` to retry a pending update. A group that uses a newly imported node requires the node in the system profile. Changes to the node inventory or external proxy address require a fresh system deployment.

## Node checks and selection

`/check` or `proxyctl check` validates the running system path. Before the system tunnel starts, the same command can probe the first configured node in an isolated process. The console opens a list of imported nodes after you complete `node` in `/check node`. Select a node and press Enter once its name is in the input to run an isolated check. Run `proxyctl check node NODE` in the shell for the same check. Each group uses its first healthy member. During automatic failover or failback, established healthy connections keep their current paths. When all members fail, new connections assigned to the group fail. A rule or preset assigned to a specific node keeps that outbound during node failure.

## Start the system proxy

Configure the nodes, presets, routing rules, and any external upstream. Run `/system start` in the console or `proxyctl start` in the shell. When a local profile is available for startup, the command checks it over the current network before requesting that you pause another active VPN. The console offers Enter to continue after the other VPN has stopped. In the shell, rerun the start command. Proxyctl checks the new network before taking over.

A first start or a changed local profile checks isolated node forwarding before requesting administrator authentication. One system operation saves the profile, starts the offline watchdog, verifies TUN routing and forwarding, and tests the independent PF rules. The startup commits when both checks pass. A failure during the trial rolls back the changes. The watchdog can recover an interrupted trial offline. Start from a verified, stopped profile reuses its protection when the local profile matches the saved revision.

When starting from a stopped deployment, the startup reads the current local profile. A verified profile with no recorded source revision can start with its existing settings. Use `/system apply` once it is running to apply saved group and routing changes. Replacing the full snapshot requires preparing a new deployment.

## Manual system trial

1. Run `proxyctl system plan` for offline engine validation and PF syntax checks.
2. Run `proxyctl system prepare` with the current network available. It checks each pinned node and finds a reachable member for the default group and each named group used by the policy. Each probe has an eight-second connection limit and a twelve-second total limit, with one retry on failure. Complete administrator authentication in the same terminal after the checks pass to save the system trial profile and engine.
3. After the operator pauses any competing system tunnel, run `proxyctl system trial`. A launchd watchdog starts a four-minute offline rollback timer before the TUN starts. The trial checks both routing families, DIRECT HTTPS when configured, and the selected node. Enabled presets also verify transparent HTTPS with A and AAAA synthetic addresses.
4. Run `proxyctl firewall on` to test independent protection. It checks the tunnel, applies the PF anchor, and verifies that PF blocks a physical-interface bypass while TUN traffic still works. It also checks IPv6 bypass when the uplink offers IPv6. This starts a fresh four-minute trial.
5. Run `proxyctl system keep` after trying the applications during the PF trial. This records the verified profile and keeps the tunnel and PF running.

## Lifecycle

| Console command | Shell command | Effect |
| --- | --- | --- |
| `/system start` | `proxyctl start` | Verify and start the system proxy and independent PF |
| `/system apply` | `proxyctl system apply` | Retry applying saved group and routing changes under PF protection |
| `/system stop` | `proxyctl stop` | Stop the system tunnel and remove its PF rules and DNS entry for this boot |
| `/system enable` | `proxyctl enable` | Register the verified system proxy as a system LaunchDaemon for future boots |
| `/system disable` | `proxyctl disable` | Remove its boot registration |
| `/system rollback` | `proxyctl system rollback` | Undo deployment, verification, and startup at boot |

Use `/status` or `proxyctl system status` for the deployment, active tunnel, PF, and boot registration state. A confirmed deployment passed the timed trial. A stopped deployment that passed the trial is ready to start again. Use `/groups` to inspect each current member and `/check` to check the active path. Boot registration and current runtime are separate settings. The launchd job can start without an account login after the physical route is available. [Apple launchd jobs](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)

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
