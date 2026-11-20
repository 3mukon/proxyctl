import Darwin
import Foundation

enum TunnelCheck {
    static func routeInterface(_ address: String, ipv6: Bool = false) -> String? {
        guard let result = try? run("/sbin/route", ["-n", "get", ipv6 ? "-inet6" : "-inet", address], quiet: true),
              result.status == 0 else { return nil }
        return result.text.split(separator: "\n").compactMap { line -> String? in
            let field = line.trimmingCharacters(in: .whitespaces)
            guard field.hasPrefix("interface:") else { return nil }
            return field.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
        }.first
    }

    static func competingVPNActive() throws -> Bool {
        let connections = try run("/usr/sbin/scutil", ["--nc", "list"], quiet: true)
        guard connections.status == 0 else {
            throw UserError(localized("无法检查当前 VPN 状态。", "Could not check the current VPN state."))
        }
        return connections.text.split(separator: "\n").contains { row in
            let line = row.trimmingCharacters(in: .whitespaces)
            return ["Connected", "Connecting", "Disconnecting", "Reasserting"].contains {
                line.hasPrefix("* (\($0))") || line.hasPrefix("(\($0))")
            }
        }
    }

    static var pauseVPN: UserError {
        let start = commandExample("system start")
        return UserError(localized("请手动暂停当前 VPN，再运行 \(start)。",
                                   "Pause the current VPN, then run \(start)."))
    }

    static func verifyUpstream(_ engine: Engine, rules: [CustomRule]) throws -> Int? {
        guard engine.profile.routing.referencesUpstream(with: rules), let upstream = engine.profile.upstream else {
            return nil
        }
        try requireIndependentListener(upstream)
        do { return try engine.testUpstream(url: probeURL) }
        catch {
            throw UserError(localized("外部代理 \(upstream.addressLabel) 未通过转发检查。请确认代理能独立运行。",
                                      "The external proxy \(upstream.addressLabel) failed the forwarding check. Confirm it can run independently."))
        }
    }

    private static func requireIndependentListener(_ upstream: Upstream) throws {
        guard let host = upstream.config["server"] as? String, let port = upstream.config["server_port"] as? Int else { return }
        let addresses = ["localhost", "localhost."].contains(host.lowercased())
            ? ["127.0.0.1", "::1"] : [host]
        let pids = Set(addresses.filter(loopback).flatMap { listenerPIDs(host: $0, port: port) })
        let owners = pids.compactMap(packetTunnelOwner)
        guard owners.count == pids.count, let owner = owners.sorted().first else { return }
        let setup = commandExample("setup upstream")
        let rules = commandExample("rules")
        throw UserError(localized(
            "外部代理 \(upstream.addressLabel) 由 \(owner) 的 VPN 隧道提供。用 \(setup) 更换为独立代理，或在 \(rules) 中改选出口。",
            "The external proxy \(upstream.addressLabel) belongs to the \(owner) VPN tunnel. Change it to an independent proxy with \(setup) or choose another outbound in \(rules)."
        ))
    }

    private static func loopback(_ address: String) -> Bool {
        if address == "::1" { return true }
        var ipv4 = in_addr()
        return inet_pton(AF_INET, address, &ipv4) == 1 && UInt32(bigEndian: ipv4.s_addr) >> 24 == 127
    }

    private static func packetTunnelOwner(_ pid: Int) -> String? {
        guard let executable = executablePath(of: pid) else { return nil }
        let components = URL(fileURLWithPath: executable).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".appex") || $0.hasSuffix(".systemextension") }),
              let bundle = Bundle(path: NSString.path(withComponents: Array(components.prefix(index + 1)))),
              let info = bundle.infoDictionary else { return nil }
        let point = "com.apple.networkextension.packet-tunnel"
        let appExtension = info["NSExtension"] as? [String: Any]
        let systemExtension = info["NetworkExtension"] as? [String: Any]
        let providers = systemExtension?["NEProviderClasses"] as? [String: Any]
        guard appExtension?["NSExtensionPointIdentifier"] as? String == point || providers?[point] != nil else { return nil }
        let name = components.prefix(index).last(where: { $0.hasSuffix(".app") }) ?? components[index]
        return terminalText((name as NSString).deletingPathExtension)
    }

    static func preflight() throws -> Uplink {
        guard try !competingVPNActive() else { throw pauseVPN }
        guard if_nametoindex(Tunnel.name) == 0,
              let ipv4 = routeInterface("1.1.1.1"), physical(ipv4) else {
            throw UserError("需要可用的 IPv4 外网接口和一个空闲的 \(Tunnel.name)。")
        }
        let ipv6 = routeInterface("2606:4700:4700::1111", ipv6: true)
        guard ipv6.map(physical) ?? true else { throw UserError("检测到 IPv6 路由已被其他隧道接管。") }
        return Uplink(ipv4: ipv4, ipv6: ipv6)
    }

    private static func physical(_ name: String) -> Bool {
        !["utun", "tun", "tap", "ipsec", "ppp", "lo"].contains(where: { name.hasPrefix($0) }) &&
            name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) } &&
            if_nametoindex(name) != 0
    }

    static var routed: Bool {
        routeInterface("1.1.1.1") == Tunnel.name &&
        routeInterface("2606:4700:4700::1111", ipv6: true) == Tunnel.name
    }

    static func checkDeadline(_ deadline: TimeInterval?) throws {
        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline {
            throw UserError(localized("系统试用已超时。", "The system trial timed out."))
        }
    }

    static func dataPath(_ engine: Engine, deadline: TimeInterval? = nil) throws {
        try checkDeadline(deadline)
        guard routed else { throw UserError("IPv4 或 IPv6 公网路由未经过 TUN。") }
        let routing = engine.profile.routing
        let rules = try routing.ruleFiles(in: engine.paths.state)?.list() ?? []
        func outbound(_ host: String) -> RuleTarget {
            if let group = routing.collections.first(where: { $0.enabled && matchesDomain(host, $0.domains) }) {
                return group.target
            }
            if let rule = rules.first(where: { $0.match == .domain && matchesDomain(host, [$0.value]) }) {
                return rule.target
            }
            return routing.fallback
        }
        for host in ["example.com", "api.anthropic.com", "api.openai.com"] {
            try checkDeadline(deadline)
            if outbound(host) == .direct {
                if host == "example.com" { try request(host, deadline: deadline) }
                continue
            }
            for family in ["A", "AAAA"] {
                try checkDeadline(deadline)
                let address = try fakeAddress(host, family)
                try checkDeadline(deadline)
                try request(host, address: address, ipv6: family == "AAAA", deadline: deadline)
            }
        }
        try checkDeadline(deadline)
        let checked = try engine.checkActive(url: probeURL)
        for name in routing.pinnedNodes(rules).sorted() where name != checked.node {
            try checkDeadline(deadline)
            do { _ = try engine.measure(name, url: probeURL) }
            catch {
                throw UserError(localized("指定节点 \(terminalText(name)) 未通过连通性检查。",
                                          "The specified node \(terminalText(name)) failed its connectivity check."))
            }
        }
        if engine.profile.upstream != nil, routing.referencesUpstream(with: rules) {
            try checkDeadline(deadline)
            _ = try engine.measure(upstreamTag, url: probeURL)
        }
        try checkDeadline(deadline)
    }

    private static func fakeAddress(_ host: String, _ family: String) throws -> String {
        let result = try run("/usr/bin/dig", ["@\(Tunnel.dns4)", "+short", "+time=2", "+tries=1", host, family], quiet: true)
        let ipv6 = family == "AAAA"
        for row in result.text.split(separator: "\n") {
            let address = String(row)
            var parsed = in6_addr()
            guard inet_pton(ipv6 ? AF_INET6 : AF_INET, address, &parsed) == 1 else { continue }
            let fake = withUnsafeBytes(of: &parsed) { bytes in
                ipv6 ? bytes[0] == 0xfc && bytes[1] == 0 && bytes[2] < 0x40
                     : bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)
            }
            if fake { return address }
        }
        throw UserError("\(host) 的 \(family) 查询未命中代理 DNS。")
    }

    private static func request(_ host: String, address: String? = nil, ipv6: Bool = false,
                                deadline: TimeInterval?) throws {
        let family = ipv6 ? "IPv6" : "IPv4"
        var args = ["-q", "--noproxy", "*", "--proto", "=https", "--head", "--silent", "--show-error",
                    "--output", "/dev/null", "--write-out", "\n%{http_code}\n", ipv6 ? "-6" : "-4"]
        if let address { args += ["--resolve", "\(host):443:\(ipv6 ? "[\(address)]" : address)"] }
        let result = try TunnelHTTPSProbe.check {
            guard routed else {
                throw UserError(localized("IPv4 或 IPv6 公网路由未经过 TUN。",
                                          "The IPv4 or IPv6 public route does not use the TUN."))
            }
            try checkDeadline(deadline)
            let seconds = deadline.map { min(6, $0 - ProcessInfo.processInfo.systemUptime) } ?? 6
            let milliseconds = Int(seconds * 1000)
            guard milliseconds > 0 else {
                throw UserError(localized("系统试用已超时。", "The system trial timed out."))
            }
            let timeouts = ["--max-time", String(Double(milliseconds) / 1000),
                            "--connect-timeout", String(Double(min(3000, milliseconds)) / 1000)]
            let response = try run("/usr/bin/curl", args + timeouts + ["https://\(host)/"],
                                   quiet: true, mergeError: true)
            return TunnelHTTPSProbe(exitCode: response.status, output: response.text)
        }
        guard result.passed else {
            let failure = localized("\(host) 的 \(family) TUN HTTPS 探测失败",
                                    "\(family) TUN HTTPS probe failed for \(host)")
            var details = [failure]
            if let code = result.httpCode, code > 0 { details.append("HTTP \(code)") }
            if let detail = result.detail {
                details.append(terminalText(String(detail.prefix(180))))
            } else if result.exitCode != 0 || (result.httpCode ?? 0) == 0 {
                details.append("curl \(result.exitCode)")
            }
            throw UserError(details.joined(separator: " · "))
        }
    }

    static func proveDrop(_ filter: PacketFilter, uplink: Uplink) throws {
        try proveDrop(filter, interface: uplink.ipv4, ipv6: false)
        if let interface = uplink.ipv6 { try proveDrop(filter, interface: interface, ipv6: true) }
    }

    private static func proveDrop(_ filter: PacketFilter, interface: String, ipv6: Bool) throws {
        var index = if_nametoindex(interface)
        guard index != 0 else { throw UserError("试用期间外网接口发生变化。") }
        let before = try filter.blockedPackets(ipv6: ipv6)
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw UserError("无法创建 PF 探测连接。") }
        defer { close(fd) }
        let result = setsockopt(fd, ipv6 ? IPPROTO_IPV6 : IPPROTO_IP, ipv6 ? IPV6_BOUND_IF : IP_BOUND_IF,
                                &index, socklen_t(MemoryLayout<UInt32>.size))
        guard result == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw UserError("无法将探测绑定到实体网卡。") }
        if ipv6 {
            var target = sockaddr_in6()
            target.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            target.sin6_family = sa_family_t(AF_INET6)
            target.sin6_port = UInt16(443).bigEndian
            _ = inet_pton(AF_INET6, "2606:4700:4700::1111", &target.sin6_addr)
            try dropCheck(fd, &target)
        } else {
            var target = sockaddr_in()
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            target.sin_family = sa_family_t(AF_INET)
            target.sin_port = UInt16(443).bigEndian
            target.sin_addr.s_addr = inet_addr("1.1.1.1")
            try dropCheck(fd, &target)
        }
        guard try filter.blockedPackets(ipv6: ipv6) > before else {
            throw UserError("PF 未记录实体网卡的 \(ipv6 ? "IPv6" : "IPv4") 绕行探测。")
        }
    }

    private static func dropCheck<T>(_ fd: Int32, _ address: inout T) throws {
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<T>.size))
            }
        }
        guard connected != 0 else { throw UserError("实体网卡绕行连接成功，防护验证失败。") }
        if errno == EINPROGRESS {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&descriptor, 1, 1_300) > 0 {
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error != 0 else {
                    throw UserError("实体网卡绕行连接成功，防护验证失败。")
                }
            }
        }
    }
}
