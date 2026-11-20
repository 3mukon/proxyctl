---
id: DOC-mod-cli
type: doc
title: Terminal interface
status: current
visibility: public
date: 2026-11-17
summary: Provide the interactive console, diagnostics, and scripting interface.
scope: ["Sources/CLI/**"]
tags: []
---

## Responsibilities

Parse arguments, display local state, and dispatch commands. `Console.swift` draws a black overview, fixed result pages, and a framed composer. The overview places node information beside shortcuts in wide windows and stacks them in narrow ones. Command results use a shared title, aligned content, and compact borders in roomy terminals. Status labels sit beside their values. Tables adapt to narrower windows and repeat their headings on each page. Guided forms share the result panel's heading and inset. Prompts and choices appear together, and choices paginate as the selection moves. Result shortcuts use aligned command and description columns. Shortcut hints sit a few spaces after the current input. The overview and command pages align their headings along the same inset and show the application name and version at the right. Opening the command menu raises the content before drawing the overlay. The composer shows system capture and PF status along its lower edge. The terminal supplies the font family and size. The console uses bold headings and muted supporting text. `Terminal.swift` and `terminal_support.c` handle input, terminal size, and restoration. Preset and proxy group editing, node imports, rule entry, and external proxy setup use the full-screen input and picker. The console dispatches the completed operation to the scripting executable. Administrator authentication uses native terminal input within the full-screen buffer. Basic terminals use the same command list through the libedit line console.

## Non-responsibilities

Node extraction belongs to Profiles. Network control belongs to Host.

## Public interface

In the console, `/` opens the daily command list over the current page. Enter or Tab inserts the selected item and a space, then shows any next choices. Use the arrow keys to select a next choice. Press Esc to go back one layer. It first clears a highlighted choice, then hides command suggestions while keeping the draft. If the draft still requires a choice, Enter restores the last highlighted option in the same list. With suggestions closed, Esc backs up one argument or clears the final command. Tab reopens suggestions. In guided forms, Esc clears the selection, clears any active input, then returns to the previous step. Esc from an idle result returns to the overview. Left and Right turn result pages when the input is empty. Up and Down browse recent commands when the list is closed.

The slash menu matches the beginning of a top-level command name. A space after a recognized command opens its own subcommands or argument choices. After selecting a subcommand, completion continues with its arguments. A final selection fills the input. Press Enter to run the completed command. Completing `node` in `/check node` shows all locally imported nodes. Completing `edit` in `/presets edit` shows existing presets and **New preset**. Esc backs out of the editor to that list. Guided rule entry returns to the same outbound picker used when typing a rule. System rule removal may require administrator authentication to read the rules before showing the choices.

Use `/nodes add` for copied links. Use `/nodes group` to edit the local default group's membership and priority. Use `/presets edit` for preset collections. Use `/rules` to list custom rules or `/rules remove` to pick and remove one. Choose where unmatched traffic goes with `/rules default`. View, change, or clear an external proxy address with `/setup upstream`. The console also prompts for an address when you first choose an external proxy for unmatched traffic. Use `/setup import` to import a sing-box JSON file. Open `/help` for one command catalog with each subcommand listed under its parent, plus keyboard shortcuts. Use `/presets route` to choose a preset's outbound with the same node search as the rule picker. `/use` selects the default group's current member. Use `/status` for system capture, PF protection, and startup at boot. `/system` shows the current state and offers `start`, `stop`, `enable`, `disable`, and `rollback`. Use `/system start` after setting nodes and routing. It handles preparation, timed TUN verification, and independent PF verification. Pause any competing system VPN manually when prompted. Complete administrator authentication in the console. Use `/system stop` for the current session and `/system rollback` to clear deployment verification and startup at boot. Use `/check` for a quick check or `/check node` to pick an imported node. Use `/lang zh` or `/lang en` to save the display language. Run `proxyctl help` for shell commands. `status --json` and `nodes --json` provide machine-readable output.

When starting from a local profile with another VPN active, the console probes the default group, pinned nodes, and the external proxy if the routing policy uses one. A successful check leads to the pause prompt. Press Enter to continue after the pause.

The rule table shows the active catch-all and any pending change. The preset table identifies the active policy or marks pending changes. Saving presets or the catch-all applies the changes automatically when the protected service supports it. Complete administrator authentication in the terminal when prompted. Use `/system apply` to sync pending settings manually or retry a failed application.

## Allowed dependencies

`Profiles`, `Host`, and macOS system libraries.
