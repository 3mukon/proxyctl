import Foundation

@main
struct RoutingUpdateTests {
    private enum Interrupted: Error { case stop, start }

    static func main() throws {
        let args = CommandLine.arguments
        let directory = URL(fileURLWithPath: args[1], isDirectory: true)
        let paths = try Paths(state: directory, core: URL(fileURLWithPath: args[2]))
        try paths.ensureState()
        let first = "Primary"
        let second = "Backup"
        let port = Int(args[3])!
        let controller = Int(args[4])!
        let nodes = [(first, Int(args[5])!), (second, Int(args[6])!)]
        let source = try Profile(["outbounds": nodes.map { name, port in
            ["type": "socks", "tag": name, "server": "127.0.0.1", "server_port": port]
        }])
        let initial = Routing(presets: [.claude, .gpt])
        let preview = try source.managed(order: [first], port: port, controllerPort: controller, routing: initial)
        let id = UUID()
        let installed = try SystemProfile(preview, rulesID: id).config
        let installedProfile = try ManagedProfile(installed, system: true)
        precondition(installedProfile.routing.policy == initial.policy)
        let gemini = RuleCollection.preset(.gemini)
        let rules = [try CustomRule("single.test", target: .node(first))]
        let files = RuleFiles(state: directory, id: id, nodeNames: [first, second])
        try files.create(rules)
        let installedData = try jsonData(installed)
        try savePrivate(installedData, to: paths.config)
        try paths.coreCheck(paths.config)

        var desired = try ManagedProfile(preview).routing
        let group = ProxyGroup(name: "Work exit", order: [second, first])
        desired.groups = [group]
        desired.collections[0].target = group.target
        desired.collections[1].enabled = false
        let geminiIndex = desired.collections.firstIndex { $0.name == gemini.name }!
        desired.collections[geminiIndex].enabled = true
        desired.collections[geminiIndex].target = .node(first)
        desired.collections += [RuleCollection(name: "Local web", target: .direct, enabled: true,
                                              domains: ["local.test"], networks: ["127.0.0.1/32"])]
        desired.fallback = .node(second)
        let edited = try source.managed(order: [second, first], port: port, controllerPort: controller, routing: desired)
        let update = try RoutingUpdate(ManagedProfile(edited))
        var candidate = try update.candidate(from: installed)
        let resulting = try ManagedProfile(candidate, system: true)
        precondition(resulting.routing.policy == desired.policy)
        precondition(resulting.routing.rulesID == id && resulting.order == [first])
        let dns = candidate["dns"] as! [String: Any]
        let geminiDNS = (dns["rules"] as! [[String: Any]]).filter { ($0["domain_suffix"] as? [String]) == gemini.domains }
        precondition(geminiDNS.compactMap { $0["server"] as? String } == [fakeDNS, RuleTarget.node(first).resolver])
        let withDefaultOrder = try RoutingUpdate(ManagedProfile(edited), includeDefaultOrder: true).candidate(from: installed)
        let reordered = try ManagedProfile(withDefaultOrder, system: true)
        precondition(reordered.order == [second, first])
        let beforeSecret = installedProfile.secret
        precondition(resulting.secret == beforeSecret)
        let expanded = resulting.routing.expandedTargets(since: installedProfile.routing)
        precondition(expanded == [.node(first), .node(second), group.target, .direct])
        var narrowed = resulting.routing
        narrowed.collections[0].domains.removeLast()
        precondition(narrowed.expandedTargets(since: resulting.routing).isEmpty)
        let retained = try files.list()
        precondition(retained == rules)
        let nextFiles = resulting.routing.ruleFiles(in: directory)!
        try nextFiles.prepareGroupSlots(previous: files)
        let groupedRule = try RuleChange(["add", "group.test", group.target.rawValue],
                                         hasUpstream: false, nodeNames: files.nodeNames, groupNames: nextFiles.groupNames)
        try nextFiles.update(groupedRule)
        do {
            try files.prepareGroupSlots(previous: nextFiles)
            preconditionFailure("Expected deletion of a group in use to be rejected")
        } catch is UserError {}
        let activeRules = try nextFiles.list()
        precondition(Set(activeRules) == Set(rules + [groupedRule.rule]))
        let candidateData = try jsonData(candidate)
        try verifyRollback(RoutingRollback(config: paths.config), config: paths.config,
                           original: installedData, candidate: candidateData)
        try savePrivate(candidateData, to: paths.config)
        try paths.coreCheck(paths.config)

        // Exercise the system candidate without creating a system TUN in the test.
        candidate["inbounds"] = (candidate["inbounds"] as! [[String: Any]]).filter { $0["tag"] as? String != "system-tun" }
        var route = candidate["route"] as! [String: Any]
        route["auto_detect_interface"] = false
        route["rules"] = (route["rules"] as! [[String: Any]]).filter { $0["inbound"] as? String != "system-tun" }
        candidate["route"] = route
        try savePrivate(jsonData(candidate), to: directory.appendingPathComponent("loopback.json"))
    }

    private static func verifyRollback(_ journal: RoutingRollback, config: URL, original: Data, candidate: Data) throws {
        try journal.arm(original)
        try savePrivate(candidate, to: config)
        do {
            try journal.restore(stop: { throw Interrupted.stop }, start: {})
            preconditionFailure("Expected an interrupted stop")
        } catch Interrupted.stop {}
        let afterStop = try localData(config)
        precondition(journal.pending && afterStop == candidate)
        do {
            try journal.restore(stop: {}, start: { throw Interrupted.start })
            preconditionFailure("Expected an interrupted restart")
        } catch Interrupted.start {}
        let afterStart = try localData(config)
        precondition(journal.pending && afterStart == original)
        try journal.restore(stop: {}, start: {})
        precondition(!journal.pending)
        try journal.restore(stop: { preconditionFailure("The recovery was already committed") }, start: {})
    }
}
