import Darwin
import Foundation

private func proxyProbe(url: String, port: Int, password: String, preparingSystem: Bool) throws -> Int {
    guard let destination = URLComponents(string: url), let scheme = destination.scheme?.lowercased(),
          ["http", "https"].contains(scheme), destination.host != nil,
          destination.user == nil, destination.password == nil, terminalText(url) == url else {
        throw UserError(localized("测试地址必须是无凭据的 HTTP(S) 地址。", "Use an HTTP or HTTPS URL without credentials."))
    }
    let connectTimeout = preparingSystem ? "8" : "3"
    let requestTimeout = preparingSystem ? "12" : "6"
    let attempts = preparingSystem ? 2 : 1
    let arguments = ["-q", "--noproxy", "", "--proxy", "http://127.0.0.1:\(port)", "--proto", "=http,https",
                     "--max-time", requestTimeout, "--connect-timeout", connectTimeout, "--head", "-fsS", "--output", "/dev/null",
                     "--write-out", "%{time_total}", "--config", "-", "--url", url]
    let credential = Data("proxy-user = \"proxyctl:\(password)\"\n".utf8)
    for _ in 0..<attempts {
        let result = try run("/usr/bin/curl", arguments, input: credential, quiet: true)
        if result.status == 0, let seconds = Double(result.text), seconds.isFinite {
            return max(1, Int((seconds * 1000).rounded()))
        }
    }
    throw UserError(localized("节点未通过连通性探测。", "The node failed its connectivity check."))
}

private func chooseProbePort() throws -> Int {
    try withBoundPort(0) { descriptor in
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { throw UserError(localized("无法分配探测端口。", "Could not allocate a probe port.")) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

extension Engine {
    func test(_ name: String, url: String, preparingSystem: Bool = false) throws -> Int {
        guard profile.nodes.contains(where: { $0.name == name }) else { throw UserError(localized("未找到此节点。", "Node not found.")) }
        return try testOutbound(name, url: url, preparingSystem: preparingSystem)
    }

    func testUpstream(url: String) throws -> Int {
        try testOutbound(upstreamTag, url: url, preparingSystem: true)
    }

    private func testOutbound(_ name: String, url: String, preparingSystem: Bool) throws -> Int {
        let port = try chooseProbePort()
        let password = UUID().uuidString
        var candidate = try loadObject(localData(paths.config))
        candidate.removeValue(forKey: "experimental")
        candidate["log"] = ["disabled": true]
        candidate["inbounds"] = [["type": "mixed", "listen": "127.0.0.1", "listen_port": port,
                                  "users": [["username": "proxyctl", "password": password]]]]
        let route = candidate["route"] as? [String: Any] ?? [:]
        let resolver = route["default_domain_resolver"] as? String ?? directDNS
        var probeRoute: [String: Any] = ["final": name, "default_domain_resolver": resolver]
        probeRoute["rule_set"] = route["rule_set"]
        candidate["route"] = probeRoute

        let input = Pipe()
        let child = Process()
        child.executableURL = paths.core
        child.arguments = ["-D", paths.state.path, "run", "-c", "/dev/stdin"]
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        let shutdown = DispatchQueue(label: "proxyctl.probe.shutdown")
        let signals = [SIGINT, SIGTERM, SIGHUP].map { signum in
            let previous = signal(signum, { _ in })
            let source = DispatchSource.makeSignalSource(signal: signum, queue: shutdown)
            source.setEventHandler {
                if child.isRunning {
                    child.terminate()
                    child.waitUntilExit()
                }
                _exit(128 + signum)
            }
            return (signum, previous, source)
        }
        defer {
            for (signum, previous, source) in signals {
                source.cancel()
                signal(signum, previous)
            }
        }
        try shutdown.sync {
            for (_, _, source) in signals { source.resume() }
            try child.run()
        }
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        defer { try? input.fileHandleForWriting.close() }
        try input.fileHandleForWriting.write(contentsOf: jsonData(candidate))
        try input.fileHandleForWriting.close()
        for _ in 0..<16 {
            guard child.isRunning else { break }
            if listenerPID(port: port) == Int(child.processIdentifier) {
                return try proxyProbe(url: url, port: port, password: password, preparingSystem: preparingSystem)
            }
            usleep(120_000)
        }
        throw UserError(localized("隔离的节点探测未就绪。", "The isolated node probe did not start."))
    }
}
