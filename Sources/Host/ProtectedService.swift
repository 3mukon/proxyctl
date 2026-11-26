import Darwin
import Foundation
import SystemConfiguration

struct ProtectionStatus: Codable {
    let phase: ProtectionPhase
    let engineRunning: Bool
    let firewallLoaded: Bool
    let secondsLeft: Int?
    let selectedNode: String?
    let nodes: [Node]
    let order: [String]
    let lastError: String?
    let hasUpstream: Bool
    let startsAtBoot: Bool
    let verified: Bool
    let nodeRuleTargets: [String]
    let groupRuleTargets: [String]
    let sourceRevision: String
    let fallback: RuleTarget
    let routingRevision: String
    let groups: [ProxyGroupStatus]
}

struct ProtectedService {
    static let base = URL(fileURLWithPath: "/Library/Application Support/Proxyctl System", isDirectory: true)
    static let runtime = URL(fileURLWithPath: "/private/var/run/proxyctl", isDirectory: true)
    static let cli = base.appendingPathComponent("proxyctl")
    static let coreLabel = "local.proxyctl.tunnel"
    static let guardLabel = "local.proxyctl.guard"
    static let guardJob = URL(fileURLWithPath: "/Library/LaunchDaemons/\(guardLabel).plist")
    static let publicStatus = base.appendingPathComponent("status.json")
    static let interval: TimeInterval = 240
    private static let commandLockWait: TimeInterval = 15
    private static let dnsKey = "State:/Network/Service/local.proxyctl.tunnel/DNS" as CFString

    private let privateState = base.appendingPathComponent("private", isDirectory: true)
    private var recordFile: URL { privateState.appendingPathComponent("state.json") }
    private var routingRollback: RoutingRollback {
        RoutingRollback(config: privateState.appendingPathComponent("profile.json"))
    }
    private var coreJob: URL { privateState.appendingPathComponent("tunnel.plist") }
    private var sessionGuardJob: URL { privateState.appendingPathComponent("guard.plist") }
    private var startsAtBoot: Bool { FileManager.default.fileExists(atPath: Self.guardJob.path) }
    private var filter: PacketFilter { PacketFilter(directory: Self.runtime) }
    private var paths: Paths {
        get throws { try Paths(state: privateState, core: Self.base.appendingPathComponent("sing-box")) }
    }

    static func installedStatus() -> ProtectionStatus? {
        try? JSONDecoder().decode(ProtectionStatus.self, from: localData(publicStatus))
    }

    static func asAdministrator(_ arguments: [String], executable: URL, input: Data? = nil) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            let start = commandExample("system start")
            throw UserError(localized("请先运行 \(start)。", "Run \(start) first."))
        }
        if geteuid() != 0, isatty(STDIN_FILENO) != 1 && isatty(STDERR_FILENO) != 1 {
            throw UserError(localized("请在终端运行这条命令，macOS 会请求管理员认证。",
                                      "Run this command in a terminal so macOS can request administrator authentication."))
        }
        let result = try runForeground("/usr/bin/sudo", [executable.path] + arguments, input: input)
        try checkedStatus(result)
    }

    static func isInstalledDriver() -> Bool {
        geteuid() == 0 && Bundle.main.executableURL?.resolvingSymlinksInPath() == cli
    }

    static func bootID() throws -> String {
        let result = try run("/usr/sbin/sysctl", ["-n", "kern.bootsessionuuid"], quiet: true)
        let value = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, UUID(uuidString: value) != nil else { throw UserError("无法读取本次启动标识。") }
        return value
    }

    private func rootDirectory(_ directory: URL, mode: Int) throws {
        if mkdir(directory.path, mode_t(mode)) == 0 {
            guard chmod(directory.path, mode_t(mode)) == 0 else { throw UserError("无法设置系统目录权限。") }
        } else if errno != EEXIST {
            throw UserError("无法创建系统目录。")
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == mode_t(mode) else {
            throw UserError("系统目录的所有者或权限不符合要求。")
        }
    }

    private func secureState() throws {
        guard geteuid() == 0 else { throw UserError("这项操作需要管理员权限。") }
        try rootDirectory(Self.base, mode: 0o755)
        try rootDirectory(privateState, mode: 0o700)
        try rootDirectory(Self.runtime, mode: 0o700)
    }

    private func record() throws -> ProtectionRecord {
        try JSONDecoder().decode(ProtectionRecord.self, from: localData(recordFile))
    }

    private func save(_ state: ProtectionRecord) throws {
        try savePrivate(try JSONEncoder().encode(state), to: recordFile)
    }

    private func publish(_ state: ProtectionRecord, error: String? = nil) throws {
        let running = localJobPID(Self.coreLabel) != nil
        let engine = try Engine(paths, system: true)
        let name = running ? try? engine.current() : nil
        let remaining = state.deadline.map { max(0, Int($0 - ProcessInfo.processInfo.systemUptime)) }
        let summary = ProtectionStatus(phase: state.phase, engineRunning: running,
                                       firewallLoaded: filter.active(), secondsLeft: remaining,
                                       selectedNode: name, nodes: engine.profile.nodes,
                                       order: engine.profile.order, lastError: error,
                                       hasUpstream: engine.profile.upstream != nil, startsAtBoot: startsAtBoot,
                                       verified: state.verified, nodeRuleTargets: engine.profile.routing.ruleNodes,
                                       groupRuleTargets: engine.profile.routing.ruleGroups,
                                       sourceRevision: state.sourceRevision, fallback: engine.profile.routing.fallback,
                                       routingRevision: try engine.profile.routing.policy.revision(),
                                       groups: engine.groupStatus(running: running))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(summary)
        if (try? localData(Self.publicStatus)) != data {
            try data.write(to: Self.publicStatus, options: .atomic)
            guard chmod(Self.publicStatus.path, 0o644) == 0 else { throw UserError("无法发布系统服务状态。") }
        }
    }

    func install(from bundle: Paths, submission: SystemSubmission, selected: String, activate: Bool = false) throws {
        try secureState()
        try paths.locked(waitingUpTo: Self.commandLockWait) {
            let previousState = FileManager.default.fileExists(atPath: recordFile.path) ? try record() : nil
            if let previousState, previousState.phase != .prepared {
                throw UserError("请先回退正在运行的系统部署，再准备新配置。")
            }
            guard !jobLoaded(Self.coreLabel), !filter.hasTransaction,
                  let executable = Bundle.main.executableURL else {
                throw UserError("系统试用状态尚未清理。请运行 proxyctl system rollback。")
            }
            if activate { _ = try TunnelCheck.preflight() }
            let preview = try loadObject(submission.profile)
            let checked = try ManagedProfile(preview)
            guard checked.upstream != nil || !submission.rules.contains(where: { $0.target == .upstream }) else {
                throw UserError(localized("存在缺少外部出站的规则。", "A rule refers to an unconfigured upstream."))
            }
            let id = UUID()
            let files = RuleFiles(state: privateState, id: id, nodeNames: checked.nodes.map(\.name),
                                  groupNames: checked.routing.groupNames)
            let profile = try SystemProfile(preview, first: selected, rulesID: id)
            let candidate = privateState.appendingPathComponent("candidate-\(UUID().uuidString).json")
            let destination = try paths
            let previous = try? ManagedProfile(loadObject(localData(destination.config)), system: true)
            let prepared = ProtectionRecord(sourceRevision: try submission.sourceRevision())
            try files.create(submission.rules)
            var profileSaved = false
            defer {
                try? FileManager.default.removeItem(at: candidate)
                if !profileSaved { try? FileManager.default.removeItem(at: files.directory) }
            }
            try savePrivate(jsonData(profile.config), to: candidate)
            try installFile(bundle.core, at: destination.core)
            try destination.coreCheck(candidate)
            if executable.resolvingSymlinksInPath() != Self.cli {
                try installFile(executable.resolvingSymlinksInPath(), at: Self.cli)
            }
            try writeJob(coreJob, label: Self.coreLabel, action: "_engine", interval: nil)
            if !activate { try removeBootJob() }
            // An interrupted replacement must leave the watchdog with an unverified profile.
            try save(prepared)
            guard rename(candidate.path, destination.config.path) == 0 else {
                if let previousState { try save(previousState) }
                else { try FileManager.default.removeItem(at: recordFile) }
                throw UserError("无法保存系统配置。")
            }
            profileSaved = true
            if let previousFiles = previous?.routing.ruleFiles(in: privateState) {
                try? FileManager.default.removeItem(at: previousFiles.directory)
            }
            try publish(prepared)
            if activate { try startDeployment() }
        }
    }

    private func installFile(_ source: URL, at destination: URL) throws {
        let staging = Self.base.appendingPathComponent(".install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try checkedStatus(run("/usr/bin/install", ["-o", "root", "-g", "wheel", "-m", "755", source.path, staging.path],
                              capture: false))
        guard rename(staging.path, destination.path) == 0 else { throw UserError("无法安装系统运行文件。") }
    }

    private func writeJob(_ path: URL, label: String, action: String, interval: Int?) throws {
        var job: [String: Any] = [
            "Label": label, "ProgramArguments": [Self.cli.path, "system", action],
            "RunAtLoad": true, "WorkingDirectory": privateState.path, "Umask": 0o077
        ]
        if let interval { job["StartInterval"] = interval }
        else { job["KeepAlive"] = true; job["ThrottleInterval"] = 5 }
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        if path == Self.guardJob, FileManager.default.fileExists(atPath: path.path) {
            let previous = try PropertyListSerialization.propertyList(from: localData(path), format: nil)
            guard let existing = previous as? NSDictionary, existing.isEqual(to: job) else {
                throw UserError("同名的 launchd 守护服务已有其他配置。")
            }
        }
        try data.write(to: path, options: .atomic)
        guard chmod(path.path, 0o644) == 0 else { throw UserError("无法设置 launchd 清单权限。") }
        try checkedStatus(run("/usr/bin/plutil", ["-lint", "-s", path.path], quiet: true))
    }

    private func jobLoaded(_ label: String) -> Bool {
        (try? run("/bin/launchctl", ["print", "system/\(label)"], quiet: true).status) == 0
    }

    private func launch(_ label: String, _ plist: URL) throws {
        if !jobLoaded(label) {
            let result = try run("/bin/launchctl", ["bootstrap", "system", plist.path], mergeError: true)
            guard result.status == 0, jobLoaded(label) else {
                throw UserError("启动 \(label) 失败 · \(terminalText(result.text))")
            }
        }
    }

    private func ensureGuard() throws {
        try writeJob(sessionGuardJob, label: Self.guardLabel, action: "_watch", interval: 4)
        try launch(Self.guardLabel, sessionGuardJob)
    }

    private func stopCore() throws {
        if jobLoaded(Self.coreLabel) {
            try checkedStatus(run("/bin/launchctl", ["bootout", "system/\(Self.coreLabel)"], capture: false))
        }
        for _ in 0..<30 {
            if !jobLoaded(Self.coreLabel) && if_nametoindex(Tunnel.name) == 0 { return }
            usleep(200_000)
        }
        throw UserError("系统隧道尚未退出。请稍后重试 system rollback。")
    }

    private func setDNS(_ enabled: Bool) throws {
        guard let store = SCDynamicStoreCreate(nil, "Proxyctl" as CFString, nil, nil) else {
            throw UserError("无法连接系统 DNS 状态。")
        }
        let value: [String: Any] = [
            "ServerAddresses": [Tunnel.dns4, Tunnel.dns6], "SupplementalMatchDomains": [""],
            "SupplementalMatchOrders": [0], "SupplementalMatchDomainsNoSearch": 1,
            "InterfaceName": Tunnel.name
        ]
        if enabled {
            if let existing = SCDynamicStoreCopyValue(store, Self.dnsKey), CFEqual(existing, value as CFDictionary) { return }
            guard SCDynamicStoreSetValue(store, Self.dnsKey, value as CFDictionary) else {
                throw UserError("无法配置隧道 DNS。")
            }
        } else if SCDynamicStoreCopyValue(store, Self.dnsKey) != nil {
            guard SCDynamicStoreRemoveValue(store, Self.dnsKey) else { throw UserError("无法移除隧道 DNS。") }
        }
    }

    private func startCore(deadline: TimeInterval? = nil) throws -> Engine {
        try TunnelCheck.checkDeadline(deadline)
        try launch(Self.coreLabel, coreJob)
        let engine = try Engine(paths, system: true)
        for _ in 0..<35 {
            try TunnelCheck.checkDeadline(deadline)
            if TunnelCheck.routed, (try? engine.current()) != nil {
                try setDNS(true)
                return engine
            }
            usleep(200_000)
        }
        throw UserError("系统 TUN 未通过 IPv4 和 IPv6 路由就绪检查。")
    }

    func launchCore() throws {
        guard getgrgid(PacketFilter.gid) == nil, setgroups(0, nil) == 0, setgid(PacketFilter.gid) == 0,
              getegid() == PacketFilter.gid else { throw UserError("无法设置 sing-box 专用网络身份。") }
        let paths = try paths
        try ManagedCore(paths, system: true).wait()
    }

    private func verifyTrialPath(_ engine: Engine, deadline: TimeInterval?, phase: String,
                                 changedTargets: Set<RuleTarget>? = nil) throws {
        do {
            try TunnelCheck.dataPath(engine, deadline: deadline, changedTargets: changedTargets)
        } catch {
            throw UserError("\(phase) · \(error.localizedDescription)")
        }
    }

    func applyRouting(_ update: RoutingUpdate) throws {
        try secureState()
        let paths = try paths
        try paths.locked(waitingUpTo: Self.commandLockWait) {
            let state = try record()
            guard state.phase == .protected, state.verified, filter.active(), jobLoaded(Self.guardLabel),
                  TunnelCheck.routed, try !TunnelCheck.competingVPNActive() else {
                throw UserError(localized("系统隧道和 PF 就绪后才能应用策略。",
                                          "The system tunnel and PF must be healthy to apply routing settings."))
            }
            guard !routingRollback.pending else {
                throw UserError(localized("系统正在恢复上一份路由配置，请稍后重试。", "The previous routing policy is being restored. Try again shortly."))
            }
            let engine = try Engine(paths, system: true)
            let currentNode = try engine.current()
            let old = try localData(paths.config)
            let candidate = try update.candidate(from: loadObject(old))
            let next = try ManagedProfile(candidate, system: true)
            let oldFiles = engine.profile.routing.ruleFiles(in: paths.state)
            let nextFiles = next.routing.ruleFiles(in: paths.state)
            let rules = try oldFiles?.list() ?? []
            let nextTargets = next.routing.activeTargets(rules)
            let expanded = next.routing.expandedTargets(since: engine.profile.routing)
            let changedGroups = next.routing.groups.filter {
                nextTargets.contains($0.target) && (expanded.contains($0.target) || !engine.profile.routing.groups.contains($0))
            }
            let orderChanged = engine.profile.order != next.order
            let selections = try engine.healthyMembers(for: changedGroups, defaultOrder: orderChanged ? next.order : nil)
            var committed = false
            defer {
                if let oldFiles, let nextFiles, oldFiles.groupNames != nextFiles.groupNames {
                    if committed { oldFiles.removeGroupSlots(omittedFrom: nextFiles) }
                    else if !routingRollback.pending { nextFiles.removeGroupSlots(omittedFrom: oldFiles) }
                }
            }
            // The independent watchdog must know how to restore the previous config before the core is restarted.
            guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
                throw UserError("Could not locate the system driver.")
            }
            let changed = orderChanged || engine.profile.routing.policy != update.policy
            let checked = privateState.appendingPathComponent("routing-candidate-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: checked) }
            if changed {
                if let oldFiles, let nextFiles, oldFiles.groupNames != nextFiles.groupNames {
                    try nextFiles.prepareGroupSlots(previous: oldFiles)
                }
                try savePrivate(jsonData(candidate), to: checked)
                try paths.coreCheck(checked)
            }
            if executable != Self.cli, try localData(executable) != localData(Self.cli) {
                try installFile(executable, at: Self.cli)
            }
            guard changed else {
                try publish(state)
                print(localized("系统路由已使用这份策略。", "The system is already using this routing policy."))
                return
            }
            try routingRollback.arm(old)
            do {
                try stopCore()
                guard rename(checked.path, paths.config.path) == 0 else {
                    throw UserError(localized("无法替换系统路由配置。", "Could not replace the system routing configuration."))
                }
                let deadline = ProcessInfo.processInfo.systemUptime + Self.interval
                let restarted = try startCore(deadline: deadline)
                if !orderChanged { try restarted.select(currentNode) }
                for (target, member) in selections { try restarted.select(member, in: target) }
                try verifyTrialPath(restarted, deadline: deadline,
                                    phase: localized("路由更新验证", "Routing validation"),
                                    changedTargets: expanded.union(selections.map { $0.0 }))
                guard filter.active() else {
                    throw UserError(localized("PF 防护未就绪。", "PF protection is not ready."))
                }
                try routingRollback.commit()
                committed = true
            } catch {
                let failure = error
                do {
                    try recoverRouting(restart: true)
                } catch {
                    throw UserError(localized("路由应用失败，守护服务将继续恢复上一份配置。\n\(failure.localizedDescription)",
                                              "Routing update failed. The watchdog will continue restoring the previous policy.\n\(failure.localizedDescription)"))
                }
                try? publish(state)
                throw UserError(localized("已恢复原系统策略。\n\(failure.localizedDescription)",
                                          "Restored the previous system policy.\n\(failure.localizedDescription)"))
            }
            if (try? publish(state)) == nil {
                print(localized("状态面板将在守护服务下次检查时刷新。", "The status panel will refresh on the next watchdog check."))
            }
            print(localized("新策略已在系统代理上生效。", "The new routing policy is active."))
        }
    }

    private func recoverRouting(restart: Bool) throws {
        try routingRollback.restore(stop: {
            if restart {
                try filter.enable()
                try stopCore()
            }
        }, start: {
            guard restart else { return }
            _ = try startCore()
            guard filter.active() else { throw UserError("PF protection is not ready.") }
        })
    }

    func trial(manual: Bool = true) throws {
        let state = try record()
        guard state.phase == .prepared, !filter.hasTransaction, !jobLoaded(Self.coreLabel) else {
            throw UserError("现有试用需要先回退。")
        }
        let uplink = try TunnelCheck.preflight()
        let engine = try Engine(paths, system: true)
        guard portAvailable(engine.profile.port), portAvailable(engine.profile.controllerPort) else {
            throw UserError("端口已被占用。请先结束回环预览或选择不同端口。")
        }
        try ensureGuard()
        let trial = ProtectionRecord(phase: .tunnelTrial,
                                     deadline: ProcessInfo.processInfo.systemUptime + Self.interval,
                                     bootID: try Self.bootID(), uplink: uplink, sourceRevision: state.sourceRevision)
        try save(trial)
        do {
            let engine = try startCore(deadline: trial.deadline)
            let rules = try engine.profile.routing.ruleFiles(in: paths.state)?.list() ?? []
            let targets = engine.profile.routing.activeTargets(rules)
            let groups = engine.profile.routing.groups.filter { targets.contains($0.target) }
            for (target, member) in try engine.healthyMembers(for: groups) { try engine.select(member, in: target) }
            try verifyTrialPath(engine, deadline: trial.deadline,
                                phase: localized("首次 TUN 检查", "Initial TUN check"))
            try publish(trial)
        } catch {
            let failure = error
            try stop(keepVerification: false)
            throw failure
        }
        if manual {
            print("TUN 试用已通过。4 分钟内可运行 proxyctl firewall on 验证防护，或运行 proxyctl system rollback。")
        } else {
            print(localized("首次 TUN 检查已通过。", "Initial TUN check passed."))
        }
        fflush(stdout)
    }

    func activateFirewall(manual: Bool = true) throws {
        var state = try record()
        guard state.phase == .tunnelTrial, let uplink = state.uplink,
              !state.expired(bootID: try Self.bootID(), now: ProcessInfo.processInfo.systemUptime),
              jobLoaded(Self.guardLabel) else { throw UserError("需要先完成仍在计时中的 TUN 试用。") }
        let engine = try Engine(paths, system: true)
        try verifyTrialPath(engine, deadline: state.deadline,
                            phase: localized("PF 挂载前的 TUN 复检", "TUN recheck before loading PF"))
        guard try !TunnelCheck.competingVPNActive() else { throw TunnelCheck.pauseVPN }
        state.phase = .firewallTesting
        if manual { state.deadline = ProcessInfo.processInfo.systemUptime + Self.interval }
        try save(state)
        do {
            try filter.enable()
            try TunnelCheck.checkDeadline(state.deadline)
            try TunnelCheck.proveDrop(filter, uplink: uplink)
            try verifyTrialPath(engine, deadline: state.deadline,
                                phase: localized("PF 挂载后的 TUN 复检", "TUN recheck after loading PF"))
            state.phase = .firewallTrial
            try save(state)
            try publish(state)
        } catch {
            let failure = error
            try filter.disable()
            state.phase = .tunnelTrial
            try save(state)
            try publish(state)
            throw failure
        }
        if manual {
            print("PF 和 TUN 探测通过。4 分钟内运行 proxyctl system keep 保留设置。")
        } else {
            print(localized("独立 PF 防护已通过。", "Independent PF protection verified."))
        }
        fflush(stdout)
    }

    func keep(recheck: Bool = true) throws {
        let state = try record()
        guard state.phase == .firewallTrial, filter.active(), jobLoaded(Self.guardLabel),
              !state.expired(bootID: try Self.bootID(), now: ProcessInfo.processInfo.systemUptime) else {
            throw UserError("当前没有通过防火墙验证的系统试用。")
        }
        if recheck {
            try verifyTrialPath(Engine(paths, system: true), deadline: state.deadline,
                                phase: localized("确认前的 TUN 复检", "TUN recheck before confirmation"))
        }
        guard try !TunnelCheck.competingVPNActive() else { throw TunnelCheck.pauseVPN }
        guard !state.expired(bootID: try Self.bootID(), now: ProcessInfo.processInfo.systemUptime), filter.active() else {
            throw UserError("验证期间试用已到期或防护发生变化。")
        }
        let committed = ProtectionRecord(phase: .protected, bootID: try Self.bootID(), verified: true,
                                         sourceRevision: state.sourceRevision)
        try save(committed)
        try publish(committed)
        print(localized("系统代理与独立 PF 已启用。", "System proxy and independent PF are running."))
    }

    func startExisting(expectedRevision: String) throws {
        try secureState()
        try paths.locked(waitingUpTo: Self.commandLockWait) {
            if try record().sourceRevision != expectedRevision {
                throw UserError(localized("系统配置已变化，请重新启动。", "The system profile changed. Run start again."))
            }
            try startDeployment()
        }
    }

    private func startDeployment() throws {
        let state = try record()
        if state.phase == .protected { try recoverRouting(restart: true) }
        let needsTrial = state.phase == .prepared && !state.verified
        if !needsTrial && state.phase != .tunnelTrial && state.phase != .firewallTrial {
            try start(state)
            print(localized("系统代理已启动。", "System proxy started."))
            return
        }
        do {
            try completeSystemStartup(
                trial: { if needsTrial { try trial(manual: false) } },
                firewall: { if state.phase != .firewallTrial { try activateFirewall(manual: false) } },
                keep: { try keep(recheck: state.phase == .firewallTrial) },
                rollback: { try stop(keepVerification: false) }
            )
        } catch let failure as SystemStartupFailure {
            if let rollback = failure.rollback {
                throw UserError(localized(
                    "\(failure.cause.localizedDescription) · 回退遇到错误（\(rollback.localizedDescription)）。请运行 \(commandExample("system rollback"))。",
                    "\(failure.cause.localizedDescription) · Rollback failed (\(rollback.localizedDescription)). Run \(commandExample("system rollback"))."
                ))
            }
            try? publish(record(), error: failure.cause.localizedDescription)
            throw UserError(localized("\(failure.cause.localizedDescription) · 已回退本次启动。",
                                      "\(failure.cause.localizedDescription) · Startup rolled back."))
        }
    }

    private func start(_ state: ProtectionRecord) throws {
        let boot = try Self.bootID()
        if state.phase == .protected, filter.active(), TunnelCheck.routed {
            var running = state
            running.bootID = boot
            try save(running)
            try publish(running)
            return
        }
        guard state.verified, state.phase == .prepared || state.phase == .protected,
              !filter.hasTransaction, !jobLoaded(Self.coreLabel) else {
            throw UserError(localized("系统部署尚未完成清理，请先执行回退。",
                                      "The previous deployment is still present. Roll it back first."))
        }
        _ = try TunnelCheck.preflight()
        let engine = try Engine(paths, system: true)
        guard portAvailable(engine.profile.port), portAvailable(engine.profile.controllerPort) else {
            throw UserError(localized("代理端口已被占用。", "A proxy port is already in use."))
        }
        try ensureGuard()
        let transition = ProtectionRecord(phase: .starting,
                                          deadline: ProcessInfo.processInfo.systemUptime + Self.interval,
                                          bootID: boot, verified: true, sourceRevision: state.sourceRevision)
        try save(transition)
        do {
            try filter.enable()
            _ = try startCore(deadline: transition.deadline)
            try TunnelCheck.checkDeadline(transition.deadline)
            guard filter.active() else { throw UserError(localized("PF 防护未就绪。", "PF protection is not ready.")) }
            let active = ProtectionRecord(phase: .protected, bootID: boot, verified: true, sourceRevision: state.sourceRevision)
            try save(active)
            try publish(active)
        } catch {
            let failure = error
            try stop(keepVerification: true)
            throw failure
        }
    }

    private func stop(keepVerification: Bool) throws {
        let state = try record()
        let stopped = ProtectionRecord(phase: .prepared, bootID: (try? Self.bootID()) ?? state.bootID,
                                       verified: keepVerification && state.verified, sourceRevision: state.sourceRevision)
        if state.phase != .prepared || jobLoaded(Self.coreLabel) {
            var pending = stopped
            pending.phase = .rollingBack
            try save(pending)
            try stopCore()
        }
        try recoverRouting(restart: false)
        try setDNS(false)
        try filter.disable()
        try save(stopped)
        try publish(stopped)
        if !startsAtBoot { try unloadGuard() }
    }

    private func removeBootJob() throws {
        if FileManager.default.fileExists(atPath: Self.guardJob.path) {
            let manifest = try PropertyListSerialization.propertyList(from: localData(Self.guardJob), format: nil)
            guard let job = manifest as? [String: Any],
                  job["ProgramArguments"] as? [String] == [Self.cli.path, "system", "_watch"] else {
                throw UserError("守护服务已由其他配置接管。")
            }
            try FileManager.default.removeItem(at: Self.guardJob)
        }
    }

    private func unloadGuard() throws {
        if jobLoaded(Self.guardLabel) {
            try checkedStatus(run("/bin/launchctl", ["bootout", "system/\(Self.guardLabel)"], capture: false))
        }
    }

    func watch() throws {
        var state = try record()
        do {
            if state.phase == .rollingBack {
                try stop(keepVerification: state.verified)
                return
            }
            let boot = try Self.bootID()
            if let resumed = state.resumedAtBoot(boot, enabled: startsAtBoot) {
                // A verified boot recovery keeps its protection intent while the uplink comes up.
                try save(resumed)
                state = resumed
            }
            if state.expired(bootID: boot, now: ProcessInfo.processInfo.systemUptime) {
                try stop(keepVerification: state.verified)
                return
            }
            if state.phase == .prepared {
                if !startsAtBoot { try unloadGuard() }
                return
            }
            if state.phase == .protected {
                try filter.enable()
                try recoverRouting(restart: true)
                if TunnelCheck.routed, localJobPID(Self.coreLabel) != nil {
                    try setDNS(true)
                } else {
                    try stopCore()
                    _ = try TunnelCheck.preflight()
                    _ = try startCore()
                }
            }
            try publish(state)
        } catch {
            try publish(try record(), error: error.localizedDescription)
            throw error
        }
    }

    private func configureAutostart(_ enabled: Bool) throws {
        let state = try record()
        if enabled {
            guard state.verified, state.phase == .prepared || state.phase == .protected else {
                throw UserError(localized("请先完成系统试用与 PF 验收。", "Complete the system and PF trials before enabling autostart."))
            }
            try writeJob(Self.guardJob, label: Self.guardLabel, action: "_watch", interval: 4)
        } else {
            try removeBootJob()
        }
        try publish(state)
        if !enabled && state.phase == .prepared { try unloadGuard() }
    }

    func check() throws {
        let state = try record()
        guard state.phase != .prepared && state.phase != .rollingBack else { throw UserError("系统隧道尚未运行。") }
        try TunnelCheck.dataPath(Engine(paths, system: true))
        if (state.phase == .protected || state.phase == .firewallTrial) && !filter.active() {
            throw UserError("PF 防护检查失败。")
        }
        try publish(state)
        print("IPv4、IPv6 路由和 TUN 连通性已通过 · PF \(filter.active() ? "生效" : "待验证")")
    }

    private func rules(_ args: [String]) throws {
        let engine = try Engine(paths, system: true)
        let files = engine.profile.routing.ruleFiles(in: privateState)
        if args.isEmpty || args == ["--json"] {
            try printRules(files?.list() ?? [], json: args == ["--json"], hasUpstream: engine.profile.upstream != nil,
                           fallback: engine.profile.routing.fallback)
            return
        }
        guard let files else {
            throw UserError(localized("请用新版重新准备系统配置后再编辑规则。", "Prepare the system profile with this release before editing its rules."))
        }
        let change = try RuleChange(args, hasUpstream: engine.profile.upstream != nil,
                                    nodeNames: engine.profile.nodes.map(\.name), groupNames: files.groupNames)
        try files.update(change)
        print(ruleChangeMessage(change))
    }

    func perform(_ action: String, _ args: [String]) throws {
        guard Self.isInstalledDriver(), FileManager.default.fileExists(atPath: recordFile.path) else {
            throw UserError("请先准备系统配置。")
        }
        if action == "_engine", args.isEmpty {
            try launchCore()
            return
        }
        if action == "_watch", args.isEmpty {
            try secureState()
            do { try paths.locked { try watch() } }
            catch is OperationLockBusy { return }
            return
        }
        try manage(action, args)
    }

    func manage(_ action: String, _ args: [String]) throws {
        guard FileManager.default.isExecutableFile(atPath: Self.cli.path),
              FileManager.default.fileExists(atPath: recordFile.path) else {
            let start = commandExample("system start")
            throw UserError(localized("请先运行 \(start)。", "Run \(start) first."))
        }
        try secureState()
        try paths.locked(waitingUpTo: Self.commandLockWait) {
            switch (action, args.count) {
            case ("trial", 0): try trial()
            case ("protect", 0): try activateFirewall()
            case ("keep", 0): try keep()
            case ("start", 0): try startDeployment()
            case ("stop", 0):
                try stop(keepVerification: true)
                print(localized("系统代理已停止。", "System proxy stopped."))
            case ("enable", 0):
                try configureAutostart(true)
                print(localized("开机自启已启用。", "Start at boot enabled."))
            case ("disable", 0):
                try configureAutostart(false)
                print(localized("开机自启已停用。", "Start at boot disabled."))
            case ("rollback", 0):
                try removeBootJob()
                try stop(keepVerification: false)
                print("已回退系统隧道、DNS 和 Proxyctl 的 PF 规则。")
            case ("check", 0): try check()
            case ("rules", _): try rules(args)
            default: throw UserError("未知的系统服务操作。")
            }
        }
    }
}
