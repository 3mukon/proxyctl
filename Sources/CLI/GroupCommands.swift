import Foundation

struct GroupInventory: Encodable {
    let defaultOrder: [String]
    let defaultMember: String?
    let groups: [ProxyGroupStatus]
    let system: Bool
    let pending: Bool

    init(_ paths: Paths, active: ProtectionStatus?) {
        let local = try? Engine(paths)
        let profile = local?.profile
        let order = active?.order ?? profile?.order ?? []
        let selected = active == nil ? try? local?.current() : active?.selectedNode
        let entries = active == nil
            ? (local?.groupStatus(running: selected != nil) ?? [])
            : (active?.groups ?? [])
        defaultOrder = order
        defaultMember = selected
        groups = entries
        system = active != nil
        pending = active != nil && profile.map { profile in
            let deployed = entries.map { ProxyGroup(name: $0.name, order: $0.order) }
            return deployed != profile.routing.groups || order != profile.order
        } == true
    }
}

func manageGroups(_ args: [String], _ paths: Paths) throws {
    if args == ["edit"], tty {
        try groupWizard(paths)
        return
    }
    if args.isEmpty || args == ["--json"] {
        let active = protectedConsoleStatus(paths, ProtectedService.installedStatus())
        let inventory = GroupInventory(paths, active: active)
        if args == ["--json"] { try printJSON(inventory); return }
        if inventory.defaultOrder.isEmpty {
            print(localized("请先用 proxyctl nodes add 添加节点。", "Add a node with proxyctl nodes add first."))
            return
        }
        for (name, order, current) in [(RuleTarget.proxy.displayName, inventory.defaultOrder, inventory.defaultMember)] +
            inventory.groups.map({ (terminalText($0.name), $0.order, $0.selectedNode) }) where !order.isEmpty {
            let members = order.map(terminalText).joined(separator: " → ")
            print("\(name)  \(members)" + (current.map { "  ● " + terminalText($0) } ?? ""))
        }
        if inventory.pending {
            print(localized("本机代理组与系统配置不同。", "Local groups differ from the system profile."))
        }
        return
    }
    if args.starts(with: ["default"]), args.count >= 2 {
        let order = try saveDefaultGroup(Array(args.dropFirst()), paths: paths)
        print(localized("默认代理组已保存", "Default proxy group saved") + " · " + order.map(terminalText).joined(separator: " → "))
        try paths.locked {
            try syncRoutingPolicy(ManagedProfile(paths.config), paths: paths, includeDefaultOrder: true)
        }
        return
    }
    guard args.count >= 2, let action = args.first else { throw groupUsage() }
    let name = args[1]
    let checked = ["_set", "_remove"].contains(action)
    guard !checked || args.count >= 3 else { throw groupUsage() }
    let values = args.dropFirst(checked ? 3 : 2)
    let remove = ["remove", "_remove"].contains(action)
    guard (remove && values.isEmpty) || (["set", "_set"].contains(action) && !values.isEmpty) else {
        throw groupUsage()
    }
    try editLocalPolicy(paths) { routing, profile in
        if checked, args[2] != (try routing.policy.revision()) {
            throw UserError(localized("代理组或分流已更新。请返回并重新打开编辑。",
                                      "Groups or routing changed. Go back and reopen the editor."))
        }
        let index = routing.groups.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if remove {
            guard let index else {
                throw UserError(localized("未找到该代理组。", "Proxy group not found."))
            }
            routing.groups.remove(at: index)
        } else {
            let order = try Profile.order(Array(values), among: profile.nodes.map(\.name))
            let group = ProxyGroup(name: index.map { routing.groups[$0].name } ?? name, order: order)
            if let index { routing.groups[index] = group }
            else { routing.groups.append(group) }
        }
    }
    print(remove ? localized("代理组已删除。", "Proxy group deleted.") : localized("代理组已保存。", "Proxy group saved."))
}

private func groupUsage() -> UserError {
    let set = commandExample("groups set NAME NODE...")
    let remove = commandExample("groups remove NAME")
    return UserError(localized("使用 \(set) 或 \(remove)。", "Use \(set) or \(remove)."))
}

private func groupWizard(_ paths: Paths) throws {
    let raw = try loadObject(localData(paths.config))
    let local = try ManagedProfile(raw)
    let groups = local.routing.groups
    print("  1. " + RuleTarget.proxy.displayName)
    for (index, group) in groups.enumerated() { print("  \(index + 2). \(terminalText(group.name))") }
    print(localized("  0. 新建代理组", "  0. New proxy group"))
    print(localized("输入编号，直接回车返回。", "Choose a number or press Enter to go back."))
    guard let input = readLine(), !input.isEmpty else { return }
    guard let choice = Int(input), (0...(groups.count + 1)).contains(choice) else { throw groupUsage() }
    let source = try Profile(raw)
    if choice == 1 {
        try manageGroups(["default"] + awaitOrder(source, currentOrder: local.order), paths)
    } else if choice == 0 {
        print(localized("输入代理组名称。", "Enter a proxy group name."))
        guard let name = readLine(), !name.isEmpty else { return }
        guard ProxyGroup.validName(name), Profile.matchingName(name, in: local.routing.groupNames) == nil else {
            throw ProxyGroup.invalid
        }
        try manageGroups(["_set", name, local.routing.policy.revision()] + awaitOrder(source), paths)
    } else {
        let group = groups[choice - 2]
        try manageGroups(["_set", group.name, local.routing.policy.revision()] + awaitOrder(source, currentOrder: group.order), paths)
    }
}
