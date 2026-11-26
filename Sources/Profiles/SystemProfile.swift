import CryptoKit
import Darwin
import Foundation

enum Tunnel {
    static let name = "utun99"
    static let ipv4 = "172.29.255.1/29"
    static let ipv6 = "fd7a:115c:a1e0:ffff::1/126"
    static let dns4 = "172.29.255.2"
    static let dns6 = "fd7a:115c:a1e0:ffff::2"
}

struct SystemProfile {
    let config: [String: Any]

    init(_ preview: [String: Any], first: String? = nil, rulesID: UUID? = nil) throws {
        let managed = try ManagedProfile(preview)
        let source = try Profile(preview)
        var routing = managed.routing
        if let rulesID {
            routing.rulesID = rulesID
            routing.ruleNodes = managed.nodes.map(\.name)
            routing.ruleGroups = managed.routing.groupNames
        }
        if let first, !managed.order.contains(first) { throw UserError("试用节点不在所选策略组内。") }
        var candidate = try source.managed(order: managed.order, port: managed.port,
                                           controllerPort: managed.controllerPort, routing: routing, upstream: managed.upstream)
        var outbounds = (candidate["outbounds"] as? [[String: Any]] ?? [])
        if let first, let selector = outbounds.firstIndex(where: { $0["tag"] as? String == selectorTag }) {
            outbounds[selector]["default"] = first
            candidate["outbounds"] = outbounds
        }
        // A system service must not open file references supplied by a client profile.
        guard !Self.containsFileReference(outbounds) else {
            throw UserError("系统服务需要自包含的节点配置，请使用内嵌证书和密钥。")
        }
        var inbounds = (candidate["inbounds"] as? [[String: Any]] ?? [])
        inbounds.append([
            "type": "tun", "tag": "system-tun", "interface_name": Tunnel.name,
            "address": [Tunnel.ipv4, Tunnel.ipv6], "auto_route": true, "dns_mode": "hijack",
            "stack": "mixed"
        ])
        candidate["inbounds"] = inbounds
        try routing.apply(to: &candidate, system: true)
        var experiment = candidate["experimental"] as? [String: Any] ?? [:]
        var cache = experiment["cache_file"] as? [String: Any] ?? [:]
        cache["store_fakeip"] = true
        experiment["cache_file"] = cache
        candidate["experimental"] = experiment
        config = candidate
    }

    private static func containsFileReference(_ value: Any) -> Bool {
        if let dict = value as? [String: Any] {
            return dict.contains { key, entry in
                key.hasSuffix("_path") || key.hasSuffix("_file") || containsFileReference(entry)
            }
        }
        if let items = value as? [Any] { return items.contains(where: containsFileReference) }
        return false
    }
}

struct SystemSubmission: Codable {
    let profile: Data
    let rules: [CustomRule]

    func sourceRevision() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try SHA256.hash(data: encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}
