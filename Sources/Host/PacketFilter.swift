import Darwin
import Foundation

struct PacketFilter {
    static let anchor = "local.proxyctl.egress"
    static let gid: gid_t = 39991
    static let rootRule = "anchor \"\(anchor)\" out all"

    let directory: URL
    private var snapshot: URL { directory.appendingPathComponent("pf-root.conf") }
    private var reference: URL { directory.appendingPathComponent("pf-token") }
    private var fingerprint: URL { directory.appendingPathComponent("pf-rules") }
    var hasTransaction: Bool { FileManager.default.fileExists(atPath: snapshot.path) }

    static var rules: String {
        """
        pass out all tag PXCTL_CHECK no state
        pass out on lo0 all tag PXCTL_OK no state
        pass out on \(Tunnel.name) all tag PXCTL_OK no state
        pass out proto { tcp udp } all user = 0 group = \(gid) tag PXCTL_OK no state
        block drop out quick proto { tcp udp } from any to any port { 53 853 } ! tagged PXCTL_OK
        pass out inet proto udp from any port 68 to any port 67 tag PXCTL_OK no state
        pass out inet6 proto udp from fe80::/10 port 546 to ff02::1:2 port 547 tag PXCTL_OK no state
        pass out inet6 proto ipv6-icmp from any to any icmp6-type { routersol routeradv neighbrsol neighbradv } tag PXCTL_OK no state
        pass out inet to { 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/24 255.255.255.255 } tag PXCTL_OK no state
        pass out inet6 to { fd00::/8 fe80::/10 ff02::/16 } tag PXCTL_OK no state
        block drop out quick inet proto tcp from any to 1.1.1.1 port 443 ! tagged PXCTL_OK label "proxyctl_probe_v4"
        block drop out quick inet6 proto tcp from any to 2606:4700:4700::1111 port 443 ! tagged PXCTL_OK label "proxyctl_probe_v6"
        block drop out quick inet all ! tagged PXCTL_OK
        block drop out quick inet6 all ! tagged PXCTL_OK

        """
    }

    private static func pf(_ args: [String], input: String? = nil, merged: Bool = false) throws -> String {
        let result = try run("/sbin/pfctl", args, input: input.map { Data($0.utf8) },
                             quiet: !merged, mergeError: merged)
        guard result.status == 0 else {
            let output = terminalText(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            throw UserError("PF \(args.joined(separator: " ")) 失败（\(result.status)）\(output.isEmpty ? "" : " · \(output)")")
        }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validate(root: String = PacketFilterRoot.withAppleDefaults(adding: PacketFilter.rootRule)) throws {
        // Dry parsing opens no live PF transaction.
        _ = try pf(["-n", "-a", anchor, "-f", "-"], input: rules, merged: true)
        _ = try pf(["-n", "-R", "-f", "-"], input: root + "\n", merged: true)
    }

    private static func anchorExists() throws -> Bool {
        // macOS returns EINVAL when asked for rules in an absent anchor.
        try pf(["-s", "Anchors"]).split(whereSeparator: \.isWhitespace).contains(Substring(anchor))
    }

    private static func requireSystemRulesLoaded() throws {
        // The macOS boot job replaces the top-level ruleset when it loads /etc/pf.conf.
        let plist = "/System/Library/LaunchDaemons/com.apple.pfctl.plist"
        guard FileManager.default.fileExists(atPath: plist) else { return }
        let job = try run("/bin/launchctl", ["print", "system/com.apple.pfctl"], quiet: true)
        let fields = job.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard job.status == 0, fields.contains("state = not running"), fields.contains("last exit code = 0") else {
            throw UserError(localized("正在等待 macOS 的 PF 基础规则加载完成。", "Waiting for macOS to load its PF rules."))
        }
    }

    private func savedRoot() throws -> String {
        String(decoding: try localData(snapshot), as: UTF8.self)
    }

    func active() -> Bool {
        guard hasTransaction,
              let status = try? Self.pf(["-si"]), status.hasPrefix("Status: Enabled"),
              let baseline = try? savedRoot(),
              let expected = PacketFilterRoot.adding(Self.rootRule, to: baseline),
              let actualRoot = try? Self.pf(["-sr"]), actualRoot == expected,
              let actualRules = try? Self.pf(["-a", Self.anchor, "-sr"]),
              let expectedRules = try? localData(fingerprint) else { return false }
        return !actualRules.isEmpty && Data(actualRules.utf8) == expectedRules
    }

    func enable() throws {
        if active() { return }
        guard !hasTransaction else { throw UserError("PF 状态与上次记录不同，请先执行 system rollback。") }
        guard getgrgid(Self.gid) == nil else { throw UserError("专用网络组号已被此机占用，停止部署。") }
        try Self.requireSystemRulesLoaded()
        let baseline = try Self.pf(["-sr"])
        guard let protectedRoot = PacketFilterRoot.adding(Self.rootRule, to: baseline) else {
            throw UserError(localized("PF 主规则与受支持的系统规则不符，无法安全挂载防护。",
                                      "The main PF ruleset differs from supported system rules. Protection could not be loaded safely."))
        }
        try Self.validate(root: protectedRoot)
        guard try !Self.anchorExists() || Self.pf(["-a", Self.anchor, "-sr"]).isEmpty else {
            throw UserError(localized("Proxyctl 的 PF 锚点已有规则，无法安全挂载防护。",
                                      "The Proxyctl PF anchor already contains rules. Protection could not be loaded safely."))
        }
        guard try Self.pf(["-ss"]).isEmpty else {
            throw UserError(localized("PF 仍有连接状态，无法安全挂载防护。",
                                      "PF still has connection states. Protection could not be loaded safely."))
        }
        try savePrivate(Data(baseline.utf8), to: snapshot)
        do {
            _ = try Self.pf(["-a", Self.anchor, "-f", "-"], input: Self.rules)
            let loaded = try Self.pf(["-a", Self.anchor, "-sr"])
            guard !loaded.isEmpty else { throw UserError("PF 未加载防护规则。") }
            try savePrivate(Data(loaded.utf8), to: fingerprint)
            _ = try Self.pf(["-R", "-f", "-"], input: protectedRoot + "\n")
            let result = try Self.pf(["-E"], merged: true)
            let token = result.split(separator: "\n").compactMap { line -> UInt64? in
                guard let colon = line.firstIndex(of: ":"), line[..<colon].trimmingCharacters(in: .whitespaces) == "Token" else { return nil }
                return UInt64(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }.first
            guard let token else { throw UserError("PF 未返回本次启用的引用令牌。") }
            try savePrivate(Data(String(token).utf8), to: reference)
            guard active(), try Self.pf(["-ss"]).isEmpty else { throw UserError("无法确认 PF 已接管新连接。") }
        } catch {
            let failure = error
            try disable()
            throw failure
        }
    }

    func disable() throws {
        guard hasTransaction else { return }
        let current = try Self.pf(["-sr"])
        if let baseline = try? savedRoot(),
           let expected = PacketFilterRoot.adding(Self.rootRule, to: baseline), current == expected {
            _ = try Self.pf(["-R", "-f", "-"], input: baseline + "\n")
        }
        if try Self.anchorExists() {
            _ = try Self.pf(["-a", Self.anchor, "-F", "rules"])
        }
        if FileManager.default.fileExists(atPath: reference.path) {
            guard let token = UInt64(String(decoding: try localData(reference), as: UTF8.self)) else {
                throw UserError("PF 引用令牌无效。")
            }
            let references = try Self.pf(["-s", "References"])
            if references.split(whereSeparator: { $0.isWhitespace }).contains(Substring(String(token))) {
                _ = try Self.pf(["-X", String(token)], merged: true)
            }
        }
        let files = [reference, fingerprint, snapshot]
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    func blockedPackets(ipv6: Bool) throws -> UInt64 {
        let label = ipv6 ? "proxyctl_probe_v6" : "proxyctl_probe_v4"
        let counters = try Self.pf(["-a", Self.anchor, "-sl"])
        guard let row = counters.split(separator: "\n").first(where: { $0.hasPrefix(label + " ") }),
              let packets = UInt64(row.split(whereSeparator: { $0.isWhitespace }).dropFirst(2).first ?? "") else {
            throw UserError("无法读取 PF 丢弃计数。")
        }
        return packets
    }
}
