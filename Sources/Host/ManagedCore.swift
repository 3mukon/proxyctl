import Darwin
import Foundation

struct SelectionPreference: Codable, Equatable {
    let scope: String
    let automatic: Bool
    let url: String
}

extension Engine {
    private var preferenceFile: URL { paths.state.appendingPathComponent("selection-mode.json") }

    func selectionPreference() -> SelectionPreference {
        if let data = try? localData(preferenceFile),
           let saved = try? JSONDecoder().decode(SelectionPreference.self, from: data),
           saved.scope == profile.secret {
            return saved
        }
        return SelectionPreference(scope: profile.secret, automatic: true, url: probeURL)
    }

    func setSelection(automatic: Bool, url: String) throws {
        try Engine.validateCheckURL(url)
        let state = SelectionPreference(scope: profile.secret, automatic: automatic, url: url)
        try savePrivate(JSONEncoder().encode(state), to: preferenceFile)
    }

    func automaticallySelect() throws {
        let preference = selectionPreference()
        guard preference.automatic, profile.order.count > 1 else { return }
        let current = try self.current()
        guard let candidate = profile.order.first(where: { (try? measure($0, url: preference.url)) != nil }),
              current != candidate else { return }
        try paths.locked {
            // A manual selection or another runtime may have changed the policy during probing.
            guard selectionPreference() == preference, try self.current() == current else { return }
            try select(candidate)
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

    func wait() throws {
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
            if process.isRunning { try? engine.automaticallySelect() }
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

func selectionModeLine(_ automatic: Bool) -> String {
    automatic ? localized("节点选择     主备自动", "Selection    Automatic failover") :
        localized("节点选择     手动固定", "Selection    Pinned")
}
