import Darwin
import Foundation

struct RunResult {
    let status: Int32
    let output: Data
    var text: String { String(decoding: output, as: UTF8.self) }
}

func run(_ executable: String, _ arguments: [String], input: Data? = nil,
         capture: Bool = true, quiet: Bool = false, mergeError: Bool = false,
         environment: [String: String]? = nil) throws -> RunResult {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = arguments
    if let environment { child.environment = environment }
    let output = Pipe()
    if capture { child.standardOutput = output }
    if quiet { child.standardError = FileHandle.nullDevice }
    if capture && mergeError { child.standardError = output }
    let inputPipe = Pipe()
    if input != nil { child.standardInput = inputPipe }
    try child.run()
    if let input {
        try inputPipe.fileHandleForWriting.write(contentsOf: input)
        try inputPipe.fileHandleForWriting.close()
    }
    let data = capture ? output.fileHandleForReading.readDataToEndOfFile() : Data()
    child.waitUntilExit()
    return RunResult(status: child.terminationStatus, output: data)
}

func checkedStatus(_ result: RunResult) throws {
    guard result.status == 0 else { throw ExitCode(value: result.status) }
}

struct ExitCode: Error { let value: Int32 }

private func foregroundOutput(_ output: FileHandle, onTick: () -> Void) -> Data {
    var data = Data()
    var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
    while true {
        onTick()
        let ready = poll(&descriptor, 1, 50)
        if ready < 0 && errno != EINTR {
            data.append(output.readDataToEndOfFile())
            return data
        }
        guard ready > 0 else { continue }
        let chunk = output.availableData
        guard !chunk.isEmpty else { return data }
        data.append(chunk)
    }
}

// A console password prompt needs the foreground process group. Foundation's Process
// gives children a separate group on macOS, so interactive commands inherit it here.
func runForeground(_ executable: String, _ arguments: [String], input: Data? = nil,
                   capture: Bool = false, environment: [String: String]? = nil,
                   onTick: (() -> Void)? = nil) throws -> RunResult {
    func check(_ code: Int32) throws {
        if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }

    var actions: posix_spawn_file_actions_t?
    try check(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }

    let output = capture ? Pipe() : nil
    if let output {
        let writer = output.fileHandleForWriting.fileDescriptor
        try check(posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, writer, STDERR_FILENO))
        try check(posix_spawn_file_actions_addclose(&actions, writer))
        try check(posix_spawn_file_actions_addclose(&actions, output.fileHandleForReading.fileDescriptor))
    }

    var submission: FileHandle?
    if let input {
        // An unlinked file supplies configuration bytes independently of the password prompt.
        var name = FileManager.default.temporaryDirectory.appendingPathComponent("proxyctl-submit.XXXXXX").path.utf8CString
        let fd = name.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let removed = name.withUnsafeBufferPointer { unlink($0.baseAddress!) }
        if removed != 0 { try check(errno) }
        try file.write(contentsOf: input)
        try file.seek(toOffset: 0)
        try check(posix_spawn_file_actions_adddup2(&actions, fd, STDIN_FILENO))
        if fd != STDIN_FILENO { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
        submission = file
    }

    var argv = ([executable] + arguments).map { strdup($0) }
    var envp = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") }
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }
    guard !argv.contains(nil), !envp.contains(nil) else { throw POSIXError(.ENOMEM) }
    argv.append(nil)
    envp.append(nil)
    var pid: pid_t = 0
    try withExtendedLifetime(submission) {
        try check(posix_spawn(&pid, executable, &actions, nil, &argv, &envp))
    }
    try? output?.fileHandleForWriting.close()
    let data = output.map { pipe in
        if let onTick { return foregroundOutput(pipe.fileHandleForReading, onTick: onTick) }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    } ?? Data()
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 {
        let code = errno
        if code != EINTR { try check(code) }
    }
    // waitpid produces either an exit status in the upper byte or a terminating signal.
    let signal = status & 0x7f
    return RunResult(status: signal == 0 ? (status >> 8) & 0xff : 128 + signal, output: data)
}
