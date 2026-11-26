import Darwin
import Foundation

struct Node: Codable, Equatable {
    let name: String
    let protocolName: String
    let endpoint: String
}

struct Inventory: Codable {
    let source: String
    let nodes: [Node]
}

struct Profile {
    static let proxyTypes: Set<String> = [
        "anytls", "http", "hysteria", "hysteria2", "naive", "shadowsocks", "shadowtls",
        "snell", "socks", "ssh", "trojan", "tuic", "vless", "vmess"
    ]
    let outbounds: [[String: Any]]
    let nodes: [Node]

    init(_ raw: [String: Any]) throws {
        guard let outbounds = raw["outbounds"] as? [[String: Any]] else {
            throw UserError(localized("配置中没有 outbounds。请选择 sing-box 客户端 JSON。", "Choose a sing-box client JSON file with an outbounds array."))
        }
        self.outbounds = outbounds
        nodes = outbounds.compactMap { entry in
            guard let type = entry["type"] as? String, Self.proxyTypes.contains(type),
                  let name = entry["tag"] as? String, Self.validName(name),
                  let host = entry["server"] as? String, !host.isEmpty else { return nil }
            return Node(name: name, protocolName: type, endpoint: Self.family(host))
        }
        guard !nodes.isEmpty else { throw UserError(localized("没有找到可管理的代理节点。", "No supported proxy nodes were found.")) }
        guard Set(nodes.map(\.name)).count == nodes.count else {
            throw UserError(localized("存在重复节点名。请先在来源配置中为各节点使用唯一名称。", "Assign unique names to the nodes in your source configuration."))
        }
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 160 && terminalText(name) == name &&
        !name.contains("/") && name == name.trimmingCharacters(in: .whitespacesAndNewlines) &&
        ![selectorTag, directTag, upstreamTag].contains(name)
    }

    static func family(_ host: String) -> String {
        var ip4 = in_addr()
        var ip6 = in6_addr()
        if inet_pton(AF_INET, host, &ip4) == 1 { return "IPv4" }
        if inet_pton(AF_INET6, host, &ip6) == 1 { return "IPv6" }
        return "域名"
    }

    static func matchingName(_ name: String, in names: [String]) -> String? {
        if let exact = names.first(where: { $0 == name }) { return exact }
        let matches = names.filter { $0.caseInsensitiveCompare(name) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }

    func order(_ names: [String]) throws -> [String] {
        try Self.order(names, among: nodes.map(\.name))
    }

    static func order(_ names: [String], among available: [String]) throws -> [String] {
        let selected = try names.map { name in
            guard let matched = Self.matchingName(name, in: available) else {
                throw UserError(localized("无法唯一匹配所选节点。请使用列表里的完整名称。", "Use the full node name from the list."))
            }
            return matched
        }
        guard !selected.isEmpty, Set(selected).count == selected.count else {
            throw UserError(localized("请至少选择一个节点，每个节点只添加一次。", "Choose at least one node. Select each node once."))
        }
        return selected
    }

    var groups: [String] {
        outbounds.compactMap { entry in
            guard let name = entry["tag"] as? String, Self.validName(name),
                  ["selector", "urltest"].contains(entry["type"] as? String ?? ""),
                  (try? importedGroup(name)) != nil else { return nil }
            return name
        }
    }

    func importedGroup(_ name: String) throws -> [String] {
        let groups = outbounds.filter { $0["tag"] as? String == name && ["selector", "urltest"].contains($0["type"] as? String ?? "") }
        guard groups.count == 1, let names = groups.first?["outbounds"] as? [String] else {
            throw UserError(localized("未找到指定的代理组。", "The requested proxy group was not found."))
        }
        return try order(names)
    }

    func explicitUpstream(_ name: String) throws -> Upstream {
        let names = try order([name])
        guard let entry = outbounds.first(where: { $0["tag"] as? String == names[0] }) else {
            throw UserError(localized("未找到指定上游。", "The requested upstream was not found."))
        }
        return try Upstream(entry)
    }

    func managed(order names: [String], port: Int, controllerPort: Int, routing: Routing,
                 upstream: Upstream? = nil) throws -> [String: Any] {
        let selected = try order(names)
        try upstream?.validatePorts(port, controllerPort)
        let known = Set(nodes.map(\.name))
        let candidates = outbounds.filter { item in
            guard let tag = item["tag"] as? String, let type = item["type"] as? String else { return false }
            return known.contains(tag) && Self.proxyTypes.contains(type)
        }
        guard candidates.count == nodes.count else { throw UserError(localized("配置中有冲突的出站标签。", "The source configuration has conflicting outbound tags.")) }
        var outbound = try candidates.map { candidate -> [String: Any] in
            var copy = candidate
            if let detour = copy["detour"] as? String, !detour.isEmpty, !known.contains(detour) {
                throw UserError(localized("节点依赖额外出站或策略组。本版需要独立代理节点或节点之间的链路。", "Choose standalone proxy nodes or chains between imported nodes."))
            }
            // Trial dials follow the operating system's current path.
            for key in ["bind_interface", "inet4_bind_address", "inet6_bind_address", "routing_mark", "netns", "domain_resolver"] {
                copy.removeValue(forKey: key)
            }
            return copy
        }
        outbound.append(ProxyGroup.selector(tag: selectorTag, order: selected))
        outbound.append(["type": "direct", "tag": directTag])
        if let upstream { outbound.append(upstream.config) }
        let secret = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
        var config: [String: Any] = [
            "log": ["level": "warn", "timestamp": true, "output": "engine.log"],
            "inbounds": [["type": "mixed", "tag": "local-proxy", "listen": "127.0.0.1", "listen_port": port]],
            "outbounds": outbound,
            "experimental": [
                "cache_file": ["enabled": true, "path": "selection.db", "cache_id": UUID().uuidString],
                "clash_api": ["external_controller": "127.0.0.1:\(controllerPort)", "secret": secret]
            ]
        ]
        try routing.apply(to: &config)
        return config
    }
}

struct ManagedProfile {
    let nodes: [Node]
    let order: [String]
    let port: Int
    let controllerPort: Int
    let secret: String
    let routing: Routing
    let upstream: Upstream?

    func order(for target: RuleTarget) -> [String] {
        if target == .proxy { return order }
        return routing.groups.first { $0.target == target }?.order ?? []
    }

    init(_ path: URL) throws {
        try self.init(loadObject(localData(path)))
    }

    init(_ raw: [String: Any], system: Bool = false) throws {
        let profile = try Profile(raw)
        let inbounds = raw["inbounds"] as? [[String: Any]] ?? []
        let experiment = raw["experimental"] as? [String: Any]
        let api = experiment?["clash_api"] as? [String: Any]
        let control = api?["external_controller"] as? String
        let secretChars = CharacterSet(charactersIn: "0123456789abcdef-")
        guard inbounds.count == (system ? 2 : 1), inbounds[0]["type"] as? String == "mixed",
              inbounds[0]["listen"] as? String == "127.0.0.1", let port = inbounds[0]["listen_port"] as? Int,
              let control, control.hasPrefix("127.0.0.1:"), let controllerPort = Int(control.dropFirst("127.0.0.1:".count)),
              validPorts(port, controllerPort), let secret = api?["secret"] as? String,
              secret.count == 72, secret.unicodeScalars.allSatisfy(secretChars.contains),
              raw["endpoints"] == nil, raw["services"] == nil,
              profile.outbounds.contains(where: { $0["tag"] as? String == directTag && $0["type"] as? String == "direct" }),
              let group = profile.outbounds.first(where: { $0["tag"] as? String == selectorTag }),
              group["type"] as? String == "selector", let order = group["outbounds"] as? [String],
              try profile.order(order) == order else {
            throw UserError(localized("本机配置不是 Proxyctl 生成的回环代理。请重新导入节点。", "Import the nodes again to create a Proxyctl loopback profile."))
        }
        nodes = profile.nodes
        self.order = order
        self.port = port
        self.controllerPort = controllerPort
        self.secret = secret
        routing = try Routing(raw, nodeNames: profile.nodes.map(\.name))
        upstream = try profile.outbounds.first(where: { $0["tag"] as? String == upstreamTag }).map(Upstream.init)
        try upstream?.validatePorts(port, controllerPort)
        if routing.referencesUpstream && upstream == nil {
            throw UserError(localized("请先配置外部出站。", "Configure an external upstream first."))
        }
    }
}

func validPorts(_ port: Int, _ controller: Int) -> Bool {
    (1024...65535).contains(port) && (1024...65535).contains(controller) && port != controller
}

private func writeProfile(_ data: Data, using paths: Paths, requireFreePorts: Bool) throws {
    let candidate = paths.state.appendingPathComponent("candidate-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: candidate) }
    try savePrivate(data, to: candidate)
    let preview = try ManagedProfile(candidate)
    if requireFreePorts && (hasListener(port: preview.port) || hasListener(port: preview.controllerPort)) {
        throw UserError(localized("预览端口已被占用。可以继续使用 1082 上的现有代理并选择另一个试用端口。", "A preview port is in use. Choose an available port."))
    }
    try paths.coreCheck(candidate)
    guard rename(candidate.path, paths.config.path) == 0 else { throw UserError(localized("无法保存已通过校验的配置。", "Could not save the validated configuration.")) }
}

func saveDefaultGroup(_ names: [String], paths: Paths, expectedRevision: String? = nil) throws -> [String] {
    try paths.locked {
        guard FileManager.default.fileExists(atPath: paths.config.path) else {
            throw UserError(localized("请先添加节点。", "Add a node first."))
        }
        var config = try loadObject(localData(paths.config))
        let current = try ManagedProfile(config)
        if let expectedRevision, expectedRevision != (try current.defaultOrderRevision()) {
            throw UserError(localized("默认代理组已有更新。按 Esc 返回，再打开编辑。",
                                      "The default proxy group changed. Go back and reopen the editor."))
        }
        let source = try Profile(config)
        let order = try source.order(names)
        guard order != current.order else { return order }
        guard !isCoreListener(port: current.controllerPort, core: paths.core) else {
            throw UserError(localized("结束本机回环诊断后再保存代理组。", "Stop the local loopback diagnostic before saving the group."))
        }
        var outbounds = source.outbounds
        guard let selector = outbounds.firstIndex(where: { $0["tag"] as? String == selectorTag }) else {
            throw UserError(localized("本机配置缺少默认代理组。", "The local profile has no default proxy group."))
        }
        outbounds[selector]["outbounds"] = order
        outbounds[selector]["default"] = order[0]
        config["outbounds"] = outbounds
        try writeProfile(jsonData(config), using: paths, requireFreePorts: false)
        return order
    }
}

@discardableResult
func writeRoutingProfile(_ routing: Routing, nodes: [Node], paths: Paths, requireFreePorts: Bool = true,
                         build: (Routing) throws -> [String: Any]) throws -> RuleFiles {
    let names = nodes.map(\.name)
    let previous = routing.ruleFiles(in: paths.state)
    if let previous, previous.nodeNames == names, previous.groupNames == routing.groupNames {
        try writeProfile(jsonData(build(routing)), using: paths, requireFreePorts: requireFreePorts)
        return previous
    }

    let id = UUID()
    var updated = routing
    updated.rulesID = id
    updated.ruleNodes = names
    updated.ruleGroups = routing.groupNames
    let files = RuleFiles(state: paths.state, id: id, nodeNames: names, groupNames: routing.groupNames)
    try files.create(previous?.list() ?? [])
    do {
        try writeProfile(jsonData(build(updated)), using: paths, requireFreePorts: requireFreePorts)
    } catch {
        try? FileManager.default.removeItem(at: files.directory)
        throw error
    }
    if let previous { try? FileManager.default.removeItem(at: previous.directory) }
    return files
}

@discardableResult
func writeRoutingProfile(_ original: [String: Any], routing: Routing, paths: Paths) throws -> RuleFiles {
    if let current = try? ManagedProfile(paths.config), isCoreListener(port: current.controllerPort, core: paths.core) {
        throw UserError(localized("结束本机回环诊断后再保存出口设置。",
                                  "Stop the local loopback diagnostic before saving outbound settings."))
    }
    let source = try Profile(original)
    return try writeRoutingProfile(routing, nodes: source.nodes, paths: paths, requireFreePorts: false) { routing in
        var config = original
        try routing.apply(to: &config)
        return config
    }
}
