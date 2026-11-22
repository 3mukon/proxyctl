import Foundation

@main
struct ManagedCoreFixture {
    static func main() throws {
        let args = CommandLine.arguments
        let state = URL(fileURLWithPath: args[1], isDirectory: true)
        let core = URL(fileURLWithPath: args[2])
        try ManagedCore(Paths(state: state, core: core)).wait(probeAt: "http://127.0.0.1:9/health")
    }
}
