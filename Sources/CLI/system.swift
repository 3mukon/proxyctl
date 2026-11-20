import Darwin
import Foundation

struct SystemPlan: Encodable {
    let tunnel = Tunnel.name
    let addresses = [Tunnel.ipv4, Tunnel.ipv6]
    let anchor = PacketFilter.anchor
    let port: Int
    let fallback: RuleTarget
    let presets: [Preset]
    let collections: [RuleCollection]
    let order: [String]
    let rules: [CustomRule]
    let upstream: Bool
    let rollbackSeconds = Int(ProtectedService.interval)
}

func validateSystemProfile(_ source: Data, paths: Paths) throws -> ManagedProfile {
    let profile = try SystemProfile(loadObject(source))
    let scratch = paths.state.appendingPathComponent("system-plan-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: scratch) }
    try savePrivate(jsonData(profile.config), to: scratch)
    try paths.coreCheck(scratch)
    try PacketFilter.validate()
    return try ManagedProfile(profile.config, system: true)
}

func protectedConsoleStatus(_ paths: Paths, _ status: ProtectionStatus?) -> ProtectionStatus? {
    guard paths.state == (try? Paths())?.state,
          let status, status.engineRunning || status.firewallLoaded else { return nil }
    return status
}

func usesLivePolicy(_ status: ProtectionStatus?) -> Bool {
    status?.phase == .protected && status?.engineRunning == true && status?.firewallLoaded == true &&
        status?.routingRevision != nil
}

func changesPolicy(_ args: [String]) -> Bool {
    if args.first == "presets" {
        return args.count >= 3 && (args[1] != "route" || args.count == 4)
    }
    return args.count == 3 && args.starts(with: ["rules", "default"]) && args[2] != "--json"
}

func pendingPolicyMessage(_ status: ProtectionStatus, lookup: String = commandExample("system apply")) -> String {
    if status.phase == .protected && status.engineRunning && status.firewallLoaded {
        return localized("更改已保存在本机。用 \(lookup) 应用到系统。",
                         "Changes are saved locally. Use \(lookup) to apply them to the system.")
    }
    return localized("更改已保存在本机。系统保护就绪后可以应用。",
                     "Changes are saved locally and can apply once system protection is ready.")
}

func applyRoutingPolicy(_ profile: ManagedProfile) throws {
    let update = try JSONEncoder().encode(RoutingUpdate(profile))
    guard update.count <= maxConfigBytes else { throw RuleCollection.invalid }
    try ProtectedService.asAdministrator(["system", "_apply-routing"] + systemPresentation,
                                         executable: systemLauncher(), input: update)
}

func isProtectedConsoleCommand(_ args: [String]) -> Bool {
    switch args.first {
    case "rules": return args.dropFirst().first.map { !["upstream", "default"].contains($0) } ?? true
    case "use": return true
    case "nodes", "check": return args.count == 1
    default: return false
    }
}

func systemCaptureText(_ status: ProtectionStatus?) -> String {
    if status?.engineRunning == true { return localized("全机 TUN 运行中", "System TUN running") }
    return localized("全机接管未启用", "System capture is off")
}

func protectionPhaseText(_ status: ProtectionStatus) -> String {
    if status.phase == .prepared && status.verified == true {
        return localized("已验证，可以启动", "Verified and ready to start")
    }
    let names: [ProtectionPhase: String] = [
        .prepared: localized("已准备，等待试用", "Ready for trial"),
        .tunnelTrial: localized("TUN 试用中", "TUN trial"),
        .firewallTesting: localized("PF 正在验证", "Testing PF"),
        .firewallTrial: localized("PF 试用中", "PF trial"),
        .starting: localized("正在启动", "Starting"),
        .protected: localized("试用通过，已确认启用", "Trial passed and deployment confirmed"),
        .rollingBack: localized("正在回退", "Rolling back")
    ]
    return names[status.phase] ?? status.phase.rawValue
}

func systemStatusLines(_ status: ProtectionStatus) -> [String] {
    let firewall = status.firewallLoaded ? localized("已加载", "Loaded") : localized("未加载", "Not loaded")
    var lines = [systemCaptureText(status) + " · " + protectionPhaseText(status),
                 localized("独立 PF    ", "Independent PF ") + firewall]
    if let boot = status.startsAtBoot {
        lines.append(boot ? localized("开机自启   已启用", "Start at boot   On") : localized("开机自启   已停用", "Start at boot   Off"))
    }
    if let node = status.selectedNode { lines.append(localized("系统节点   ", "System node    ") + terminalText(node)) }
    if let automatic = status.automaticSelection { lines.append(selectionModeLine(automatic)) }
    if let seconds = status.secondsLeft { lines.append(localized("回退倒计时  约 \(seconds) 秒", "Rollback in about \(seconds) seconds")) }
    if let error = status.lastError { lines.append(localized("诊断       ", "Diagnostics    ") + terminalText(error)) }
    return lines
}

private var missingSystemProfile: UserError {
    let setup = commandExample("setup import")
    return UserError(localized("请先用 \(setup) 导入节点。", "Import nodes with \(setup) first."))
}

private func systemSource(_ paths: Paths) throws -> SystemSubmission {
    guard FileManager.default.fileExists(atPath: paths.config.path) else { throw missingSystemProfile }
    let source = try localData(paths.config)
    let profile = try ManagedProfile(loadObject(source))
    let rules = try profile.routing.ruleFiles(in: paths.state)?.list() ?? []
    return SystemSubmission(profile: source, rules: rules)
}

private func checkDeployment(_ submission: SystemSubmission, paths: Paths) throws -> String {
    _ = try validateSystemProfile(submission.profile, paths: paths)
    let engine = try Engine(paths)
    let profile = engine.profile
    let pinned = profile.routing.pinnedNodes(submission.rules)
    if let delay = try TunnelCheck.verifyUpstream(engine, rules: submission.rules) {
        print("✓ " + localized("外部代理转发", "External proxy forwarding") + " · \(delay) ms")
        fflush(stdout)
    }
    var pinnedChecks: [String: Int] = [:]
    for node in profile.nodes where pinned.contains(node.name) {
        guard let time = try? engine.test(node.name, url: probeURL, preparingSystem: true) else {
            throw UserError(localized("指定节点 \(terminalText(node.name)) 未通过探测，系统配置未写入。",
                                      "The specified node \(terminalText(node.name)) failed its probe. The system profile was left untouched."))
        }
        pinnedChecks[node.name] = time
        print("✓ \(terminalText(node.name)) · \(time) ms")
    }
    for name in profile.order {
        guard let time = pinnedChecks[name] ?? (try? engine.test(name, url: probeURL, preparingSystem: true)) else {
            print("× \(terminalText(name)) · " + localized("回环探测失败", "Loopback probe failed"))
            fflush(stdout)
            continue
        }
        if pinnedChecks[name] == nil {
            print("✓ \(terminalText(name)) · " + localized("回环探测", "Loopback probe") + " \(time) ms")
        }
        return name
    }
    throw UserError(localized("没有节点通过实际转发探测，系统配置未写入。",
                              "No node passed the forwarding probe. The system profile was not written."))
}

private func systemLauncher() throws -> URL {
    guard let executable = Bundle.main.executableURL else {
        throw UserError(localized("无法定位安装器。", "Could not locate the installer."))
    }
    return executable
}

private var systemPresentation: [String] {
    [interfaceLanguage.rawValue, consoleInvocation ? "console" : "shell"]
}

private func loadSystemPresentation(_ arguments: [String]) throws {
    guard arguments.count == 2, let language = InterfaceLanguage(rawValue: arguments[0]),
          ["console", "shell"].contains(arguments[1]) else {
        throw UserError("Invalid system command presentation arguments.")
    }
    interfaceLanguage = language
    consoleInvocation = arguments[1] == "console"
}

private func runInstalledSystemCommand(_ action: String, _ arguments: [String] = []) throws {
    guard FileManager.default.isExecutableFile(atPath: ProtectedService.cli.path) else {
        let start = commandExample("system start")
        throw UserError(localized("请先运行 \(start)。", "Run \(start) first."))
    }
    try ProtectedService.asAdministrator(["system", "_manage-installed"] + systemPresentation + [action] + arguments,
                                         executable: systemLauncher())
}

private func installSystem(_ submission: SystemSubmission, paths: Paths, activate: Bool) throws {
    let node = try checkDeployment(submission, paths: paths)
    fflush(stdout)
    let command = activate ? ["system", "_deploy", node] + systemPresentation : ["system", "_prepare", node]
    try ProtectedService.asAdministrator(command, executable: systemLauncher(),
                                         input: JSONEncoder().encode(submission))
}

private func usesInstalledProfile(_ installed: ProtectionStatus?, hasLocal: Bool) -> Bool {
    guard let installed else { return false }
    return installed.phase != .prepared || !hasLocal || (installed.verified == true && installed.sourceRevision == nil)
}

private func checkSystemStartup(_ paths: Paths, installed: ProtectionStatus?) throws {
    let hasLocal = FileManager.default.fileExists(atPath: paths.config.path)
    if usesInstalledProfile(installed, hasLocal: hasLocal) {
        print(localized("沿用已准备的系统配置。暂停当前 VPN 后将检查实际网络。",
                        "Using the installed profile. The active network will be checked after the current VPN is paused."))
        return
    }
    guard hasLocal else { throw missingSystemProfile }
    try paths.locked {
        let submission = try systemSource(paths)
        _ = try checkDeployment(submission, paths: paths)
    }
}

private func startSystem(_ paths: Paths) throws {
    let installed = ProtectedService.installedStatus()
    let hasLocal = FileManager.default.fileExists(atPath: paths.config.path)

    if installed == nil || installed?.phase == .prepared, try TunnelCheck.competingVPNActive() {
        try checkSystemStartup(paths, installed: installed)
        throw TunnelCheck.pauseVPN
    }

    func startInstalled() throws {
        if installed?.phase == .prepared { _ = try TunnelCheck.preflight() }
        let revision = installed?.sourceRevision.map { [$0] } ?? []
        try ProtectedService.asAdministrator(["system", "_start-installed"] + systemPresentation + revision,
                                             executable: systemLauncher())
    }

    if usesInstalledProfile(installed, hasLocal: hasLocal) {
        try startInstalled()
        return
    }
    guard hasLocal else { throw missingSystemProfile }
    try paths.locked {
        let submission = try systemSource(paths)
        if installed?.verified == true, installed?.sourceRevision == (try submission.sourceRevision()) {
            try startInstalled()
        } else {
            _ = try TunnelCheck.preflight()
            try installSystem(submission, paths: paths, activate: true)
        }
    }
}

func system(_ args: [String], _ paths: Paths) throws {
    guard let action = args.first else {
        print("""
        proxyctl system plan        离线校验系统配置和 PF 规则
        proxyctl system prepare     测试节点并准备系统服务
        proxyctl system trial       临时接管路由，自动回退
        proxyctl firewall on        在已通过的 TUN 试用上验证独立防护
        proxyctl system keep        保留通过验证的试用设置
        proxyctl system rollback    离线撤销本产品的系统设置
        proxyctl system apply       将本机预设和其余流量出口应用到系统
        proxyctl system status | check | nodes | rules
        proxyctl system use NODE | --auto
        proxyctl start | stop        验证并启动，或停止系统代理
        proxyctl enable | disable    设置下次开机是否自动启动
        """)
        return
    }
    let rest = Array(args.dropFirst())
    if action == "_check-start" && rest.isEmpty {
        try checkSystemStartup(paths, installed: ProtectedService.installedStatus())
        return
    }
    if ["_prepare", "_deploy"].contains(action) && geteuid() == 0 {
        let activate = action == "_deploy"
        guard rest.count == (activate ? 3 : 1) else { throw UserError("Invalid system deployment arguments.") }
        if activate { try loadSystemPresentation(Array(rest.dropFirst())) }
        let input = try FileHandle.standardInput.read(upToCount: maxConfigBytes * 2 + 1) ?? Data()
        guard input.count <= maxConfigBytes * 2 else { throw UserError("系统配置超过大小限制。") }
        let submission = try JSONDecoder().decode(SystemSubmission.self, from: input)
        try ProtectedService().install(from: paths, submission: submission, selected: rest[0], activate: activate)
        return
    }
    if action == "_start-installed" && geteuid() == 0 {
        guard (2...3).contains(rest.count) else { throw UserError("Invalid installed startup arguments.") }
        try loadSystemPresentation(Array(rest.prefix(2)))
        try ProtectedService().startExisting(expectedRevision: rest.count == 3 ? rest[2] : nil)
        return
    }
    if action == "_apply-routing" && geteuid() == 0 {
        try loadSystemPresentation(rest)
        let input = try FileHandle.standardInput.read(upToCount: maxConfigBytes + 1) ?? Data()
        guard input.count <= maxConfigBytes else { throw RuleCollection.invalid }
        let update = try JSONDecoder().decode(RoutingUpdate.self, from: input)
        try ProtectedService().applyRouting(update)
        return
    }
    if action == "_manage-installed" && geteuid() == 0 {
        guard rest.count >= 3 else { throw UserError("Invalid installed management command arguments.") }
        try loadSystemPresentation(Array(rest.prefix(2)))
        try ProtectedService().manage(rest[2], Array(rest.dropFirst(3)))
        return
    }
    if ProtectedService.isInstalledDriver(), action != "status" && action != "nodes" {
        try ProtectedService().perform(action, rest)
        return
    }
    switch action {
    case "start":
        guard rest.isEmpty else { throw UserError(localized("此命令无需额外参数。", "This command takes no arguments.")) }
        try startSystem(paths)
    case "apply":
        guard rest.isEmpty, let installed = protectedConsoleStatus(paths, ProtectedService.installedStatus()),
              installed.phase == .protected, installed.engineRunning, installed.firewallLoaded else {
            throw UserError(localized("需要正在运行且已启用 PF 防护的系统代理。",
                                      "This requires a running system proxy with PF protection enabled."))
        }
        try paths.locked { try applyRoutingPolicy(ManagedProfile(paths.config)) }
    case "plan", "prepare":
        guard rest.isEmpty || (action == "plan" && rest == ["--json"]) else {
            throw UserError(localized("未知的系统准备选项。", "Unknown system preparation option."))
        }
        guard FileManager.default.fileExists(atPath: paths.config.path) else { throw missingSystemProfile }
        try paths.locked {
            let submission = try systemSource(paths)
            if action == "plan" {
                let profile = try validateSystemProfile(submission.profile, paths: paths)
                let plan = SystemPlan(port: profile.port, fallback: profile.routing.fallback,
                                      presets: profile.routing.presets, collections: profile.routing.collections,
                                      order: profile.order, rules: submission.rules,
                                      upstream: profile.upstream != nil)
                if rest == ["--json"] { try printJSON(plan) }
                else {
                    print("离线校验通过 · \(plan.tunnel) · 回环端口 \(plan.port)")
                    print("默认出站 \(plan.fallback.displayName) · 分流预设 \(plan.presets.map(\.rawValue).joined(separator: ", "))")
                    print("策略组 \(plan.order.map(terminalText).joined(separator: " → "))")
                }
                return
            }
            try installSystem(submission, paths: paths, activate: false)
            if consoleInvocation {
                print(localized("已准备系统配置。用 /system 查看状态。", "System profile prepared. Use /system to see its status."))
            } else {
                print(localized("已准备系统配置。下一步可运行 proxyctl system start。", "System profile prepared. Next, run proxyctl system start."))
            }
        }
    case "status", "nodes":
        guard rest.isEmpty || rest == ["--json"] else { throw UserError("未知的系统状态选项。") }
        guard let installed = ProtectedService.installedStatus() else {
            if action == "status" && rest == ["--json"] { print("null"); return }
            print("系统隧道尚未准备。")
            return
        }
        if action == "nodes" {
            try showInventory(Inventory(source: "system", nodes: installed.nodes), order: installed.order,
                              selected: installed.selectedNode, json: rest == ["--json"])
        } else if rest == ["--json"] {
            try printJSON(installed)
        } else {
            systemStatusLines(installed).forEach { print($0) }
        }
    case "trial", "keep", "rollback", "check", "stop", "enable", "disable":
        guard rest.isEmpty else { throw UserError("此命令无需额外参数。") }
        try runInstalledSystemCommand(action)
    case "rules":
        if rest == ["add"], tty {
            let status = ProtectedService.installedStatus()
            if let change = try promptForRule(nodeNames: status?.nodeRuleTargets ?? [], hasUpstream: status?.hasUpstream == true) {
                try runInstalledSystemCommand("rules", change)
            }
        } else {
            try runInstalledSystemCommand("rules", rest)
        }
    case "use":
        guard rest.count == 1 else { throw UserError("用法：proxyctl system use NODE | --auto") }
        try runInstalledSystemCommand(action, rest)
    default:
        throw UserError("未知的系统命令。运行 proxyctl system 查看用法。")
    }
}

func firewall(_ args: [String]) throws {
    switch args {
    case [], ["status"]:
        if let status = ProtectedService.installedStatus() { systemStatusLines(status).forEach { print($0) } }
        else { print("Proxyctl PF 防护未加载。") }
    case ["plan"]:
        try PacketFilter.validate()
        print(PacketFilter.rules)
    case ["on"]:
        try runInstalledSystemCommand("protect")
    default:
        throw UserError("用法：proxyctl firewall status | plan | on")
    }
}
