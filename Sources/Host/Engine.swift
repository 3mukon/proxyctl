import Darwin
import Foundation

let probeURL = "https://www.gstatic.com/generate_204"

struct ProxyGroupStatus: Codable, Equatable {
    let name: String
    let order: [String]
    let selectedNode: String?
}

struct Engine {
    let paths: Paths
    let profile: ManagedProfile

    init(_ paths: Paths, system: Bool = false) throws {
        self.paths = paths
        guard FileManager.default.fileExists(atPath: paths.config.path) else {
            throw UserError(localized("还没有导入节点。用 \(commandExample("nodes add")) 添加。",
                                      "Import nodes with \(commandExample("nodes add")) first."))
        }
        profile = try ManagedProfile(loadObject(localData(paths.config)), system: system)
    }

    func requireListener() throws {
        guard isCoreListener(port: profile.controllerPort, core: paths.core) else {
            let status = commandExample("status")
            throw UserError(localized("Proxyctl 内核未在运行。用 \(status) 查看全机接管状态。",
                                      "The Proxyctl core is stopped. See \(status) for system capture status."))
        }
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) throws -> Data {
        try requireListener()
        var args = ["-q", "--noproxy", "*", "--proto", "=http", "--max-time", "9", "--connect-timeout", "2",
                    "-fsS", "--request", method, "--config", "-"]
        if let body { args += ["--json", String(decoding: body, as: UTF8.self)] }
        args.append("http://127.0.0.1:\(profile.controllerPort)" + path)
        let header = Data("header = \"Authorization: Bearer \(profile.secret)\"\n".utf8)
        let result = try run("/usr/bin/curl", args, input: header, quiet: true)
        guard result.status == 0 else { throw UserError(localized("本机控制接口或节点探测失败。", "The local control request or node check failed.")) }
        return result.output
    }

    private func proxyPath(_ name: String) throws -> String {
        let pathChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let tag = name.addingPercentEncoding(withAllowedCharacters: pathChars) else { throw ProxyGroup.invalid }
        return "/proxies/" + tag
    }

    func current(in group: RuleTarget = .proxy) throws -> String {
        let order = profile.order(for: group)
        let result = try loadObject(request(proxyPath(group.outbound)))
        guard let current = result["now"] as? String, order.contains(current), result["all"] as? [String] == order else {
            throw UserError(localized("运行中策略组与本机配置不一致。", "The running selector does not match the local profile."))
        }
        return current
    }

    func groupStatus(running: Bool) -> [ProxyGroupStatus] {
        profile.routing.groups.map { group in
            ProxyGroupStatus(name: group.name, order: group.order, selectedNode: running ? try? current(in: group.target) : nil)
        }
    }

    func healthyMembers(for groups: [ProxyGroup], defaultOrder: [String]? = nil) throws -> [(RuleTarget, String)] {
        var health: [String: Bool] = [:]
        let options = (defaultOrder.map { [(RuleTarget.proxy, $0)] } ?? []) + groups.map { ($0.target, $0.order) }
        return try options.map { target, order in
            let group = ProxyGroup(name: target.groupName ?? target.displayName, order: order)
            let member = try group.firstReachable { name in
                if let cached = health[name] { return cached }
                let reachable = (try? measure(name, url: probeURL)) != nil
                health[name] = reachable
                return reachable
            }
            return (target, member)
        }
    }

    func checkActive(url: String) throws -> (node: String, delay: Int) {
        let selected = try current()
        guard isCoreListener(port: profile.port, core: paths.core) else { throw UserError(localized("回环代理未就绪。", "The loopback proxy is not ready.")) }
        if URLComponents(string: url)?.scheme?.lowercased() == "http" {
            return (selected, try test(selected, url: url))
        }
        return (selected, try measure(selected, url: url))
    }

    static func validateCheckURL(_ url: String) throws {
        guard url.utf8.count <= 2048, terminalText(url) == url,
              let target = URLComponents(string: url), let host = target.host,
              !host.isEmpty, target.user == nil, target.password == nil,
              let scheme = target.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw UserError(localized("探测使用无凭据的 HTTP(S) 地址。", "Use a credential-free HTTP or HTTPS check URL."))
        }
    }

    func measure(_ name: String, url: String) throws -> Int {
        try Self.validateCheckURL(url)
        // Clash uses its own trust context and rewrites HTTP URLs.
        // Custom probes use the same isolated path as the explicit test command.
        if url != probeURL {
            return try test(name, url: url)
        }
        var query = URLComponents()
        query.queryItems = [.init(name: "url", value: url), .init(name: "timeout", value: "5000")]
        let result = try loadObject(request(proxyPath(name) + "/delay?" + (query.percentEncodedQuery ?? "")))
        guard let delay = result["delay"] as? Int, delay > 0 else { throw UserError(localized("节点未通过连通性探测。", "The node failed its connectivity check.")) }
        return delay
    }

    func select(_ name: String, in group: RuleTarget = .proxy) throws {
        guard profile.order(for: group).contains(name) else {
            throw UserError(localized("此节点未加入当前策略。", "This node is outside the active policy."))
        }
        if try current(in: group) == name { return }
        _ = try request(proxyPath(group.outbound), method: "PUT", body: try jsonData(["name": name]))
        guard try current(in: group) == name else { throw UserError(localized("内核没有确认选中的节点。", "The core did not confirm the selected node.")) }
    }
}

func localJobPID(_ label: String) -> Int? {
    guard let result = try? run("/bin/launchctl", ["print", "system/\(label)"], quiet: true), result.status == 0 else { return nil }
    return result.text.split(separator: "\n").compactMap { line -> Int? in
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.hasPrefix("pid = ") ? Int(text.dropFirst(6)) : nil
    }.first
}

func portAvailable(_ port: Int) -> Bool {
    (try? withBoundPort(port) { _ in true }) ?? false
}

func withBoundPort<T>(_ port: Int, _ action: (Int32) throws -> T) throws -> T {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    if descriptor < 0 { throw UserError(localized("无法创建回环端口。", "Could not create a loopback socket.")) }
    defer { close(descriptor) }
    var reuse: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
    guard bound else { throw UserError(localized("无法绑定回环端口。", "Could not bind the loopback port.")) }
    return try action(descriptor)
}

private func parentPID(_ child: Int) -> Int? {
    guard let pid = pid_t(exactly: child) else { return nil }
    var process = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, size) == size else { return nil }
    return Int(process.pbi_ppid)
}

struct SystemService {
    let paths: Paths

    var user: String { NSUserName() }
    var arguments: [String] { [serviceDriver, "--state-dir", paths.state.path, "_loopback"] }
    private var legacyArguments: [String] { [serviceCore, "-D", paths.state.path, "run", "-c", paths.config.path] }
    var installed: Bool { FileManager.default.fileExists(atPath: serviceJob) }

    func manifest() -> [String: Any] {
        ["Label": serviceLabel, "ProgramArguments": arguments, "UserName": user,
         "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10,
         "Umask": 0o077, "WorkingDirectory": paths.state.path]
    }

    private func requireDefaultState() throws {
        guard getuid() != 0, paths.state == (try Paths()).state else {
            throw UserError("请用普通登录账号和默认配置目录运行 service，macOS 会单独请求管理员认证。")
        }
        try paths.ensureState()
    }

    private func priv(_ executable: String, _ args: [String]) throws {
        guard isatty(STDIN_FILENO) == 1 || isatty(STDERR_FILENO) == 1 else {
            throw UserError("这项操作需要在终端完成管理员认证。")
        }
        try checkedStatus(runForeground("/usr/bin/sudo", [executable] + args))
    }

    private func isLegacyJob() throws -> Bool {
        var file = stat()
        let dict = (try? PropertyListSerialization.propertyList(from: localData(URL(fileURLWithPath: serviceJob)), options: [], format: nil)) as? [String: Any]
        guard lstat(serviceJob, &file) == 0, file.st_uid == 0, file.st_mode & S_IFMT == S_IFREG,
              dict?["Label"] as? String == serviceLabel, dict?["UserName"] as? String == user,
              let argv = dict?["ProgramArguments"] as? [String],
              argv == arguments || argv == legacyArguments else {
            throw UserError("此服务没有由当前账号的 Proxyctl 安装，或注册文件已改变。")
        }
        return argv == legacyArguments
    }

    func verifyStart(_ profile: ManagedProfile) throws {
        guard portAvailable(profile.port), portAvailable(profile.controllerPort) else {
            throw UserError(localized("回环端口已被占用或不可绑定。先关掉同一个 Proxyctl 预览，或另选端口。", "A loopback port is unavailable. Stop the current preview or choose another port."))
        }
        try paths.coreCheck(paths.config)
    }

    func start() throws {
        try requireDefaultState()
        let legacy = try isLegacyJob()
        if localJobPID(serviceLabel) != nil {
            _ = try Engine(paths).current()
            return
        }
        let profile = try upgradeLoopbackProfile(paths)
        let engine = try Engine(paths)
        try verifyStart(profile)
        try priv("/bin/launchctl", ["bootstrap", "system", serviceJob])
        for _ in 0..<24 {
            if let job = localJobPID(serviceLabel), let listener = listenerPID(port: profile.port),
               listenerPID(port: profile.controllerPort) == listener,
               legacy ? listener == job : parentPID(listener) == job,
               (try? engine.current()) != nil { return }
            usleep(200_000)
        }
        try priv("/bin/launchctl", ["bootout", "system/\(serviceLabel)"])
        throw UserError("本地代理未通过就绪检查，已卸载这次启动的服务。请查看 proxyctl logs。")
    }

    func install() throws {
        try requireDefaultState()
        var previous: Data?
        if installed {
            if try !isLegacyJob() { try start(); return }
            previous = try localData(URL(fileURLWithPath: serviceJob))
            try stop()
        }
        let profile = try upgradeLoopbackProfile(paths)
        try verifyStart(profile)
        guard let driver = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw UserError(localized("无法定位 CLI 安装目录。", "Could not locate the CLI installation."))
        }
        let job = paths.state.appendingPathComponent("service-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: job) }
        try savePrivate(PropertyListSerialization.data(fromPropertyList: manifest(), format: .xml, options: 0), to: job)
        try priv("/usr/bin/install", ["-d", "-o", "root", "-g", "wheel", "-m", "755", serviceBase])
        try priv("/usr/bin/install", ["-o", "root", "-g", "wheel", "-m", "755", paths.core.path, serviceCore])
        try priv("/usr/bin/install", ["-o", "root", "-g", "wheel", "-m", "755", driver.path, serviceDriver])
        try priv("/usr/bin/install", ["-o", "root", "-g", "wheel", "-m", "644", job.path, serviceJob])
        do {
            try start()
        } catch {
            let failure = error
            if let previous {
                try stop()
                try savePrivate(previous, to: job)
                try priv("/usr/bin/install", ["-o", "root", "-g", "wheel", "-m", "644", job.path, serviceJob])
                try start()
            } else {
                try remove()
            }
            throw failure
        }
    }

    func stop() throws {
        try requireDefaultState()
        _ = try isLegacyJob()
        let target = "system/\(serviceLabel)"
        if try run("/bin/launchctl", ["print", target], quiet: true).status == 0 {
            try priv("/bin/launchctl", ["bootout", target])
            for _ in 0..<20 {
                if try run("/bin/launchctl", ["print", target], quiet: true).status != 0 { return }
                usleep(200_000)
            }
            throw UserError("服务仍在停止，请稍后检查状态。")
        }
    }

    func remove() throws {
        try stop()
        try priv("/bin/rm", ["-f", serviceJob, serviceCore, serviceDriver])
    }
}
