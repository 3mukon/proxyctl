import Foundation

private struct LinkError: LocalizedError {
    let description: String
    var errorDescription: String? { description }

    static var invalid: Self {
        Self(description: localized("链接缺少有效的服务器、端口或认证信息。", "The link is missing a valid server, port, or credential."))
    }

    static func unsupported(_ feature: String) -> Self {
        Self(description: localized("打包的 sing-box 暂不支持此链接的\(feature)。", "The bundled sing-box cannot import this link's \(feature)."))
    }
}

private struct LinkOptions {
    var fields: [String: String] = [:]

    subscript(_ names: String...) -> String? {
        names.compactMap { fields[$0.lowercased()] }.first { !$0.isEmpty }
    }

    func flag(_ names: String...) throws -> Bool? {
        guard let value = names.compactMap({ fields[$0.lowercased()] }).first, !value.isEmpty else { return nil }
        switch value.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: throw LinkError.invalid
        }
    }

    func number(_ names: String...) throws -> Int? {
        guard let value = names.compactMap({ fields[$0.lowercased()] }).first, !value.isEmpty else { return nil }
        let data = value.lowercased().replacingOccurrences(of: "mbps", with: "").trimmingCharacters(in: .whitespaces)
        guard let number = Int(data), number >= 0 else { throw LinkError.invalid }
        return number
    }

    var alpn: [String] {
        self["alpn"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
    }

    func tls(required: Bool = false) throws -> [String: Any]? {
        let security = self["security", "tls"]?.lowercased()
        if let security, !["none", "tls", "reality", "0", "1"].contains(security) {
            throw LinkError.unsupported(localized("TLS 类型", "TLS mode"))
        }
        if required && (security == "none" || security == "0") {
            throw LinkError.unsupported(localized("明文模式", "plaintext mode"))
        }
        if self["pinsha256", "pcs", "ech"] != nil {
            throw LinkError.unsupported(localized("证书固定或 ECH 字段", "certificate pin or ECH options"))
        }
        guard required || ["tls", "reality", "1"].contains(security ?? "") else { return nil }
        var tls: [String: Any] = ["enabled": true]
        if let name = self["sni", "servername", "peer"] { tls["server_name"] = name }
        if let insecure = try flag("allowinsecure", "insecure", "skip-cert-verify") { tls["insecure"] = insecure }
        if !alpn.isEmpty { tls["alpn"] = alpn }
        if let fingerprint = self["fp"] ?? (security == "reality" ? "chrome" : nil) {
            tls["utls"] = ["enabled": true, "fingerprint": fingerprint]
        }
        if security == "reality" {
            guard let key = self["pbk", "publickey"] else { throw LinkError.invalid }
            tls["reality"] = ["enabled": true, "public_key": key, "short_id": self["sid", "shortid"] ?? ""]
        }
        return tls
    }

    func transport(kind: String? = nil) throws -> [String: Any]? {
        let mode = (kind ?? self["type", "transport", "net"] ?? "tcp").lowercased()
        let path = self["path"] ?? "/"
        switch mode {
        case "tcp", "raw", "none":
            if let header = self["headertype"], header != "none" {
                throw LinkError.unsupported(localized("TCP 请求头伪装", "custom TCP header"))
            }
            return nil
        case "ws", "websocket":
            var ws: [String: Any] = ["type": "ws", "path": path]
            if let host = self["host"] { ws["headers"] = ["Host": host] }
            if let early = try number("ed", "max_early_data") {
                ws["max_early_data"] = early
                ws["early_data_header_name"] = self["eh", "early_data_header_name"] ?? "Sec-WebSocket-Protocol"
            }
            return ws
        case "http", "h2":
            var http: [String: Any] = ["type": "http", "path": path]
            if let host = self["host"] { http["host"] = host.split(separator: ",").map(String.init) }
            return http
        case "httpupgrade":
            var upgrade: [String: Any] = ["type": "httpupgrade", "path": path]
            if let host = self["host"] { upgrade["host"] = host }
            return upgrade
        case "grpc":
            if self["mode"] == "multi" {
                throw LinkError.unsupported(localized("多流 gRPC 模式", "multi-stream gRPC mode"))
            }
            return ["type": "grpc", "service_name": self["servicename", "service_name"] ?? self["path"] ?? ""]
        case "quic":
            return ["type": "quic"]
        default:
            throw LinkError.unsupported(localized("传输类型", "transport"))
        }
    }
}

private struct LinkAddress {
    let host: String
    let port: Int
    let user: String?
    let password: String?
    let name: String?
    let path: String
    let options: LinkOptions

    var token: String? {
        guard let user, !user.isEmpty else { return nil }
        return password.map { "\(user):\($0)" } ?? user
    }

    init(_ source: String, defaultPort: Int?) throws {
        guard let parsed = URLComponents(string: source), let host = parsed.host, !host.isEmpty,
              let port = parsed.port ?? defaultPort, (1...65535).contains(port),
              terminalText(host) == host, !host.contains(where: \.isWhitespace) else { throw LinkError.invalid }
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.port = port
        user = parsed.user
        password = parsed.password
        name = parsed.fragment
        path = parsed.path
        var properties: [String: String] = [:]
        for item in parsed.queryItems ?? [] {
            properties[item.name.lowercased()] = item.value ?? ""
        }
        options = LinkOptions(fields: properties)
    }
}

struct ShareLink {
    let outbound: [String: Any]
    let name: String

    init(_ value: String) throws {
        guard value.utf8.count <= maxConfigBytes,
              let separator = value.range(of: "://") else { throw LinkError.invalid }
        let scheme = value[..<separator.lowerBound].lowercased()
        let body = String(value[separator.upperBound...])
        let decoded: ([String: Any], String?)
        switch scheme {
        case "ss":
            decoded = try Self.shadowsocks(value, body: body)
        case "vmess" where !body.contains("@"):
            decoded = try Self.vmessJSON(body)
        case "vless", "vmess", "trojan", "hysteria", "hysteria2", "hy2", "tuic", "anytls",
             "socks", "socks4", "socks4a", "socks5", "http", "https", "ssh", "snell",
             "naive+https", "naive+quic":
            decoded = try Self.standard(value, scheme: scheme)
        default:
            throw LinkError.unsupported(localized("分享协议", "share protocol"))
        }
        outbound = decoded.0
        let title = decoded.1.map { String(terminalText($0).prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines) }
        name = title.flatMap { Profile.validName($0) && !$0.hasPrefix("--") ? $0 : nil } ?? (decoded.0["type"] as? String ?? scheme).uppercased()
    }

    private static func standard(_ raw: String, scheme: String) throws -> ([String: Any], String?) {
        let defaultPort: Int
        switch scheme {
        case "ssh": defaultPort = 22
        case "http": defaultPort = 80
        case "socks", "socks4", "socks4a", "socks5": defaultPort = 1080
        default: defaultPort = 443
        }
        let hopping = try ["hysteria", "hysteria2", "hy2"].contains(scheme) ? hoppingAuthority(raw) : (raw, nil)
        let address = try LinkAddress(hopping.0, defaultPort: defaultPort)
        let options = address.options
        let host = address.host
        var outbound: [String: Any] = ["type": scheme, "server": host, "server_port": address.port]
        switch scheme {
        case "vless", "vmess":
            guard let user = address.user, let uuid = UUID(uuidString: user), address.password == nil else { throw LinkError.invalid }
            if scheme == "vless", let encryption = options["encryption"], encryption != "none" {
                throw LinkError.unsupported(localized("VLESS 加密设置", "VLESS encryption"))
            }
            outbound["uuid"] = uuid.uuidString.lowercased()
            if scheme == "vmess" {
                outbound["security"] = options["encryption", "scy"] ?? "auto"
                outbound["alter_id"] = try options.number("aid")
            } else {
                outbound["flow"] = options["flow"]
            }
            outbound["packet_encoding"] = options["packetencoding", "packet_encoding"]
            outbound["tls"] = try options.tls()
            outbound["transport"] = try options.transport()
        case "trojan", "anytls", "hysteria2", "hy2":
            if scheme == "hy2" { outbound["type"] = "hysteria2" }
            if address.token == nil && scheme != "hysteria2" && scheme != "hy2" { throw LinkError.invalid }
            outbound["password"] = address.token
            outbound["tls"] = try options.tls(required: true)
            if scheme == "trojan" { outbound["transport"] = try options.transport() }
            if scheme == "hysteria2" || scheme == "hy2" {
                if let type = options["obfs"] {
                    guard let password = options["obfs-password", "obfspassword"] else { throw LinkError.invalid }
                    outbound["obfs"] = ["type": type, "password": password]
                }
                outbound["up_mbps"] = try options.number("upmbps", "up")
                outbound["down_mbps"] = try options.number("downmbps", "down")
                if let ports = hopping.1 ?? options["mport"] {
                    outbound["server_ports"] = try portRanges(ports)
                    outbound.removeValue(forKey: "server_port")
                }
            }
        case "hysteria":
            if let ports = hopping.1 ?? options["mport"] {
                outbound["server_ports"] = try portRanges(ports)
                outbound.removeValue(forKey: "server_port")
            }
            if options["auth_type"] == "base64" {
                guard let value = options["auth"] ?? address.token, let data = base64(value) else { throw LinkError.invalid }
                outbound["auth"] = data.base64EncodedString()
            } else {
                outbound["auth_str"] = options["auth"] ?? address.token
            }
            outbound["obfs"] = options["obfsparam", "obfs"]
            outbound["protocol"] = options["protocol"]
            outbound["up_mbps"] = try options.number("upmbps", "up")
            outbound["down_mbps"] = try options.number("downmbps", "down")
            outbound["tls"] = try options.tls(required: true)
        case "tuic":
            guard let user = address.user, let uuid = UUID(uuidString: user),
                  let pass = address.password, !pass.isEmpty else { throw LinkError.invalid }
            outbound["uuid"] = uuid.uuidString.lowercased()
            outbound["password"] = pass
            outbound["congestion_control"] = options["congestion_control", "congestion-control"]
            outbound["udp_relay_mode"] = options["udp_relay_mode", "udp-relay-mode"]
            outbound["zero_rtt_handshake"] = try options.flag("zero_rtt_handshake", "zero_rtt")
            outbound["tls"] = try options.tls(required: true)
        case "socks", "socks4", "socks4a", "socks5":
            outbound["type"] = "socks"
            outbound["version"] = scheme == "socks" ? "5" : String(scheme.dropFirst(5))
            outbound["username"] = address.user
            outbound["password"] = address.password
        case "http", "https", "naive+https", "naive+quic":
            let naive = scheme.hasPrefix("naive+")
            guard (address.path.isEmpty || address.path == "/"),
                  address.user != nil || URLComponents(string: raw)?.port != nil else { throw LinkError.invalid }
            outbound["type"] = naive ? "naive" : "http"
            outbound["username"] = address.user
            outbound["password"] = address.password
            if naive {
                outbound["quic"] = scheme == "naive+quic"
            }
            outbound["tls"] = try options.tls(required: naive || scheme == "https")
        case "ssh":
            guard let user = address.user, !user.isEmpty, let secret = address.password, !secret.isEmpty else { throw LinkError.invalid }
            outbound["user"] = user
            outbound["password"] = secret
        case "snell":
            guard let token = address.token else { throw LinkError.invalid }
            outbound["psk"] = token
            outbound["version"] = try options.number("version")
            if options["obfs", "obfs-host"] != nil {
                throw LinkError.unsupported(localized("Snell 混淆参数", "Snell obfuscation"))
            }
        default:
            throw LinkError.invalid
        }
        return (outbound, address.name)
    }

    private static func hoppingAuthority(_ raw: String) throws -> (String, String?) {
        guard let start = raw.range(of: "://")?.upperBound else { throw LinkError.invalid }
        let authority = raw[start...].prefix { !"/?#".contains($0) }
        guard let colon = authority.lastIndex(of: ":"),
              authority.lastIndex(of: "@").map({ $0 < colon }) ?? true,
              authority.lastIndex(of: "]").map({ $0 < colon }) ?? true else { return (raw, nil) }
        let range = String(authority[authority.index(after: colon)...])
        guard range.contains(",") || range.contains("-") else { return (raw, nil) }
        let ports = try portRanges(range)
        guard let first = ports.first?.split(separator: ":").first else { throw LinkError.invalid }
        let source = String(raw[...colon]) + first + String(raw[authority.endIndex...])
        return (source, range)
    }

    private static func portRanges(_ input: String) throws -> [String] {
        try input.split(separator: ",", omittingEmptySubsequences: false).map { range in
            let bounds = range.replacingOccurrences(of: "-", with: ":")
                .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let low = bounds.first.flatMap({ Int($0) }), (1...65535).contains(low) else { throw LinkError.invalid }
            let high = bounds.count == 1 ? low : (Int(bounds[1]) ?? 0)
            guard (low...65535).contains(high) else { throw LinkError.invalid }
            return "\(low):\(high)"
        }
    }

    private static func shadowsocks(_ raw: String, body: String) throws -> ([String: Any], String?) {
        let address: LinkAddress
        let decoded: String
        if body.prefix(while: { $0 != "#" && $0 != "?" }).contains("@") {
            address = try LinkAddress(raw, defaultPort: nil)
            guard let user = address.user else { throw LinkError.invalid }
            if let password = address.password { decoded = "\(user):\(password)" }
            else if let clear = base64(user).flatMap({ String(data: $0, encoding: .utf8) }) { decoded = clear }
            else { throw LinkError.invalid }
        } else {
            let encoded = body.prefix(while: { $0 != "#" && $0 != "?" })
            guard let clear = base64(String(encoded)).flatMap({ String(data: $0, encoding: .utf8) }),
                  let at = clear.lastIndex(of: "@") else { throw LinkError.invalid }
            decoded = String(clear[..<at])
            address = try LinkAddress("ss://" + clear[clear.index(after: at)...] + body.dropFirst(encoded.count),
                                      defaultPort: nil)
        }
        let credentials = decoded.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard credentials.count == 2, !credentials[0].isEmpty, !credentials[1].isEmpty else { throw LinkError.invalid }
        var outbound: [String: Any] = [
            "type": "shadowsocks", "server": address.host, "server_port": address.port,
            "method": String(credentials[0]), "password": String(credentials[1])
        ]
        if let plugin = address.options["plugin"] {
            let parts = plugin.split(separator: ";", maxSplits: 1).map(String.init)
            guard let id = parts.first else { throw LinkError.invalid }
            outbound["plugin"] = ["obfs", "simple-obfs"].contains(id) ? "obfs-local" : id
            if parts.count == 2 { outbound["plugin_opts"] = parts[1] }
        }
        return (outbound, address.name)
    }

    private static func vmessJSON(_ body: String) throws -> ([String: Any], String?) {
        let token = body.prefix(while: { $0 != "#" })
        guard let data = base64(String(token)),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw LinkError.invalid }
        var values: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String { values[key.lowercased()] = string }
            else if let number = value as? NSNumber { values[key.lowercased()] = number.stringValue }
        }
        let options = LinkOptions(fields: values)
        guard let host = options["add"], host == terminalText(host),
              let port = try options.number("port"), (1...65535).contains(port),
              let id = options["id"], let uuid = UUID(uuidString: id) else { throw LinkError.invalid }
        if let header = options["type"], header != "none", options["net"] == "tcp" {
            throw LinkError.unsupported(localized("TCP 请求头伪装", "custom TCP header"))
        }
        var outbound: [String: Any] = [
            "type": "vmess", "server": host, "server_port": port, "uuid": uuid.uuidString.lowercased(),
            "security": options["scy"] ?? "auto"
        ]
        outbound["alter_id"] = try options.number("aid")
        outbound["tls"] = try options.tls()
        outbound["transport"] = try options.transport(kind: options["net"] ?? "tcp")
        return (outbound, options["ps"])
    }

    private static func base64(_ value: String) -> Data? {
        guard var field = value.removingPercentEncoding else { return nil }
        field = field.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        field += String(repeating: "=", count: (4 - field.count % 4) % 4)
        return Data(base64Encoded: field)
    }
}
