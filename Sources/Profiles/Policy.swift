import CryptoKit
import Foundation

struct RoutingPolicy: Codable, Equatable {
    var collections: [RuleCollection]
    var fallback: RuleTarget
    var groups: [ProxyGroup]? = nil

    func revision() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // An inactive stock Gemini preset is equivalent to profiles that predate the preset.
        let inactiveGemini = RuleCollection.preset(.gemini)
        var originalInactiveGemini = inactiveGemini
        originalInactiveGemini.domains = Preset.originalGeminiDomains
        var comparable = self
        comparable.collections.removeAll { $0 == inactiveGemini || $0 == originalInactiveGemini }
        return try SHA256.hash(data: encoder.encode(comparable)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Routing {
    var policy: RoutingPolicy { RoutingPolicy(collections: collections, fallback: fallback, groups: groups.isEmpty ? nil : groups) }

    var systemPolicy: RoutingPolicy {
        var effective = policy
        if fallback == .proxy && !explicitDefault { effective.fallback = .direct }
        return effective
    }
}

struct RoutingUpdate: Codable {
    let policy: RoutingPolicy
    let upstreamRevision: String?
    let defaultOrder: [String]?

    init(_ profile: ManagedProfile, includeDefaultOrder: Bool = false) throws {
        policy = profile.routing.systemPolicy
        upstreamRevision = try Self.upstreamRevision(profile.upstream)
        defaultOrder = includeDefaultOrder ? profile.order : nil
    }

    func candidate(from source: [String: Any]) throws -> [String: Any] {
        let installed = try ManagedProfile(source, system: true)
        var routing = installed.routing
        routing.collections = policy.collections
        routing.fallback = policy.fallback
        routing.groups = policy.groups ?? []
        if routing.rulesID != nil { routing.ruleGroups = routing.groupNames }
        routing.explicitDefault = true
        if routing.referencesUpstream {
            guard let upstreamRevision, upstreamRevision == (try Self.upstreamRevision(installed.upstream)) else {
                throw UserError(localized("本机的外部代理地址尚未应用到系统配置。请先部署该地址。",
                                          "The external proxy address in the local profile needs to be deployed first."))
            }
        }
        var candidate = source
        if let defaultOrder {
            let available = installed.nodes.map(\.name)
            guard let order = try? Profile.order(defaultOrder, among: available), order == defaultOrder else {
                throw UserError(localized("请先把组内的新节点部署到系统配置。",
                                          "Deploy the new group members to the system profile first."))
            }
            var outbounds = candidate["outbounds"] as? [[String: Any]] ?? []
            guard let index = outbounds.firstIndex(where: { $0["tag"] as? String == selectorTag }) else {
                throw RuleCollection.invalid
            }
            outbounds[index] = ProxyGroup.selector(tag: selectorTag, order: order)
            candidate["outbounds"] = outbounds
        }
        try routing.apply(to: &candidate, system: true)
        guard try ManagedProfile(candidate, system: true).routing.policy == policy else {
            throw RuleCollection.invalid
        }
        return candidate
    }

    private static func upstreamRevision(_ upstream: Upstream?) throws -> String? {
        guard let upstream else { return nil }
        return try SHA256.hash(data: jsonData(upstream.config)).map { String(format: "%02x", $0) }.joined()
    }
}

extension ManagedProfile {
    func defaultOrderRevision() throws -> String {
        try SHA256.hash(data: JSONEncoder().encode([secret] + order)).map { String(format: "%02x", $0) }.joined()
    }
}
