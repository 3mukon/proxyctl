import Foundation

struct ProxyGroup: Codable, Equatable {
    static let prefix = "proxyctl-group:"
    let name: String
    let order: [String]

    var target: RuleTarget { .group(name) }

    func firstReachable(_ reachable: (String) -> Bool) throws -> String {
        guard let node = order.first(where: reachable) else {
            throw UserError(localized("代理组「\(name)」暂无可用节点。", "No node in proxy group \(name) is reachable."))
        }
        return node
    }

    static func validName(_ name: String) -> Bool {
        Profile.validName(name) && name.utf8.count <= 80 &&
            !["default", "--new", "default proxy group", "默认代理组"].contains(name.lowercased())
    }

    static func selector(tag: String, order: [String]) -> [String: Any] {
        ["type": "selector", "tag": tag, "outbounds": order, "default": order[0],
         "interrupt_exist_connections": false]
    }

    static func isSelector(_ outbound: [String: Any]) -> Bool {
        outbound["type"] as? String == "selector" && (outbound["tag"] as? String)?.hasPrefix(prefix) == true
    }

    static func decode(_ outbounds: [[String: Any]], nodeNames: [String]) throws -> [ProxyGroup] {
        let groups = try outbounds.filter(isSelector).map { outbound in
            guard let tag = outbound["tag"] as? String, let order = outbound["outbounds"] as? [String] else {
                throw invalid
            }
            return ProxyGroup(name: String(tag.dropFirst(prefix.count)), order: order)
        }
        try validate(groups, nodeNames: nodeNames)
        return groups
    }

    static func validate(_ groups: [ProxyGroup], nodeNames: [String]) throws {
        let nodes = Set(nodeNames)
        var names = Set<String>()
        for group in groups {
            guard validName(group.name), names.insert(group.name.lowercased()).inserted,
                  !nodes.contains(group.target.outbound), !group.order.isEmpty,
                  Set(group.order).count == group.order.count, group.order.allSatisfy(nodes.contains) else {
                throw invalid
            }
        }
    }

    static var invalid: UserError {
        UserError(localized("代理组需要唯一名称和至少一个已导入的节点。", "Give each proxy group a unique name and at least one imported node."))
    }
}
