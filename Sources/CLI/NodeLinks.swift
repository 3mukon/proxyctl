import Foundation

private func readNodeLinks(_ args: [String]) throws -> [ShareLink] {
    let data: Data
    switch args {
    case ["--stdin"]:
        data = try FileHandle.standardInput.read(upToCount: maxConfigBytes + 1) ?? Data()
    case []:
        data = try nodeLinkClipboard()
    default:
        let example = commandExample("nodes add")
        throw UserError(localized("复制链接后运行 \(example)。脚本可用 --stdin。", "Copy the link and run \(example). Scripts can use --stdin."))
    }
    return try parseNodeLinks(data)
}

func nodeLinkClipboard() throws -> Data {
    let clipboard = try run("/usr/bin/pbpaste", ["-Prefer", "txt"], quiet: true)
    guard clipboard.status == 0 else {
        throw UserError(localized("无法读取剪贴板。", "Could not read the clipboard."))
    }
    return clipboard.output
}

func parseNodeLinks(_ data: Data) throws -> [ShareLink] {
    guard data.count <= maxConfigBytes, let source = String(data: data, encoding: .utf8) else {
        throw UserError(localized("链接文本过大或编码无效。", "The link text is too large or its encoding is invalid."))
    }
    let lines = source.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !lines.isEmpty else {
        throw UserError(localized("先复制一条或多条节点分享链接。", "Copy one or more node share links first."))
    }
    return try lines.enumerated().map { index, line in
        do { return try ShareLink(line) }
        catch {
            throw UserError(localized("第 \(index + 1) 条链接：\(error.localizedDescription)",
                                      "Link \(index + 1): \(error.localizedDescription)"))
        }
    }
}

private func freshName(_ preferred: String, used: inout Set<String>) -> String {
    if used.insert(preferred.lowercased()).inserted { return preferred }
    var index = 2
    while !used.insert("\(preferred.lowercased()) \(index)").inserted { index += 1 }
    return "\(preferred) \(index)"
}

private func sameNode(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
    let options: Set<String> = ["tag", "domain_resolver", "bind_interface", "inet4_bind_address",
                                "inet6_bind_address", "routing_mark", "netns"]
    return NSDictionary(dictionary: lhs.filter { !options.contains($0.key) })
        .isEqual(to: rhs.filter { !options.contains($0.key) })
}

func addNodeLinks(_ args: [String], _ paths: Paths) throws {
    let links = try readNodeLinks(args)
    try paths.locked {
        let exists = FileManager.default.fileExists(atPath: paths.config.path)
        var config = exists ? try loadObject(localData(paths.config)) : [:]
        let current = exists ? try ManagedProfile(config) : nil
        if current != nil && (try? Engine(paths).requireListener()) != nil {
            throw UserError(localized("先结束正在运行的 Proxyctl 回环代理，再粘贴新节点。", "Stop the Proxyctl loopback proxy, then add the copied links."))
        }
        var outbounds = config["outbounds"] as? [[String: Any]] ?? []
        var names = Set(outbounds.compactMap { ($0["tag"] as? String)?.lowercased() })
        var added: [String] = []
        for link in links {
            if outbounds.contains(where: { $0["tag"] as? String != upstreamTag && sameNode($0, link.outbound) }) { continue }
            var entry = link.outbound
            let name = freshName(link.name, used: &names)
            entry["tag"] = name
            outbounds.append(entry)
            added.append(name)
        }
        if added.isEmpty {
            print(localized("这些节点已经存在。", "These nodes are already in the profile."))
            return
        }
        if let current, let index = outbounds.firstIndex(where: { $0["tag"] as? String == selectorTag }) {
            outbounds[index]["outbounds"] = current.order + added
            outbounds[index]["interrupt_exist_connections"] = false
            config["outbounds"] = outbounds
            try writeRoutingProfile(config, routing: current.routing, paths: paths)
        } else {
            let profile = try Profile(["outbounds": outbounds])
            let routing = Routing(presets: Preset.allCases)
            try writeRoutingProfile(routing, nodes: profile.nodes, paths: paths) { routing in
                try profile.managed(order: added, port: 11082, controllerPort: 19082, routing: routing)
            }
        }
        print(localized("已添加 \(added.count) 个节点。", "Added \(added.count) nodes."))
        for name in added { print("  \(terminalText(name))") }
        print(localized("用 \(commandExample("nodes")) 查看节点，或用 \(commandExample("check")) 检测。",
                        "List nodes with \(commandExample("nodes")) or check connectivity with \(commandExample("check"))."))
    }
}
