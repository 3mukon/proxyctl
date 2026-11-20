struct TunnelHTTPSProbe {
    let exitCode: Int32
    let httpCode: Int?
    let detail: String?

    init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        let lines = output.split(whereSeparator: \.isNewline)
        let code = lines.last.flatMap { Int($0) }
        httpCode = code
        detail = lines.dropLast(code == nil ? 0 : 1).first.map(String.init)
    }

    var passed: Bool {
        exitCode == 0 && httpCode.map { (200..<500).contains($0) } == true
    }

    private var retryable: Bool {
        switch exitCode {
        case 0: return httpCode.map { (500..<600).contains($0) } == true
        case 6, 7, 28, 35, 52, 55, 56: return true
        default: return false
        }
    }

    static func check(_ attempt: () throws -> Self) rethrows -> Self {
        let first = try attempt()
        if first.retryable { return try attempt() }
        return first
    }
}
