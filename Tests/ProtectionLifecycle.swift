import Darwin
import Foundation

@main
struct ProtectionLifecycleTests {
    private enum Stage: Error, Equatable { case trial, firewall, keep, rollback }

    static func verifyStartup() throws {
        for failure in [nil, .trial, .firewall, .keep, .rollback] as [Stage?] {
            var visited: [Stage] = []
            func visit(_ stage: Stage) throws {
                visited.append(stage)
                if stage == failure || (failure == .rollback && stage == .firewall) { throw stage }
            }
            do {
                try completeSystemStartup(trial: { try visit(.trial) }, firewall: { try visit(.firewall) },
                                          keep: { try visit(.keep) }, rollback: { try visit(.rollback) })
                precondition(failure == nil && visited == [.trial, .firewall, .keep])
            } catch let error as SystemStartupFailure {
                switch failure {
                case .firewall, .rollback:
                    precondition(error.cause as? Stage == .firewall && visited == [.trial, .firewall, .rollback])
                    precondition(error.rollback as? Stage == (failure == .rollback ? .rollback : nil))
                case .keep:
                    precondition(error.cause as? Stage == .keep && error.rollback == nil)
                    precondition(visited == [.trial, .firewall, .keep, .rollback])
                default: preconditionFailure("Unexpected startup failure")
                }
            } catch Stage.trial {
                precondition(failure == .trial && visited == [.trial])
            }
        }
    }

    private static func verifyPacketFilterRoot() throws {
        let scrub = #"scrub-anchor "com.apple/*" all fragment reassemble"#
        let apple = #"anchor "com.apple/*" all"#
        let guardRule = #"anchor "local.proxyctl.egress" out all"#
        let baseline = scrub + "\n" + apple
        precondition(PacketFilterRoot.adding(guardRule, to: "") == guardRule)
        precondition(PacketFilterRoot.adding(guardRule, to: apple) == guardRule + "\n" + apple)
        precondition(PacketFilterRoot.adding(guardRule, to: baseline + "\npass out all") == nil)
        guard let protected = PacketFilterRoot.adding(guardRule, to: baseline) else {
            preconditionFailure("The macOS default main PF ruleset should be accepted")
        }
        precondition(protected == [scrub, guardRule, apple].joined(separator: "\n"))

        // Validate both the rule load and the saved rollback input using Apple's parser.
        for rules in [baseline, protected] {
            let parser = Process()
            parser.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
            parser.arguments = ["-n", "-R", "-f", "-"]
            let input = Pipe()
            parser.standardInput = input
            parser.standardError = FileHandle.nullDevice
            try parser.run()
            try input.fileHandleForWriting.write(contentsOf: Data((rules + "\n").utf8))
            try input.fileHandleForWriting.close()
            parser.waitUntilExit()
            precondition(parser.terminationStatus == 0, "PF rejected the generated root rules")
        }
    }

    private static func verifyHTTPSProbe() {
        let success = TunnelHTTPSProbe(exitCode: 0, output: "\n200\n")
        let timeout = TunnelHTTPSProbe(exitCode: 28, output: "curl: (28) Connection timed out\n\n000\n")
        let certificate = TunnelHTTPSProbe(exitCode: 60, output: "curl: (60) Certificate verification failed\n000\n")
        let unavailable = TunnelHTTPSProbe(exitCode: 0, output: "\n503\n")
        precondition(success.passed && success.httpCode == 200 && success.detail == nil)
        precondition(!timeout.passed && timeout.httpCode == 0 && timeout.detail?.contains("timed out") == true)
        for (first, second, expectedAttempts, expectedSuccess) in [
            (success, timeout, 1, true),
            (timeout, success, 2, true),
            (timeout, timeout, 2, false),
            (unavailable, success, 2, true),
            (certificate, success, 1, false),
        ] {
            var attempts = 0
            let result = TunnelHTTPSProbe.check {
                attempts += 1
                return attempts == 1 ? first : second
            }
            precondition(attempts == expectedAttempts && result.passed == expectedSuccess)
        }
    }

    private static func verifyOperationLock() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let holder = open(temporary.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        precondition(holder >= 0)
        defer {
            close(holder)
            try? FileManager.default.removeItem(at: temporary)
        }
        let waiter = open(temporary.path, O_RDWR | O_CLOEXEC)
        precondition(waiter >= 0)
        defer { close(waiter) }
        try acquireOperationLock(holder, waitingUpTo: 0)

        for timeout in [0.0, 0.12] {
            let start = ProcessInfo.processInfo.systemUptime
            do {
                try acquireOperationLock(waiter, waitingUpTo: timeout)
                preconditionFailure("A held lock must time out")
            } catch is OperationLockBusy {
                precondition(ProcessInfo.processInfo.systemUptime - start >= timeout)
            }
        }

        let released = DispatchSemaphore(value: 0)
        let start = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(150)) {
            precondition(flock(holder, LOCK_UN) == 0)
            released.signal()
        }
        try acquireOperationLock(waiter, waitingUpTo: 2)
        precondition(released.wait(timeout: .now() + .seconds(1)) == .success)
        precondition(ProcessInfo.processInfo.systemUptime - start >= 0.12)
        precondition(flock(holder, LOCK_EX | LOCK_NB) == -1 && errno == EWOULDBLOCK)

        do {
            try acquireOperationLock(-1, waitingUpTo: 0)
            preconditionFailure("An invalid descriptor must report a system error")
        } catch let error as POSIXError {
            precondition(error.code == .EBADF)
        }
    }

    static func main() throws {
        try verifyStartup()
        try verifyPacketFilterRoot()
        verifyHTTPSProbe()
        try verifyOperationLock()
        let unverified = ProtectionRecord(phase: .prepared, bootID: "prior", sourceRevision: "revision")
        precondition(unverified.resumedAtBoot("new", enabled: true) == nil)

        let stopped = ProtectionRecord(phase: .prepared, bootID: "prior", verified: true, sourceRevision: "revision")
        precondition(stopped.resumedAtBoot("prior", enabled: true) == nil)
        precondition(stopped.resumedAtBoot("new", enabled: false) == nil)
        precondition(stopped.resumedAtBoot("new", enabled: true)?.phase == .protected)
        precondition(stopped.resumedAtBoot("new", enabled: true)?.sourceRevision == "revision")

        let running = ProtectionRecord(phase: .protected, bootID: "prior", verified: true, sourceRevision: "revision")
        precondition(running.resumedAtBoot("new", enabled: true)?.phase == .protected)
        precondition(running.resumedAtBoot("prior", enabled: true) == nil)
        precondition(running.resumedAtBoot("new", enabled: false) == nil)
        precondition(!running.expired(bootID: "new", now: 500))

        let starting = ProtectionRecord(phase: .starting, deadline: 90, bootID: "prior", verified: true, sourceRevision: "revision")
        precondition(!starting.expired(bootID: "prior", now: 89))
        precondition(starting.expired(bootID: "prior", now: 90))
        precondition(starting.expired(bootID: "new", now: 1))
        precondition(starting.resumedAtBoot("prior", enabled: true) == nil)
        precondition(starting.resumedAtBoot("new", enabled: false) == nil)

        guard let resumed = starting.resumedAtBoot("new", enabled: true) else {
            fatalError("A verified deployment must resume after reboot when boot protection is enabled")
        }
        precondition(resumed.phase == .protected)
        precondition(resumed.bootID == "new")
        precondition(resumed.verified)
        precondition(resumed.deadline == nil)
        precondition(!resumed.expired(bootID: "new", now: 500))

        let trial = ProtectionRecord(phase: .firewallTrial, deadline: 100, bootID: "prior", sourceRevision: "revision")
        precondition(trial.resumedAtBoot("new", enabled: true) == nil)
        precondition(trial.expired(bootID: "new", now: 1))
    }
}
