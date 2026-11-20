import Foundation

let directTag = "proxyctl-direct"
let directDNS = "proxyctl-direct-dns"
let proxyDNS = "proxyctl-proxy-dns"
let upstreamDNS = "proxyctl-upstream-dns"
let fakeDNS = "proxyctl-proxy-addresses"

enum Preset: String, CaseIterable, Codable {
    case claude
    case openai

    var domains: [String] {
        switch self {
        case .claude:
            return ["anthropic.com", "claude.ai", "claude.com", "claudeusercontent.com", "anthropicusercontent.com"]
        case .openai:
            return ["chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com", "oaistatsig.com", "openaimerge.com", "sora.com"]
        }
    }
}

struct Routing: Equatable {
    var collections: [RuleCollection]
    var fallback: RuleTarget
    var rulesID: UUID?
    var ruleNodes: [String] = []
    var explicitDefault = false

    var presets: [Preset] { collections.filter(\.enabled).compactMap { Preset(rawValue: $0.name) } }
    var referencesUpstream: Bool {
        fallback == .upstream || collections.contains { $0.enabled && $0.target == .upstream }
    }

    func referencesUpstream(with rules: [CustomRule]) -> Bool {
        referencesUpstream || rules.contains { $0.target == .upstream }
    }

    init(presets: [Preset] = [], fallback: RuleTarget = .direct) {
        collections = RuleCollection.defaults(presets)
        self.fallback = fallback
    }

    init(_ raw: [String: Any], nodeNames: [String]) throws {
        let route = raw["route"] as? [String: Any] ?? [:]
        let targets = RuleFiles.targets(nodeNames, hasUpstream: true)
        guard let fallback = targets.first(where: { $0.outbound == (route["final"] as? String) }) else {
            throw UserError(localized("无法识别当前配置的默认出站。", "The default outbound could not be recognized."))
        }
        let rules = route["rules"] as? [[String: Any]] ?? []
        let sets = route["rule_set"] as? [[String: Any]] ?? []
        let layout = try RuleFiles.layout(in: route, nodeNames: nodeNames)
        self.fallback = fallback
        self.rulesID = layout?.id
        self.ruleNodes = layout?.nodeNames ?? []
        self.explicitDefault = sets.contains { $0["tag"] as? String == RuleCollection.fallbackMarker }
        let parsed = try RuleCollection.decode(sets, routes: rules, targets: targets)
        if parsed.isEmpty {
            let selected = Preset.allCases.filter { preset in
                rules.contains { $0["domain_suffix"] as? [String] == preset.domains && $0["outbound"] as? String == selectorTag }
            }
            collections = RuleCollection.defaults(selected)
        } else {
            collections = parsed
        }
    }

    func ruleFiles(in state: URL) -> RuleFiles? {
        rulesID.map { RuleFiles(state: state, id: $0, nodeNames: ruleNodes) }
    }

    func pinnedNodes(_ rules: [CustomRule]) -> Set<String> {
        Set(([fallback] + collections.filter(\.enabled).map(\.target) + rules.map(\.target)).compactMap(\.nodeName))
    }

    func apply(to config: inout [String: Any], system: Bool = false) throws {
        let nodes = try Profile(config).nodes.map(\.name)
        let available = Set(nodes)
        let pinned = ([fallback] + collections.map(\.target)).compactMap(\.nodeName)
        guard pinned.allSatisfy(available.contains) else {
            throw UserError(localized("请先修改引用已移除节点的预设或「其余全部」。",
                                      "Update presets or the catch-all that reference removed nodes first."))
        }
        let outbounds = config["outbounds"] as? [[String: Any]] ?? []
        let hasUpstream = outbounds.contains { $0["tag"] as? String == upstreamTag }
        let targets = RuleFiles.targets(ruleNodes, hasUpstream: hasUpstream)
        let activeTargets = rulesID == nil ? [] : targets

        var rules: [[String: Any]] = []
        if system {
            rules += [
                ["inbound": "system-tun", "action": "sniff", "timeout": "400ms"],
                ["inbound": "system-tun", "protocol": "dns", "action": "hijack-dns"]
            ]
        }
        rules += collections.filter(\.enabled).map {
            ["rule_set": [$0.tag], "action": "route", "outbound": $0.target.outbound]
        }
        rules += RuleMatch.allCases.flatMap { match in
            activeTargets.map { target in
                ["rule_set": [RuleFiles.tag(target, match)], "action": "route", "outbound": target.outbound]
            }
        }
        var route: [String: Any] = [
            "final": fallback.outbound, "rules": rules,
            "default_domain_resolver": directDNS, "auto_detect_interface": system
        ]
        var definitions = collections.map(\.definition)
        if explicitDefault {
            definitions.append(["type": "inline", "tag": RuleCollection.fallbackMarker, "rules": [RuleCollection.emptyEntry]])
        }
        if let rulesID { definitions += RuleFiles.config(rulesID, targets: targets) }
        route["rule_set"] = definitions
        config["route"] = route

        let directResolver: [String: Any] = system
            ? ["type": "https", "tag": directDNS, "server": "223.5.5.5", "tls": ["server_name": "dns.alidns.com"]]
            : ["type": "local", "tag": directDNS]
        var servers: [[String: Any]] = [
            directResolver,
            ["type": "https", "tag": proxyDNS, "server": "1.1.1.1", "detour": selectorTag,
             "tls": ["server_name": "cloudflare-dns.com"]]
        ]
        if hasUpstream {
            servers.append(["type": "https", "tag": upstreamDNS, "server": "1.1.1.1", "detour": upstreamTag,
                            "tls": ["server_name": "cloudflare-dns.com"]])
        }
        let needed = Set(pinned + ruleNodes)
        for name in nodes where needed.contains(name) {
            let target = RuleTarget.node(name)
            servers.append(["type": "https", "tag": target.resolver, "server": "1.1.1.1", "detour": target.outbound,
                            "tls": ["server_name": "cloudflare-dns.com"]])
        }
        if system {
            servers.append(["type": "fakeip", "tag": fakeDNS, "inet4_range": "198.18.0.0/15", "inet6_range": "fc00::/18"])
        }

        let domains: [([String: Any], RuleTarget)] =
            collections.filter { $0.enabled && !$0.domains.isEmpty }.map { (["domain_suffix": $0.domains], $0.target) } +
            activeTargets.map { (["rule_set": [RuleFiles.tag($0, .domain)]], $0) }
        var dnsRules: [[String: Any]] = []
        for (match, target) in domains {
            var query = match
            query["action"] = "route"
            if system && target != .direct {
                var addresses = query
                addresses["query_type"] = ["A", "AAAA"]
                addresses["server"] = fakeDNS
                dnsRules.append(addresses)
            }
            query["server"] = target.resolver
            dnsRules.append(query)
        }
        if system && fallback != .direct {
            dnsRules.append(["query_type": ["A", "AAAA"], "action": "route", "server": fakeDNS])
        }
        config["dns"] = ["servers": servers, "rules": dnsRules, "final": fallback.resolver]
    }
}
