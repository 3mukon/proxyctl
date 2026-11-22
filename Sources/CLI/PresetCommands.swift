import Foundation

func outboundOptions(nodeNames: [String], groupNames: [String] = [], hasUpstream: Bool, proxyOnly: Bool = false) -> [RuleTarget] {
    let common: [RuleTarget] = proxyOnly ? [.proxy] : (hasUpstream ? [.direct, .proxy, .upstream] : [.direct, .proxy])
    return common + groupNames.map(RuleTarget.group) + nodeNames.map(RuleTarget.node)
}

func chooseTarget(nodeNames: [String], groupNames: [String] = [], hasUpstream: Bool, proxyOnly: Bool = false) throws -> RuleTarget? {
    let available = outboundOptions(nodeNames: nodeNames, groupNames: groupNames, hasUpstream: hasUpstream, proxyOnly: proxyOnly)
    for (index, target) in available.enumerated() {
        print("  \(index + 1). \(target.displayName)")
    }
    print(localized("输入编号。直接回车返回。", "Choose a number or press Enter to go back."))
    guard let line = readLine(), !line.isEmpty else { return nil }
    guard let number = Int(line), number > 0, number <= available.count else {
        throw UserError(localized("请使用列表中的编号。", "Choose a number from the list."))
    }
    return available[number - 1]
}

@discardableResult
func editLocalPolicy(_ paths: Paths, change: (inout Routing, ManagedProfile) throws -> Void) throws -> Routing {
    try paths.locked {
        guard FileManager.default.fileExists(atPath: paths.config.path) else {
            throw UserError(localized("请先用 \(commandExample("nodes add")) 添加节点。", "Add a node with \(commandExample("nodes add"))."))
        }
        let config = try loadObject(localData(paths.config))
        let profile = try ManagedProfile(config)
        var edited = profile.routing
        try change(&edited, profile)
        if edited != profile.routing {
            try writeRoutingProfile(config, routing: edited, paths: paths)
            try syncRoutingPolicy(ManagedProfile(paths.config), paths: paths)
        } else {
            try syncRoutingPolicy(profile, paths: paths)
        }
        return edited
    }
}

func managePresets(_ args: [String], _ paths: Paths) throws {
    let collections = (try? ManagedProfile(paths.config).routing.collections) ?? RuleCollection.defaults([])
    if args.isEmpty || args == ["--json"] {
        if args == ["--json"] { try printJSON(collections); return }
        for group in collections {
            print("\(group.enabled ? "●" : "○") \(group.title)  →  \(group.target.displayName)")
            for member in group.domains + group.networks { print("  \(member)") }
        }
        print(commandExample("presets edit"))
        print(commandExample("presets route"))
        return
    }
    if args == ["edit"] {
        try presetWizard(collections, paths: paths)
        return
    }
    guard args.count >= 2 else { throw RuleCollection.invalid }
    let action = args[0], name = args[1]
    if action == "route", args.count == 2, tty {
        let profile = try ManagedProfile(paths.config)
        guard let index = RuleCollection.index(matching: name, in: collections) else {
            throw UserError(localized("未找到该预设。", "Preset not found."))
        }
        let group = collections[index]
        if let target = try chooseTarget(nodeNames: profile.nodes.map(\.name), groupNames: profile.routing.groupNames,
                                         hasUpstream: profile.upstream != nil,
                                         proxyOnly: group.builtIn) {
            try managePresets(["route", group.name, target.rawValue], paths)
        }
        return
    }
    let edited = try editLocalPolicy(paths) { routing, profile in
        if action == "create" {
            let target = args.count == 2 ? .proxy : RuleTarget(rawValue: args[2])
            guard args.count <= 4, RuleCollection.validName(name), let target,
                  !routing.collections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw UserError(localized("请为新预设选择唯一名称和出站。", "Choose a unique name and outbound for the new preset."))
            }
            let resolved = try target.resolved(in: profile.nodes.map(\.name), groups: routing.groupNames)
            var group = RuleCollection(name: name, target: resolved, enabled: true, domains: [], networks: [])
            if args.count == 4 { try group.edit(args[3], add: true) }
            routing.collections.append(group)
            return
        }
        guard let index = RuleCollection.index(matching: name, in: routing.collections) else {
            throw UserError(localized("未找到该预设。", "Preset not found."))
        }
        switch (action, args.count) {
        case ("enable", 2), ("disable", 2):
            routing.collections[index].enabled = action == "enable"
        case ("add", 3), ("remove", 3):
            try routing.collections[index].edit(args[2], add: action == "add")
        case ("route", 3):
            guard let target = RuleTarget(rawValue: args[2]) else {
                throw UserError(localized("请选择已配置的出口。", "Choose a configured outbound."))
            }
            if routing.collections[index].builtIn && !target.usesManagedProxy {
                throw UserError(localized("此预设需要选择一个代理组或节点。",
                                          "This preset needs a proxy group or node."))
            }
            routing.collections[index].target = try target.resolved(in: profile.nodes.map(\.name), groups: routing.groupNames)
        case ("delete", 2):
            guard !routing.collections[index].builtIn else {
                throw UserError(localized("内置预设可停用或编辑。", "Built-in presets support disabling and member edits."))
            }
            routing.collections.remove(at: index)
        default:
            let example = commandExample("presets edit")
            throw UserError(localized("使用 \(example) 查看编辑选项。", "Open \(example) for editing options."))
        }
    }
    let group = RuleCollection.index(matching: name, in: edited.collections).map { edited.collections[$0] }
    if ["enable", "disable"].contains(action), let group {
        let state = action == "enable" ? localized("已启用", "enabled") : localized("已停用", "disabled")
        print(localized("预设", "Preset") + " \(group.title) · \(state)")
    } else if action == "delete" {
        print(localized("预设已删除。", "Preset deleted."))
    } else if action == "route", let group {
        print("\(group.title)  →  \(group.target.displayName)")
    } else {
        print(localized("预设已保存。", "Preset saved."))
    }
}

private func presetWizard(_ groups: [RuleCollection], paths: Paths) throws {
    let profile = try ManagedProfile(paths.config)
    for (index, group) in groups.enumerated() {
        print("  \(index + 1). \(group.title) · \(group.target.displayName)")
    }
    print(localized("  0. 新建预设", "  0. New preset"))
    print(localized("选择编号。直接回车返回。", "Choose a number or press Enter to go back."))
    guard let line = readLine(), !line.isEmpty else { return }
    guard let number = Int(line), number >= 0, number <= groups.count else { throw RuleCollection.invalid }
    if number == 0 {
        print(localized("输入预设名称。", "Enter a preset name."))
        guard let name = readLine(), !name.isEmpty,
              let target = try chooseTarget(nodeNames: profile.nodes.map(\.name), groupNames: profile.routing.groupNames,
                                            hasUpstream: profile.upstream != nil) else { return }
        print(localized("输入第一个域名或 IP/CIDR。回车可保存空集合。", "Enter the first domain or IP/CIDR, or save an empty preset with Enter."))
        guard let first = readLine() else { return }
        let member = first.isEmpty ? [] : [first]
        try managePresets(["create", name, target.rawValue] + member, paths)
        return
    }
    let group = groups[number - 1]
    let members = group.domains + group.networks
    print(localized("  0. 更改出口", "  0. Change outbound"))
    for (index, value) in members.enumerated() { print("  \(index + 1). \(value)") }
    print(localized("输入域名或 IP/CIDR 添加。输入已有成员编号移除。回车返回。", "Enter a domain or IP/CIDR to add it. Enter a member number to remove it. Enter goes back."))
    guard let value = readLine(), !value.isEmpty else { return }
    if value == "0" {
        try managePresets(["route", group.name], paths)
    } else if let index = Int(value), index > 0, index <= members.count {
        try managePresets(["remove", group.name, members[index - 1]], paths)
    } else {
        try managePresets(["add", group.name, value], paths)
    }
}
