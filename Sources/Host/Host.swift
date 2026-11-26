import Darwin
import Foundation

struct UserError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}

extension OperationLockBusy: LocalizedError {
    var errorDescription: String? {
        localized("另一条管理命令正在运行。", "Another management command is running.")
    }
}

var consoleInvocation = ProcessInfo.processInfo.environment["PROXYCTL_CONSOLE"] == "1"

func commandExample(_ arguments: String) -> String {
    (consoleInvocation ? "/" : "proxyctl ") + arguments
}

enum InterfaceLanguage: String, CaseIterable {
    case zh, en

    var name: String { self == .zh ? "简体中文" : "English" }
    static var names: String { allCases.map(\.name).joined(separator: " / ") }
}

var interfaceLanguage = InterfaceLanguage.zh

func localized(_ chinese: String, _ english: String) -> String {
    interfaceLanguage == .zh ? chinese : english
}

func loadInterfaceLanguage(_ paths: Paths) {
    if let override = ProcessInfo.processInfo.environment["PROXYCTL_LANGUAGE"],
       let language = InterfaceLanguage(rawValue: override) {
        interfaceLanguage = language
        return
    }
    var info = stat()
    guard lstat(paths.languageFile.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 16,
          let saved = try? String(contentsOf: paths.languageFile, encoding: .utf8) else { return }
    interfaceLanguage = InterfaceLanguage(rawValue: saved.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .zh
}

func selectInterfaceLanguage(_ language: InterfaceLanguage, paths: Paths) throws {
    try paths.ensureState()
    try savePrivate(Data((language.rawValue + "\n").utf8), to: paths.languageFile)
    interfaceLanguage = language
}

let selectorTag = "proxyctl-selected"

struct Paths {
    let state: URL
    let core: URL

    init(state: URL? = nil, core: URL? = nil) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.state = state ?? home.appendingPathComponent("Library/Application Support/Proxyctl", isDirectory: true)
        guard let executable = Bundle.main.executableURL else { throw UserError(localized("无法定位 CLI 安装目录。", "Could not locate the CLI installation.")) }
        self.core = core ?? executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libexec/sing-box")
    }

    var config: URL { state.appendingPathComponent("profile.json") }
    var log: URL { state.appendingPathComponent("engine.log") }
    var languageFile: URL { state.appendingPathComponent("language") }

    func ensureState() throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(state.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw UserError(localized("配置目录必须归当前账户所有，权限为 700。", "The profile directory must belong to your account and have mode 700."))
        }
    }

    func locked<T>(waitingUpTo timeout: TimeInterval = 0, _ work: () throws -> T) throws -> T {
        try ensureState()
        let descriptor = open(state.appendingPathComponent("operation.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw UserError(localized("无法锁定配置目录。", "Could not lock the profile directory.")) }
        defer { close(descriptor) }
        try acquireOperationLock(descriptor, waitingUpTo: timeout)
        return try work()
    }

    func coreCheck(_ config: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: core.path) else {
            throw UserError(localized("缺少打包的 sing-box 内核。请重新运行安装器。", "The bundled sing-box binary is missing. Run the installer again."))
        }
        let result = try run(core.path, ["-D", state.path, "check", "-c", config.path], quiet: true)
        guard result.status == 0 else {
            throw UserError(localized("sing-box 未通过配置校验。检查协议、字段和文件路径。", "sing-box rejected the configuration. Check its protocols, fields, and file paths."))
        }
    }
}

let maxConfigBytes = 8 * 1024 * 1024

func loadObject(_ data: Data) throws -> [String: Any] {
    guard data.count <= maxConfigBytes, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw UserError(localized("无法读取 sing-box JSON。请提供小于 8 MB 的完整 JSON 文件。", "Provide a complete sing-box JSON file smaller than 8 MB."))
    }
    return object
}

func localData(_ path: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: path)
    defer { try? handle.close() }
    return try handle.read(upToCount: maxConfigBytes + 1) ?? Data()
}

func savePrivate(_ data: Data, to path: URL) throws {
    try data.write(to: path, options: .atomic)
    guard chmod(path.path, 0o600) == 0 else { throw UserError(localized("无法设置本机配置文件的私有权限。", "Could not make the configuration file private.")) }
}

func jsonData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func terminalText(_ value: String) -> String {
    String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
}

func listenerPIDs(host: String, port: Int, user: uid_t? = nil) -> Set<Int> {
    let address = host.contains(":") ? "[\(host)]" : host
    var arguments = ["-nP", "-a", "-iTCP@\(address):\(port)", "-sTCP:LISTEN", "-Fp"]
    if let user { arguments += ["-u", String(user)] }
    guard let result = try? run("/usr/sbin/lsof", arguments, quiet: true) else { return [] }
    return Set(result.text.split(separator: "\n").compactMap { line in
        line.first == "p" ? Int(line.dropFirst()) : nil
    })
}

func listenerPID(port: Int) -> Int? {
    let pids = listenerPIDs(host: "127.0.0.1", port: port, user: getuid())
    return pids.count == 1 ? pids.first : nil
}

func hasListener(port: Int) -> Bool {
    guard let result = try? run("/usr/sbin/lsof", ["-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"], quiet: true) else { return false }
    return result.status == 0 && !result.output.isEmpty
}

func executablePath(of pid: Int) -> String? {
    guard let processID = pid_t(exactly: pid) else { return nil }
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

func isCoreListener(port: Int, core: URL) -> Bool {
    guard let pid = listenerPID(port: port), let executable = executablePath(of: pid) else { return false }
    var actual = stat()
    guard stat(executable, &actual) == 0 else { return false }
    var expected = stat()
    return stat(core.path, &expected) == 0 && actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
}

func ruleChangeMessage(_ change: RuleChange) -> String {
    "\(change.rule.value)  →  \(change.rule.target.displayName) · " +
        (change.add ? localized("已添加", "Added") : localized("已移除", "Removed"))
}

func catchAllLine(_ target: RuleTarget) -> String {
    localized("其余全部", "Everything else") + "  →  " + target.displayName
}

func printRules(_ rules: [CustomRule], json: Bool, hasUpstream: Bool, fallback: RuleTarget) throws {
    if json { try printJSON(rules); return }
    if rules.isEmpty { print(localized("暂无自定义规则。", "No custom rules yet.")) }
    for rule in rules { print("\(rule.value)  →  \(rule.target.displayName)") }
    print(catchAllLine(fallback))
    print(commandExample("rules default"))
    print(commandExample("rules add|remove DOMAIN_OR_CIDR proxy|direct|upstream|group:NAME|node:NAME"))
    if hasUpstream { print(localized("外部出站已配置。", "An external upstream is configured.")) }
}
