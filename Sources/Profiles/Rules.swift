import CryptoKit
import Darwin
import Foundation

enum RuleTarget: Hashable, RawRepresentable, Codable {
    case proxy, upstream, direct
    case node(String)

    static let standard: [RuleTarget] = [.proxy, .upstream, .direct]

    init?(rawValue: String) {
        switch rawValue.lowercased() {
        case "proxy": self = .proxy
        case "upstream": self = .upstream
        case "direct": self = .direct
        default:
            guard rawValue.prefix(5).lowercased() == "node:" else { return nil }
            let name = String(rawValue.dropFirst(5))
            guard Profile.validName(name) else { return nil }
            self = .node(name)
        }
    }

    var rawValue: String {
        switch self {
        case .proxy: return "proxy"
        case .upstream: return "upstream"
        case .direct: return "direct"
        case .node(let name): return "node:" + name
        }
    }

    var nodeName: String? {
        if case .node(let name) = self { return name }
        return nil
    }

    var usesManagedNode: Bool { self == .proxy || nodeName != nil }

    // Rule-set identifiers and filenames stay independent of the node's display characters.
    var identifier: String {
        guard let name = nodeName else { return rawValue }
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return "node-" + digest
    }

    func resolved(in names: [String]) throws -> RuleTarget {
        guard let name = nodeName else { return self }
        guard let matched = Profile.matchingName(name, in: names) else {
            throw UserError(localized("请选一个已导入的节点。", "Choose a node from the imported inventory."))
        }
        return .node(matched)
    }

    var displayName: String {
        switch self {
        case .proxy: return localized("默认代理组", "Default proxy group")
        case .upstream: return localized("外部代理", "External upstream")
        case .direct: return localized("直连", "Direct")
        case .node(let name): return localized("节点 · ", "Node · ") + terminalText(name)
        }
    }

    var outbound: String {
        switch self {
        case .proxy: return selectorTag
        case .upstream: return upstreamTag
        case .direct: return directTag
        case .node(let name): return name
        }
    }

    var resolver: String {
        switch self {
        case .proxy: return proxyDNS
        case .upstream: return upstreamDNS
        case .direct: return directDNS
        case .node: return "proxyctl-\(identifier)-dns"
        }
    }
}

enum RuleMatch: String, Codable, CaseIterable {
    case domain = "domain_suffix"
    case network = "ip_cidr"

    init(_ target: String) {
        self = target.contains(":") || target.contains("/") || target.allSatisfy { $0.isNumber || $0 == "." }
            ? .network : .domain
    }

    func normalize(_ raw: String) throws -> String {
        switch self {
        case .domain:
            let lower = raw.lowercased()
            let suffix = lower.hasPrefix("*.") ? String(lower.dropFirst(2)) : lower
            let name = suffix.hasSuffix(".") ? String(suffix.dropLast()) : suffix
            let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
            let labels = name.split(separator: ".", omittingEmptySubsequences: false)
            guard !name.isEmpty, name.utf8.count <= 253, labels.allSatisfy({
                (1...63).contains($0.utf8.count) && $0.first != "-" && $0.last != "-" &&
                    $0.unicodeScalars.allSatisfy(letters.contains)
            }) else { throw Self.invalid }
            return name
        case .network:
            let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let address = parts.first else { throw Self.invalid }
            let family = address.contains(":") ? AF_INET6 : AF_INET
            var octets = [UInt8](repeating: 0, count: family == AF_INET6 ? 16 : 4)
            let width = octets.count * 8
            let prefix = parts.count == 1 ? width : (Int(parts[1]) ?? -1)
            guard (0...width).contains(prefix), inet_pton(family, String(address), &octets) == 1 else {
                throw Self.invalid
            }
            for index in octets.indices {
                let significant = min(8, max(0, prefix - index * 8))
                octets[index] &= UInt8(truncatingIfNeeded: 0xff << (8 - significant))
            }
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(family, &octets, &output, socklen_t(output.count)) != nil else { throw Self.invalid }
            return "\(String(cString: output))/\(prefix)"
        }
    }

    private static var invalid: UserError {
        UserError(localized("请输入域名后缀、IPv4/IPv6 地址或 CIDR。", "Enter a domain suffix, IPv4/IPv6 address, or CIDR."))
    }
}

struct CustomRule: Codable, Equatable, Hashable {
    let match: RuleMatch
    let value: String
    let target: RuleTarget

    init(_ value: String, target: RuleTarget) throws {
        let match = RuleMatch(value)
        self.match = match
        self.value = try match.normalize(value)
        self.target = target
    }
}

struct RuleChange {
    let rule: CustomRule
    let add: Bool

    init(_ args: [String], hasUpstream: Bool, nodeNames: [String]) throws {
        guard args.count == 3, ["add", "remove"].contains(args[0]),
              let parsed = RuleTarget(rawValue: args[2]) else {
            let example = commandExample("rules add|remove DOMAIN_OR_CIDR proxy|direct|upstream|node:NAME")
            throw UserError(localized("使用 \(example)", "Use \(example)"))
        }
        self.add = args[0] == "add"
        let target = try parsed.resolved(in: nodeNames)
        if add && target == .upstream && !hasUpstream {
            throw UserError(localized("请先配置外部出站。", "Configure an external upstream first."))
        }
        self.rule = try CustomRule(args[1], target: target)
    }
}

struct RuleFiles {
    let directory: URL
    let nodeNames: [String]

    init(state: URL, id: UUID, nodeNames: [String] = []) {
        directory = state.appendingPathComponent(Self.folder(id), isDirectory: true)
        self.nodeNames = nodeNames
    }

    static func folder(_ id: UUID) -> String { "rules-\(id.uuidString.lowercased())" }

    static func tag(_ target: RuleTarget, _ match: RuleMatch) -> String {
        "proxyctl-rule-\(target.identifier)-\(match.rawValue)"
    }

    static func targets(_ names: [String], hasUpstream: Bool) -> [RuleTarget] {
        names.map(RuleTarget.node) + (hasUpstream ? RuleTarget.standard : [.proxy, .direct])
    }

    private static func slots(_ targets: [RuleTarget]) -> [(RuleTarget, RuleMatch)] {
        RuleMatch.allCases.flatMap { match in targets.map { ($0, match) } }
    }

    private var slots: [(RuleTarget, RuleMatch)] { Self.slots(Self.targets(nodeNames, hasUpstream: true)) }

    func supports(_ target: RuleTarget) -> Bool {
        target.nodeName.map(nodeNames.contains) ?? true
    }

    static func config(_ id: UUID, targets: [RuleTarget]) -> [[String: String]] {
        slots(targets).map { target, match in
            let name = tag(target, match)
            return ["type": "local", "tag": name, "format": "source", "path": "\(folder(id))/\(name).json"]
        }
    }

    static func layout(in route: [String: Any], nodeNames: [String]) throws -> (id: UUID, nodeNames: [String])? {
        guard let sets = route["rule_set"] else { return nil }
        let invalid = UserError(localized("无法识别本机规则集。", "The local rule sets could not be identified."))
        guard let definitions = sets as? [[String: Any]] else { throw invalid }
        let local = definitions.filter { $0["type"] as? String == "local" }
        if local.isEmpty { return nil }
        guard let files = local as? [[String: String]],
              let path = files.first?["path"],
              let directory = path.split(separator: "/").first, directory.hasPrefix("rules-"),
              let id = UUID(uuidString: String(directory.dropFirst(6))) else { throw invalid }
        for names in [nodeNames, []] {
            if files == config(id, targets: targets(names, hasUpstream: false)) ||
                files == config(id, targets: targets(names, hasUpstream: true)) { return (id, names) }
        }
        throw invalid
    }

    private struct Source: Codable {
        let version: Int
        let rules: [[String: [String]]]
    }

    private func path(_ target: RuleTarget, _ match: RuleMatch) -> URL {
        directory.appendingPathComponent(Self.tag(target, match) + ".json")
    }

    func create(_ rules: [CustomRule] = []) throws {
        let validated = try rules.map { item in
            guard supports(item.target) else {
                throw UserError(localized("请先修改引用已移除节点的单条规则。", "Update single rules that reference removed nodes first."))
            }
            let rule = try CustomRule(item.value, target: item.target)
            guard rule == item else { throw UserError(localized("规则数据无效。", "Invalid rule data.")) }
            return rule
        }
        guard Set(validated).count == validated.count else {
            throw UserError(localized("自定义规则重复。", "Duplicate custom rules."))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let groups = Dictionary(grouping: validated) { Self.tag($0.target, $0.match) }
            for (target, match) in slots {
                let values = groups[Self.tag(target, match), default: []].map(\.value)
                try write(values, target: target, match: match)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func values(_ target: RuleTarget, _ match: RuleMatch) throws -> [String] {
        let source = try JSONDecoder().decode(Source.self, from: localData(path(target, match)))
        if source.rules.isEmpty { return [] }
        guard source.version == 3, source.rules.count == 1, source.rules[0].count == 1,
              let values = source.rules[0][match.rawValue] else {
            throw UserError(localized("规则文件格式无效。", "The local rule file has an invalid format."))
        }
        return values
    }

    func list() throws -> [CustomRule] {
        try slots.flatMap { target, match in
            try values(target, match).map { try CustomRule($0, target: target) }
        }
    }

    private func write(_ values: [String], target: RuleTarget, match: RuleMatch) throws {
        let source = Source(version: 3, rules: values.isEmpty ? [] : [[match.rawValue: values.sorted()]])
        try savePrivate(JSONEncoder().encode(source), to: path(target, match))
    }

    func update(_ change: RuleChange) throws {
        let rule = change.rule
        guard supports(rule.target) else {
            throw UserError(localized("请重新准备当前配置，再添加指定节点规则。", "Prepare this profile again before adding a rule with a specified node."))
        }
        var values = Set(try values(rule.target, rule.match))
        if change.add { values.insert(rule.value) } else { values.remove(rule.value) }
        try write(Array(values), target: rule.target, match: rule.match)
    }
}

let upstreamTag = "proxyctl-upstream"

struct Upstream {
    let config: [String: Any]

    var addressLabel: String {
        let type = config["type"] as? String ?? ""
        let host = config["server"] as? String ?? ""
        let port = config["server_port"] as? Int ?? 0
        return "\(type) · \(terminalText(host)) · \(port)"
    }

    init(_ entry: [String: Any]) throws {
        guard let type = entry["type"] as? String, ["socks", "http"].contains(type),
              let host = entry["server"] as? String, !host.isEmpty, host == terminalText(host),
              let port = entry["server_port"] as? Int, (1...65535).contains(port) else {
            throw UserError(localized("外部出站需要有效的 SOCKS 或 HTTP CONNECT 地址。",
                                      "Provide a valid SOCKS or HTTP CONNECT endpoint."))
        }
        var config = entry
        config["tag"] = upstreamTag
        for key in ["detour", "bind_interface", "inet4_bind_address", "inet6_bind_address", "routing_mark", "netns", "domain_resolver"] {
            config.removeValue(forKey: key)
        }
        self.config = config
    }

    init(url: String) throws {
        guard let parsed = URLComponents(string: url), let host = parsed.host, let port = parsed.port,
              parsed.user == nil, parsed.password == nil, parsed.query == nil, parsed.fragment == nil,
              parsed.path.isEmpty || parsed.path == "/" else { throw Self.invalidURL }
        let server = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var entry: [String: Any] = ["server": server, "server_port": port]
        switch parsed.scheme?.lowercased() {
        case "socks5": entry["type"] = "socks"; entry["version"] = "5"
        case "http": entry["type"] = "http"
        case "https": entry["type"] = "http"; entry["tls"] = ["enabled": true]
        default: throw Self.invalidURL
        }
        try self.init(entry)
    }

    private static var invalidURL: UserError {
        UserError(localized("请输入无凭据的 socks5://主机:端口 或 http(s)://主机:端口。带凭据的上游可在导入文件中选用。",
                            "Enter a credential-free socks5://host:port or http(s)://host:port. Select authenticated upstreams from an import file."))
    }

    func validatePorts(_ proxy: Int, _ controller: Int) throws {
        let host = (config["server"] as? String)?.lowercased() ?? ""
        let port = config["server_port"] as? Int
        if ["127.0.0.1", "::1", "localhost"].contains(host), port == proxy || port == controller {
            throw UserError(localized("外部出站不能指向 Proxyctl 自己的监听端口。", "An upstream cannot point to Proxyctl's own listeners."))
        }
    }
}
