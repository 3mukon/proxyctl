import CryptoKit
import Foundation

struct RoutingPolicy: Codable, Equatable {
    var collections: [RuleCollection]
    var fallback: RuleTarget

    func revision() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try SHA256.hash(data: encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Routing {
    var policy: RoutingPolicy { RoutingPolicy(collections: collections, fallback: fallback) }

    var systemPolicy: RoutingPolicy {
        let target = fallback == .proxy && !explicitDefault ? .direct : fallback
        return RoutingPolicy(collections: collections, fallback: target)
    }
}

struct RoutingUpdate: Codable {
    let policy: RoutingPolicy
    let upstreamRevision: String?

    init(_ profile: ManagedProfile) throws {
        policy = profile.routing.systemPolicy
        upstreamRevision = try Self.upstreamRevision(profile.upstream)
    }

    func candidate(from source: [String: Any]) throws -> [String: Any] {
        let installed = try ManagedProfile(source, system: true)
        var routing = installed.routing
        routing.collections = policy.collections
        routing.fallback = policy.fallback
        routing.explicitDefault = true
        if routing.referencesUpstream {
            guard let upstreamRevision, upstreamRevision == (try Self.upstreamRevision(installed.upstream)) else {
                throw UserError(localized("本机的外部代理地址尚未应用到系统配置。请先部署该地址。",
                                          "The external proxy address in the local profile needs to be deployed first."))
            }
        }
        var candidate = source
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
