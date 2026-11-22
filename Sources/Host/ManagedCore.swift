import Darwin
import Foundation

private extension Engine {
    func automaticallySelect(probeAt url: String) {
        let groups = [RuleTarget.proxy] + profile.routing.groups.map(\.target)
        var health: [String: Bool] = [:]
        for group in groups {
            let order = profile.order(for: group)
            guard order.count > 1, let current = try? self.current(in: group) else { continue }
            let candidate = order.first { name in
                if let cached = health[name] { return cached }
                let reachable = (try? measure(name, url: url)) != nil
                health[name] = reachable
                return reachable
            }
            guard let candidate, current != candidate else { continue }
            try? paths.locked {
                guard try self.current(in: group) == current else { return }
                try select(candidate, in: group)
            }
        }
    }
}

struct ManagedCore {
    let engine: Engine
    let process = Process()

    init(_ paths: Paths, system: Bool = false) throws {
        engine = try Engine(paths, system: system)
        process.executableURL = paths.core
        process.arguments = ["-D", paths.state.path, "run", "-c", paths.config.path]
        try process.run()
    }

    func wait(probeAt url: String = probeURL) throws {
        let signalQueue = DispatchQueue(label: "proxyctl.shutdown")
        let signals = [SIGINT, SIGTERM, SIGHUP].map { signum in
            signal(signum, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signum, queue: signalQueue)
            source.setEventHandler {
                if process.isRunning { process.terminate() }
            }
            source.resume()
            return source
        }
        let monitor = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "proxyctl.failover"))
        monitor.schedule(deadline: .now() + .seconds(2), repeating: .seconds(8))
        monitor.setEventHandler {
            if process.isRunning { engine.automaticallySelect(probeAt: url) }
        }
        monitor.resume()
        process.waitUntilExit()
        monitor.cancel()
        for (index, source) in signals.enumerated() {
            source.cancel()
            signal([SIGINT, SIGTERM, SIGHUP][index], SIG_DFL)
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let status = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
            throw ExitCode(value: status)
        }
    }
}
