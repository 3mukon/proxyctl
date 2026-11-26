import Foundation

struct Uplink: Codable {
    let ipv4: String
    let ipv6: String?
}

enum ProtectionPhase: String, Codable {
    case prepared
    case tunnelTrial = "tunnel-trial"
    case firewallTesting = "firewall-testing"
    case firewallTrial = "firewall-trial"
    case starting
    case protected
    case rollingBack = "rolling-back"

    var isTrial: Bool { self == .tunnelTrial || self == .firewallTesting || self == .firewallTrial || self == .starting }
}

struct ProtectionRecord: Codable {
    var phase: ProtectionPhase = .prepared
    var deadline: TimeInterval?
    var bootID: String?
    var uplink: Uplink?
    var verified = false
    let sourceRevision: String

    func expired(bootID: String, now: TimeInterval) -> Bool {
        phase.isTrial && (self.bootID != bootID || (deadline ?? 0) <= now)
    }

    func resumedAtBoot(_ boot: String, enabled: Bool) -> ProtectionRecord? {
        guard enabled, verified, bootID != boot else { return nil }
        switch phase {
        case .prepared, .protected, .starting:
            return ProtectionRecord(phase: .protected, bootID: boot, verified: true, sourceRevision: sourceRevision)
        default:
            return nil
        }
    }
}

struct SystemStartupFailure: Error {
    let cause: Error
    let rollback: Error?
}

func completeSystemStartup(trial: () throws -> Void, firewall: () throws -> Void,
                           keep: () throws -> Void, rollback: () throws -> Void) throws {
    try trial()
    do {
        try firewall()
        try keep()
    } catch {
        let cause = error
        do {
            try rollback()
        } catch {
            throw SystemStartupFailure(cause: cause, rollback: error)
        }
        throw SystemStartupFailure(cause: cause, rollback: nil)
    }
}
