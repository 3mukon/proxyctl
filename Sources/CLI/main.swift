import Darwin
import Foundation

let version = "0.2.0"
let tty = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
let color = tty && ProcessInfo.processInfo.environment["NO_COLOR"] == nil && ProcessInfo.processInfo.environment["TERM"] != "dumb"
umask(0o077)

@_silgen_name("readline")
func editLine(_ prompt: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("add_history")
func addHistory(_ text: UnsafePointer<CChar>)

func styled(_ text: String, _ style: String) -> String {
    color ? "\u{1b}[\(style)m\(text)\u{1b}[0m" : text
}

func problem(_ error: Error) {
    if let exit = error as? ExitCode {
        if exit.value != 0 {
            fputs(localized("子命令退出（\(exit.value)）。\n", "Command exited with code \(exit.value).\n"), stderr)
        }
        return
    }
    fputs(styled("! ", "1;33") + terminalText(error.localizedDescription) + "\n", stderr)
}

private var presetNames: String { Preset.allCases.map(\.rawValue).joined(separator: ", ") }

func help() {
    if interfaceLanguage == .en {
        print("""
        Proxyctl \(version) · macOS sing-box console

          proxyctl                         Open the console
          proxyctl status [--json]         Show system TUN, node, and firewall status
          proxyctl nodes [--json]          List nodes and priority
          proxyctl nodes add               Add a copied share link
          proxyctl nodes import FILE       Import sing-box nodes
          proxyctl groups [--json]         List proxy groups and their failover order
          proxyctl groups default NODE... Set the default group's order
          proxyctl groups set NAME NODE... Create or edit a named group
          proxyctl groups remove NAME      Remove a named group
          proxyctl rules [--json]          List custom rules and, in text output, where unmatched traffic goes
          proxyctl rules default TARGET    Set the outbound for unmatched traffic
          proxyctl rules upstream URL|off  Save or clear the external proxy address
          proxyctl presets                 Show routing presets
          proxyctl check                   Check system routing or probe the first configured node
          proxyctl check node NODE         Check one imported node in isolation
          proxyctl test [NODE]             Run an isolated node probe
          proxyctl system                  Manage the system tunnel and rollback
          proxyctl start | stop            Verify and start, or stop the system proxy
          proxyctl enable | disable        Set whether the system proxy starts at boot
          proxyctl firewall status         Show independent PF protection
          proxyctl doctor                  Check the engine and profile
          proxyctl logs                    Show recent engine logs

        Use --group NAME or repeat --node NODE with nodes import. --preset accepts \(presetNames).
        Enter /help in the console for interactive commands and keys.
        """)
        return
    }
    print("""
    Proxyctl \(version) · macOS sing-box 控制台

      proxyctl                         打开交互控制台
      proxyctl status [--json]         查看全机 TUN、节点和防火墙状态
      proxyctl nodes [--json]          列出节点和策略组顺序
      proxyctl nodes add               从剪贴板添加节点
      proxyctl nodes import FILE       从 sing-box JSON 导入节点
      proxyctl groups [--json]         查看代理组和主备顺位
      proxyctl groups default NODE... 设置默认代理组顺位
      proxyctl groups set NAME NODE... 创建或编辑自定义代理组
      proxyctl groups remove NAME      删除自定义代理组
      proxyctl rules [--json]          查看自定义规则，文字输出也显示其余流量的出口
      proxyctl rules default TARGET    设置其余流量的出口
      proxyctl rules upstream URL|off  保存或清除外部代理地址
      proxyctl presets                 查看分流预设
      proxyctl check                   验证全机路径，启用前隔离检测首选节点
      proxyctl check node NODE         隔离检测一个已导入节点
      proxyctl test [NODE]             在隔离环境中检测节点
      proxyctl system                  查看系统隧道、验证和回退命令
      proxyctl start | stop            验证并启动系统代理，或停止系统代理
      proxyctl enable | disable        设置开机自启
      proxyctl firewall status         查看独立 PF 防护状态
      proxyctl doctor                  查看内核和本地配置
      proxyctl logs                    查看近期内核日志

    nodes import 可用 --group NAME，或重复 --node NODE。--preset 可选 \(presetNames)。
    在控制台输入 /help 可查看交互命令和按键。
    --port 默认 11082，--control-port 默认 19082。
    """)
}

struct Status: Encodable {
    let service: String
    let port: Int?
    let selectedNode: String?
    let protectedSystem: ProtectionStatus?
}

func currentStatus(_ paths: Paths) -> Status {
    let exists = FileManager.default.fileExists(atPath: paths.config.path)
    let engine = try? Engine(paths)
    let selected = try? engine?.current()
    let service: String
    if selected != nil {
        service = "preview"
    } else if engine != nil {
        service = "ready"
    } else {
        service = exists ? "invalid" : "unconfigured"
    }
    let system = paths.state == (try? Paths())?.state ? ProtectedService.installedStatus() : nil
    return Status(service: service, port: engine?.profile.port, selectedNode: selected,
                  protectedSystem: system)
}

func localServiceText(_ service: String) -> String {
    let states = [
        "preview": localized("仅本机回环诊断在运行", "Loopback diagnostics only"),
        "ready": localized("本机配置已就绪", "Local profile ready"),
        "invalid": localized("本机配置无效", "Invalid local profile"),
        "unconfigured": localized("尚未导入节点", "No nodes configured")
    ]
    return states[service] ?? service
}

func statusLines(_ status: Status) -> [String] {
    let system = status.protectedSystem
    var lines = system.map(systemStatusLines) ?? [systemCaptureText(nil)]
    if system?.engineRunning == true || system?.firewallLoaded == true { return lines }
    lines.append(localServiceText(status.service))
    if let port = status.port, status.service == "preview" {
        lines.append(localized("回环监听     127.0.0.1:\(port)", "Loopback     127.0.0.1:\(port)"))
    }
    if let selected = status.selectedNode { lines.append(localized("当前节点     \(terminalText(selected))", "Node         \(terminalText(selected))")) }
    return lines
}

func showInventory(_ inventory: Inventory, order: [String] = [], selected: String? = nil, json: Bool = false) throws {
    if json {
        struct Output: Encodable {
            let source: String
            let nodes: [Node]
            let order: [String]
            let selected: String?
        }
        try printJSON(Output(source: inventory.source, nodes: inventory.nodes, order: order, selected: selected))
        return
    }
    let sources = [
        "file": localized("导入文件", "import file"),
        "managed": localized("Proxyctl 本机配置", "Proxyctl local profile"),
        "system": localized("Proxyctl 系统配置", "Proxyctl system profile")
    ]
    let source = sources[inventory.source] ?? inventory.source
    print(styled(localized("节点 / \(source)", "Nodes / \(source)"), "1;36"))
    for (index, node) in inventory.nodes.enumerated() {
        let priority = order.firstIndex(of: node.name).map { localized("  顺位 \($0 + 1)", "  Priority \($0 + 1)") } ?? ""
        let marker = selected == node.name ? styled("●", "1;32") : "·"
        let endpoint = node.endpoint == "域名" ? localized("域名", "Hostname") : node.endpoint
        print("  \(marker) \(index + 1). \(terminalText(node.name))  \(node.protocolName) / \(endpoint)\(priority)")
    }
}

func awaitOrder(_ profile: Profile, currentOrder: [String] = []) throws -> [String] {
    guard profile.nodes.count > 1 else { return profile.nodes.map(\.name) }
    guard tty else { throw UserError(localized("配置有多个节点。重复传入 --node NODE 指定顺序。", "Repeat --node NODE to set the priority order.")) }
    try showInventory(Inventory(source: currentOrder.isEmpty ? "file" : "managed", nodes: profile.nodes), order: currentOrder)
    let groups = profile.groups
    for (index, group) in groups.enumerated() { print("  g\(index + 1) · \(terminalText(group))") }
    if !groups.isEmpty {
        print(localized("输入 g 编号选择代理组。", "Enter a g-number to pick a proxy group."))
    }
    print(localized("输入允许的节点编号，按先后用逗号或空格分隔。直接回车退出。", "Enter the node numbers in order, separated by commas or spaces. Press Enter on a blank line to cancel."))
    guard let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty else { throw UserError(localized("已取消。", "Cancelled.")) }
    let input = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if input.hasPrefix("g"), let group = Int(input.dropFirst()), group > 0, group <= groups.count {
        return try profile.importedGroup(groups[group - 1])
    }
    let order = try line.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace }).map { item in
        guard let index = Int(item), (1...profile.nodes.count).contains(index) else { throw UserError(localized("请使用列表中的节点编号。", "Use the numbers in the node list.")) }
        return profile.nodes[index - 1].name
    }
    return try profile.order(order)
}

func nodeFilePath(_ input: String) throws -> String {
    let path = (input as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: path) { return path }
    let parsed = try parseLine(input)
    guard parsed.count == 1 else {
        throw UserError(localized("请输入一个配置文件路径。", "Enter a single configuration file path."))
    }
    return parsed[0]
}

func readNodeFile(_ source: String) throws -> Profile {
    if source.hasPrefix("--") {
        throw UserError(localized("请提供本机 sing-box JSON 文件。", "Choose a local sing-box JSON file."))
    }
    let url = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
    return try Profile(loadObject(localData(url)))
}

func importNodes(_ args: [String], _ paths: Paths) throws {
    var arguments = args
    if arguments.isEmpty && !tty {
        print(localized(
            """
            导入节点：proxyctl nodes add 或 proxyctl nodes import FILE
            隔离检测：proxyctl check
            全机接管：proxyctl system 查看准备、试用和回退步骤
            """,
            """
            Import nodes with proxyctl nodes add or proxyctl nodes import FILE.
            Run an isolated node check with proxyctl check.
            For system capture, see proxyctl system for preparation, trial, and recovery.
            """))
        return
    }
    if arguments.isEmpty {
        print(localized("拖入 sing-box JSON 文件或输入路径。直接回车返回。", "Drop a sing-box JSON file or type its path. Press Enter on a blank line to go back."))
        guard let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        arguments = [try nodeFilePath(line)]
    }
    var args = arguments[...]
    let source = args.popFirst()!
    var order: [String] = []
    var group: String?
    var external: String?
    var presets: [Preset] = []
    var fallback: RuleTarget?
    var port = 11082
    var apiPort = 19082
    while let flag = args.popFirst() {
        guard let value = args.popFirst() else { throw UserError(localized("选项需要一个值。", "This option needs a value.")) }
        switch flag {
        case "--node": order.append(value)
        case "--group": group = value
        case "--upstream": external = value
        case "--preset":
            guard let preset = Preset(rawValue: value) else {
                throw UserError(localized("可用预设为 \(presetNames)。", "Available presets are \(presetNames)."))
            }
            presets.append(preset)
        case "--default":
            guard let route = RuleTarget(rawValue: value) else { throw UserError(localized("请选择有效的默认出站。", "Choose a valid default outbound.")) }
            fallback = route
        case "--port": port = Int(value) ?? 0
        case "--control-port": apiPort = Int(value) ?? 0
        default: throw UserError(localized("未知的节点导入选项。", "Unknown import option."))
        }
    }
    guard group == nil || order.isEmpty else {
        throw UserError(localized("请选择 --group 或 --node 其中一种。", "Use either --group or --node."))
    }
    guard validPorts(port, apiPort) else { throw UserError(localized("代理端口与控制端口必须不同，且在 1024–65535 之间。", "Choose different proxy and control ports between 1024 and 65535.")) }
    try paths.locked {
        if (try? Engine(paths).requireListener()) != nil {
            throw UserError(localized("请先结束正在运行的 Proxyctl 回环代理。", "Stop the running Proxyctl loopback proxy first."))
        }
        let profile = try readNodeFile(source)
        let names = try group.map(profile.importedGroup) ?? (order.isEmpty ? awaitOrder(profile) : profile.order(order))
        let previous = FileManager.default.fileExists(atPath: paths.config.path) ? try ManagedProfile(paths.config) : nil
        let upstream = try external.map(profile.explicitUpstream) ?? previous?.upstream
        var routing = previous?.routing ?? Routing(presets: Preset.allCases)
        if let fallback {
            routing.fallback = try fallback.resolved(in: profile.nodes.map(\.name), groups: routing.groupNames)
        }
        if !presets.isEmpty {
            for index in routing.collections.indices {
                if let preset = Preset(rawValue: routing.collections[index].name) {
                    routing.collections[index].enabled = presets.contains(preset)
                }
            }
        }
        try writeRoutingProfile(routing, nodes: profile.nodes, paths: paths) { routing in
            try profile.managed(order: names, port: port, controllerPort: apiPort, routing: routing, upstream: upstream)
        }
        let order = names.map(terminalText).joined(separator: " → ")
        print(localized("已校验配置", "Profile validated") + " · \(order)")
        print(localized("用 \(commandExample("check")) 检测节点。", "Check the node with \(commandExample("check"))."))
    }
}

func nodes(_ args: [String], _ paths: Paths) throws {
    if args.first == "import" {
        try importNodes(Array(args.dropFirst()), paths)
        return
    }
    if args.first == "add" {
        try addNodeLinks(Array(args.dropFirst()), paths)
        return
    }
    let json = args.contains("--json")
    let flags = args.filter { $0 != "--json" }
    if flags.count == 2 && flags[0] == "--file" {
        let url = URL(fileURLWithPath: (flags[1] as NSString).expandingTildeInPath)
        let profile = try Profile(loadObject(localData(url)))
        try showInventory(Inventory(source: "file", nodes: profile.nodes), json: json)
        return
    }
    guard flags.isEmpty else {
        let example = commandExample("nodes [--file FILE] [--json]")
        throw UserError(localized("使用 \(example)", "Use \(example)"))
    }
    if FileManager.default.fileExists(atPath: paths.config.path) {
        let engine = try Engine(paths)
        try showInventory(Inventory(source: "managed", nodes: engine.profile.nodes), order: engine.profile.order,
                          selected: try? engine.current(), json: json)
        if !json {
            print(commandExample("nodes add") + " · " + localized("从剪贴板添加节点", "Add from clipboard"))
            print(commandExample("nodes import") + " · " + localized("从 JSON 文件导入节点", "Import nodes from JSON"))
        }
    } else {
        if json { try showInventory(Inventory(source: "managed", nodes: []), json: true); return }
        print(localized("复制节点链接后，运行 \(commandExample("nodes add"))。",
                        "Copy a node link, then run \(commandExample("nodes add"))."))
    }
}

func testNodes(_ arguments: [String], _ paths: Paths) throws {
    var args = arguments[...]
    var name: String?
    var url = probeURL
    while let value = args.popFirst() {
        if value == "--url" {
            guard let address = args.popFirst() else { throw UserError(localized("--url 需要测试地址。", "Provide a URL for --url.")) }
            url = address
            continue
        }
        guard name == nil else { throw UserError(localized("请只指定一个节点名称。", "Specify one node name.")) }
        name = value
    }
    let engine = try Engine(paths)
    let names = name.map { [$0] } ?? engine.profile.order
    var success = false
    for node in names {
        guard let delay = try? engine.test(node, url: url) else {
            print("  × \(terminalText(node))  " + localized("探测失败", "Check failed"))
            continue
        }
        print("  ✓ \(terminalText(node))  \(delay) ms")
        success = true
    }
    if !success {
        throw UserError(localized("节点均未通过连通性检查。", "None of the nodes passed the connectivity check."))
    }
}

func tailLog(_ paths: Paths) throws {
    guard let handle = try? FileHandle(forReadingFrom: paths.log) else { print("目前没有内核日志。"); return }
    defer { try? handle.close() }
    let end = try handle.seekToEnd()
    try handle.seek(toOffset: end > 64 * 1024 ? end - 64 * 1024 : 0)
    let text = String(decoding: try handle.read(upToCount: 64 * 1024) ?? Data(), as: UTF8.self)
    for line in text.split(separator: "\n").suffix(35) { print(terminalText(String(line))) }
}

func execute(_ args: [String], _ paths: Paths) throws {
    guard let command = args.first else { return }
    let rest = Array(args.dropFirst())
    switch command {
    case "help", "--help", "-h": help()
    case "version", "--version": print(version)
    case "status":
        guard rest.isEmpty || rest == ["--json"] else {
            let example = commandExample("status [--json]")
            throw UserError(localized("使用 \(example)", "Use \(example)"))
        }
        let status = currentStatus(paths)
        if rest == ["--json"] { try printJSON(status) }
        else { statusLines(status).forEach { print($0) } }
    case "doctor":
        statusLines(currentStatus(paths)).forEach { print($0) }
        if let result = try? run(paths.core.path, ["version"], quiet: true), result.status == 0,
           let first = result.text.split(separator: "\n").first { print(terminalText(String(first))) }
        else { print("自带内核暂不可用。") }
        if FileManager.default.fileExists(atPath: paths.config.path) {
            try paths.coreCheck(paths.config)
            print(localized("本机配置通过 sing-box 校验。", "sing-box validated the local profile."))
        } else { print(commandExample("nodes add")) }
    case "nodes": try nodes(rest, paths)
    case "groups": try manageGroups(rest, paths)
    case "presets": try managePresets(rest, paths)
    case "rules": try rules(rest, paths)
    case "preview":
        guard rest.isEmpty else { throw UserError(localized("使用 ", "Use ") + commandExample("preview")) }
        guard FileManager.default.fileExists(atPath: paths.config.path) else {
            throw UserError(localized("运行 \(commandExample("nodes import")) 导入节点。", "Import nodes with \(commandExample("nodes import"))."))
        }
        let core = try paths.locked {
            let engine = try Engine(paths)
            try engine.verifyLoopbackStart()
            let profile = engine.profile
            print(localized("仅本机回环诊断", "Loopback diagnostics only") + " · 127.0.0.1:\(profile.port) · " + localized("Ctrl-C 结束", "Ctrl-C to stop"))
            fflush(stdout)
            return try ManagedCore(paths)
        }
        try core.wait()
    case "test": try testNodes(rest, paths)
    case "check":
        if rest.first == "node" {
            guard rest.count == 2 || (rest.count == 4 && rest[2] == "--url") else {
                let example = commandExample("check node NODE [--url URL]")
                throw UserError(localized("使用 \(example)", "Use \(example)"))
            }
            let name = rest[1]
            let url = rest.count == 4 ? rest[3] : probeURL
            let delay = try Engine(paths).test(name, url: url)
            print(localized("隔离节点检测", "Isolated node check") + " · \(terminalText(name)) · \(delay) ms")
            return
        }
        guard rest.isEmpty || (rest.count == 2 && rest.first == "--url") else {
            throw UserError(localized("使用 ", "Use ") + commandExample("check [--url URL]"))
        }
        if rest.isEmpty, protectedConsoleStatus(paths, ProtectedService.installedStatus()) != nil {
            try system(["check"], paths)
            return
        }
        let engine = try Engine(paths)
        let url = rest.last ?? probeURL
        if (try? engine.requireListener()) != nil {
            let result = try engine.checkActive(url: url)
            print("\(terminalText(result.node)) · " + localized("回环诊断", "Loopback diagnostics") + " · \(result.delay) ms")
        } else {
            let node = engine.profile.order[0]
            let delay = try engine.test(node, url: url)
            print(localized("隔离节点检测", "Isolated node check") + " · \(terminalText(node)) · \(delay) ms")
        }
    case "system": try system(rest, paths)
    case "start", "stop", "enable", "disable": try system([command] + rest, paths)
    case "firewall": try firewall(rest)
    case "logs":
        guard rest.isEmpty else { throw UserError("用法：proxyctl logs") }
        try tailLog(paths)
    default: throw UserError("未知命令。运行 proxyctl help 查看用法。")
    }
}

struct CommandToken {
    let value: String
    let end: String.Index
}

func commandTokens(_ line: String, allowingIncomplete: Bool = false) throws -> [CommandToken] {
    var tokens: [CommandToken] = []
    var token = ""
    var quote: Character?
    var escape = false
    var started = false
    for index in line.indices {
        let character = line[index]
        if escape { token.append(character); escape = false; continue }
        if character == "\\" && quote != "'" { escape = true; started = true; continue }
        if let matching = quote {
            if character == matching { quote = nil } else { token.append(character) }
        } else if character == "\"" || character == "'" {
            quote = character
            started = true
        } else if character.isWhitespace {
            if started {
                tokens.append(CommandToken(value: token, end: index))
                token = ""
                started = false
            }
        } else {
            token.append(character)
            started = true
        }
    }
    guard allowingIncomplete || (quote == nil && !escape) else {
        throw UserError(localized("引号或反斜杠尚未闭合。", "Close the quote or finish the escape sequence."))
    }
    if started { tokens.append(CommandToken(value: token, end: line.endIndex)) }
    return tokens
}

func parseLine(_ line: String) throws -> [String] {
    try commandTokens(line).map(\.value)
}

func consoleCommand(_ input: String) -> String {
    input.hasPrefix("/") ? String(input.dropFirst()) : input
}

func lineConsole(_ paths: Paths) {
    consoleInvocation = true
    let menu = consoleCommandList
    print("proxyctl \(version)\n\(menu)")
    while let pointer = editLine("\n❯ ") {
        let line = String(cString: pointer)
        free(pointer)
        do {
            var args = try parseLine(line)
            guard let first = args.first else { continue }
            args[0] = consoleCommand(first)
            if args[0] == "quit" { break }
            if args[0].isEmpty || args[0] == "home" { print(menu); continue }
            if args[0] == "help" {
                let rows = try consoleHelpRows(args)
                let width = (rows.map { $0[0].count }.max() ?? 0) + 2
                for row in rows {
                    print(row[0].padding(toLength: width, withPad: " ", startingAt: 0) + row[1])
                }
                print()
                consoleHelpTips.forEach { print($0) }
                continue
            }
            if args[0] == "lang" {
                guard args.count == 2, let language = InterfaceLanguage(rawValue: args[1]) else {
                    let options = InterfaceLanguage.allCases.map { "/lang \($0.rawValue) · \($0.name)" }
                    print(options.joined(separator: "    "))
                    continue
                }
                try selectInterfaceLanguage(language, paths: paths)
                continue
            }
            guard isConsoleCommand(args[0]) else { throw UserError(localized("输入 / 查看日常命令。", "Type / for daily commands.")) }
            if args.starts(with: ["nodes", "add"]), args.count > 2 {
                throw UserError(localized("复制分享链接，再运行 /nodes add。", "Copy the share links, then run /nodes add."))
            }
            _ = try consoleSystemAction(args)
            line.withCString { addHistory($0) }
            if args == ["system"] {
                try execute(["status"], paths)
                print()
                consoleSystemActionHints.forEach { print($0) }
                continue
            }
            if protectedConsoleStatus(paths, ProtectedService.installedStatus()) != nil,
               isProtectedConsoleCommand(args) {
                args.insert("system", at: 0)
            }
            try execute(args, paths)
        } catch { problem(error) }
    }
}

do {
    var args = Array(CommandLine.arguments.dropFirst())
    var override: URL?
    if args.first == "--state-dir", args.count >= 2 {
        override = URL(fileURLWithPath: args[1], isDirectory: true)
        args.removeFirst(2)
    }
    let paths = try Paths(state: override)
    loadInterfaceLanguage(paths)
    if args.isEmpty && tty { console(paths) }
    else { try execute(args.isEmpty ? ["status"] : args, paths) }
} catch {
    problem(error)
    exit((error as? ExitCode)?.value ?? 1)
}
