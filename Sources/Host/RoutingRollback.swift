import Foundation

struct RoutingRollback {
    let config: URL

    private var backup: URL {
        config.deletingLastPathComponent().appendingPathComponent("routing-rollback.json")
    }
    var pending: Bool { FileManager.default.fileExists(atPath: backup.path) }

    func arm(_ previous: Data) throws {
        try savePrivate(previous, to: backup)
    }

    func commit() throws {
        try FileManager.default.removeItem(at: backup)
    }

    func restore(stop: () throws -> Void, start: () throws -> Void) throws {
        guard pending else { return }
        try stop()
        try savePrivate(localData(backup), to: config)
        try start()
        try commit()
    }
}
