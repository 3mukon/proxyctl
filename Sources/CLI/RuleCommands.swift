import Foundation

private func ruleUsage() -> UserError {
    let example = commandExample("rules add|remove DOMAIN_OR_CIDR proxy|direct|upstream|node:NAME")
    return UserError(localized("使用 \(example)", "Use \(example)"))
}

private func showRules(_ args: [String], profile: ManagedProfile, paths: Paths) throws {
    let rules = try profile.routing.ruleFiles(in: paths.state)?.list() ?? []
    try printRules(rules, json: args == ["--json"], hasUpstream: profile.upstream != nil,
                   fallback: profile.routing.fallback)
}

func manageUpstream(_ args: [String], _ paths: Paths, offerDefault: Bool = true) throws {
    if args.isEmpty && tty {
        _ = try ManagedProfile(paths.config)
        print(localized("输入独立代理的地址，例如 socks5://host:1080。回车返回。",
                        "Enter an independent proxy URL, such as socks5://host:1080. Enter goes back."))
        guard let url = readLine(), !url.isEmpty else { return }
        _ = try Upstream(url: url)
        if !offerDefault {
            try manageUpstream([url], paths)
            return
        }
        print(localized("  1. 将其余全部交给此外部代理\n  2. 仅保存代理地址",
                        "  1. Use this external proxy for everything else\n  2. Save the endpoint only"))
        guard let choice = readLine(), !choice.isEmpty else { return }
        guard ["1", "2"].contains(choice) else { throw ruleUsage() }
        try manageUpstream(choice == "1" ? [url, "--default"] : [url], paths)
        return
    }
    try paths.locked {
        var config = try loadObject(localData(paths.config))
        let current = try ManagedProfile(config)
        if args.isEmpty {
            if let upstream = current.upstream {
                print(upstream.addressLabel)
            } else { print(localized("外部出站未配置。", "No external upstream is configured.")) }
            print(commandExample(offerDefault ? "rules upstream socks5://HOST:PORT|off" : "setup upstream socks5://HOST:PORT|off"))
            return
        }
        let asDefault = args.count == 2 && args.last == "--default"
        guard (args.count == 1 || asDefault), let argument = args.first, !(asDefault && argument == "off") else {
            throw ruleUsage()
        }
        if (try? Engine(paths).requireListener()) != nil {
            throw UserError(localized("请先结束 Proxyctl 回环试用，再更改外部出站。", "Stop the Proxyctl loopback proxy before changing the upstream."))
        }
        let next = try argument == "off" ? nil : Upstream(url: argument)
        if next == nil && current.routing.referencesUpstream {
            throw UserError(localized("请先修改使用外部代理的预设或「其余全部」。",
                                      "Change the presets or catch-all that use this upstream first."))
        }
        if next == nil, let files = current.routing.ruleFiles(in: paths.state),
           try files.list().contains(where: { $0.target == .upstream }) {
            throw UserError(localized("请先移除使用 UPSTREAM 的自定义规则。", "Remove custom UPSTREAM rules before clearing the upstream."))
        }
        try next?.validatePorts(current.port, current.controllerPort)
        var outbounds = (config["outbounds"] as? [[String: Any]] ?? []).filter { $0["tag"] as? String != upstreamTag }
        if let next { outbounds.append(next.config) }
        config["outbounds"] = outbounds
        var routing = current.routing
        if asDefault {
            routing.fallback = .upstream
            routing.explicitDefault = true
        }
        try writeRoutingProfile(config, routing: routing, paths: paths)
        print(localized("外部出站设置已保存。", "External upstream settings saved."))
        if protectedConsoleStatus(paths, ProtectedService.installedStatus()) != nil {
            print(localized("新的外部代理地址需重新部署系统配置后才生效。",
                            "Deploy the system profile again to apply the new external proxy address."))
        }
        if asDefault { print(catchAllLine(.upstream)) }
    }
}

private func applyLocalRules(_ args: [String], paths: Paths) throws {
    let config = try loadObject(localData(paths.config))
    let profile = try ManagedProfile(config)
    if args.isEmpty || args == ["--json"] {
        try showRules(args, profile: profile, paths: paths)
        return
    }
    let change = try RuleChange(args, hasUpstream: profile.upstream != nil, nodeNames: profile.nodes.map(\.name))
    if let files = profile.routing.ruleFiles(in: paths.state), files.supports(change.rule.target) {
        try files.update(change)
    } else if change.add {
        try writeRoutingProfile(config, routing: profile.routing, paths: paths).update(change)
    }
    print(ruleChangeMessage(change))
}

private func manageDefault(_ args: [String], paths: Paths) throws {
    if args.count == 2 && args.first?.lowercased() == "upstream" {
        try manageUpstream([args[1], "--default"], paths)
        return
    }
    let profile = try ManagedProfile(paths.config)
    if args == ["--json"] {
        try printJSON(profile.routing.fallback)
        return
    }
    if args.isEmpty {
        print(catchAllLine(profile.routing.fallback))
        if tty {
            if let target = try chooseTarget(nodeNames: profile.nodes.map(\.name), hasUpstream: profile.upstream != nil) {
                try manageDefault([target.rawValue], paths: paths)
            }
        } else {
            let targets = profile.upstream == nil ? "direct|proxy|node:NAME" : "direct|proxy|upstream|node:NAME"
            print(commandExample("rules default \(targets)"))
        }
        return
    }
    guard args.count == 1, let target = RuleTarget(rawValue: args[0]) else {
        throw UserError(localized("请选择其余流量的出站。", "Choose an outbound for the remaining traffic."))
    }
    let updated = try editLocalPolicy(paths) { routing, profile in
        routing.fallback = try target.resolved(in: profile.nodes.map(\.name))
        routing.explicitDefault = true
    }
    print(catchAllLine(updated.fallback))
}

func promptForRule(nodeNames: [String], hasUpstream: Bool) throws -> [String]? {
    print(localized("输入域名或 IP/CIDR。直接回车返回。", "Enter a domain or IP/CIDR. Press Enter to go back."))
    guard let match = readLine(), !match.isEmpty,
          let target = try chooseTarget(nodeNames: nodeNames, hasUpstream: hasUpstream) else { return nil }
    return ["add", match, target.rawValue]
}

func rules(_ args: [String], _ paths: Paths) throws {
    if args.first == "upstream" {
        try manageUpstream(Array(args.dropFirst()), paths)
    } else if args.first == "default" {
        try manageDefault(Array(args.dropFirst()), paths: paths)
    } else if args == ["add"], tty {
        let profile = try ManagedProfile(paths.config)
        if let change = try promptForRule(nodeNames: profile.nodes.map(\.name), hasUpstream: profile.upstream != nil) {
            try rules(change, paths)
        }
    } else {
        if !FileManager.default.fileExists(atPath: paths.config.path) {
            throw UserError(localized("请先运行 \(commandExample("setup")) 导入节点。", "Import nodes with \(commandExample("setup"))."))
        }
        try paths.locked { try applyLocalRules(args, paths: paths) }
    }
}
