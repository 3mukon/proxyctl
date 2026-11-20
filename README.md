# Proxyctl

A system proxy and firewall for macOS. The system TUN sends public traffic to the bundled sing-box. Its rules can use direct forwarding, the default proxy group, a specified node, or an optional external proxy. The independent PF guard blocks bypass. The release requires Apple Silicon and macOS 26 or later.

## Getting started

Run `sh install.sh` from the release directory. Enter `proxyctl` to open the full-screen console. Type `/` for daily commands. Use Up and Down to select a match. Enter or Tab inserts the selection and a space and shows any next options. With no highlighted row, Enter runs a complete command. When a required choice is pending, Enter restores the previous highlight in the same list. Use `/help` for the command catalog and shortcuts. A space after `/use` opens search for the default proxy group. Press Esc to go back one layer at a time through selections, suggestions, input, or the current page. Use Left and Right when results span multiple pages.

Use `/lang` to choose Simplified Chinese or English and `/quit` to leave the console. Both are in the daily command list.

1. Copy a node link and choose `/nodes add`. For a sing-box client file, use `proxyctl setup ~/Downloads/sing-box.json` and select nodes in priority order. Both import methods enable the Claude and OpenAI presets for new profiles.
2. Choose `/check` to verify the first configured node before changing system routing.
3. Follow the [system trial](docs/operations.md#system-trial) to validate the TUN and firewall with timed offline rollback. Use `/status` to see whether the system tunnel and PF are running.

Use `/nodes group` to edit the existing default proxy group. Unmatched traffic uses DIRECT initially. Claude and OpenAI follow the default proxy group until you choose a node for either preset under `/presets route`. Choose a node for a single rule with `/rules add`, or for unmatched traffic with `/rules default`.

## Commands

| Command | Purpose |
| --- | --- |
| `proxyctl` | Open the console |
| `proxyctl status` | Show the system tunnel, firewall, and current node |
| `proxyctl nodes` | List nodes, protocols, entry address types, and priority |
| `proxyctl nodes group NODE...` | Set the local default group's members in priority order |
| `proxyctl presets` | Show available domain presets and their current settings |
| `proxyctl rules` | List, add, and remove custom routing rules |
| `proxyctl check` | Verify the running system path or probe the first configured node |
| `proxyctl check node NODE` | Check an imported node in isolation |
| `proxyctl test 'node name'` | Test HTTPS reachability through the named node |
| `proxyctl use 'node name'` | Test and select a node for the default proxy group |
| `proxyctl use --auto` | Use the first reachable node in the default group's priority order |
| `proxyctl doctor` | Show the bundled engine version and validate the configuration |
| `proxyctl logs` | Show recent engine logs |
| `proxyctl system` | Show system TUN, trial, rollback, and node commands |
| `proxyctl system apply` | Apply saved presets and the catch-all to the running system proxy |
| `proxyctl firewall status` | Show the product's independent PF status |
| `proxyctl start` / `proxyctl stop` | Start or stop the verified system proxy now |
| `proxyctl enable` / `proxyctl disable` | Change whether the verified system proxy starts at boot |

Switching the default group affects new connections assigned to that group. Healthy established connections and routes assigned to specific nodes keep their paths. The engine remembers the group's selection. `check`, `test`, and `use` use Google's `generate_204` endpoint by default to test reachability.

On an updated protected deployment, saved preset and catch-all edits apply automatically. The system engine restarts under PF protection and verifies the new path. A failed update restores the previous policy. Use `/system apply` to apply a pending policy on an earlier running deployment.

Separate launchd jobs run the TUN engine and PF supervisor. Complete the timed TUN and PF trials to verify the deployment before enabling boot startup.

## Development

`sh scripts/build.sh` produces `.build/release/` and requires Apple Command Line Tools. The build obtains the pinned engine release from SagerNet and verifies its SHA-256 before packaging. For an offline build, pass the path to the official archive as an argument. The package includes the engine version, license, and source link.

`sh scripts/check.sh` builds the release and runs isolated end-to-end tests on the Mac. Start with the [documentation index](docs/INDEX.md).
