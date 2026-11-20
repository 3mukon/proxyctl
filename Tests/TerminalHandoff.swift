import Darwin
import Foundation

// The isolated terminal target does not use the paste sanitizer from Host.
func terminalText(_ text: String) -> String { text }

@main
struct TerminalHandoffTests {
    enum TestError: Error { case expected }

    static func flags(_ fd: Int32) -> tcflag_t {
        var attributes = termios()
        precondition(tcgetattr(fd, &attributes) == 0)
        return attributes.c_lflag & tcflag_t(ICANON | ECHO | ISIG)
    }

    static func authenticate() throws {
        let fd = open("/dev/tty", O_RDWR | O_CLOEXEC)
        precondition(fd >= 0)
        let tty = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        precondition(flags(fd) & tcflag_t(ICANON | ECHO) == tcflag_t(ICANON | ECHO))
        var attributes = termios()
        precondition(tcgetattr(fd, &attributes) == 0)
        var original = attributes
        attributes.c_lflag &= ~tcflag_t(ECHO)
        withUnsafeMutableBytes(of: &attributes.c_cc) { codes in
            codes[Int(VSTATUS)] ^= 0xff
        }
        precondition(tcsetattr(fd, TCSAFLUSH, &attributes) == 0)
        usleep(150_000)
        try tty.write(contentsOf: Data("Native input ready\n".utf8))
        var bytes = [UInt8](repeating: 0, count: 100)
        let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        precondition(count > 0 && Data(bytes.prefix(count)) == Data("test-value\n".utf8))
        precondition(tcsetattr(fd, TCSANOW, &original) == 0)
        precondition(FileHandle.standardInput.readDataToEndOfFile() == Data("test submission".utf8))
        precondition(ProcessInfo.processInfo.environment["PROXYCTL_HANDOFF_TEST"] == "1")
        print("Captured operation output")
    }

    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--authenticate" {
            try authenticate()
            return
        }
        let original = flags(STDIN_FILENO)
        let terminal = Terminal()
        precondition(terminal.enter())
        defer {
            terminal.leave()
            precondition(flags(STDIN_FILENO) == original)
        }
        let raw = flags(STDIN_FILENO)
        precondition(raw & tcflag_t(ICANON) == 0)
        try terminal.withCookedInput {
            precondition(flags(STDIN_FILENO) == original)
            var inputObserved = false
            var submissionObserved = false
            let result = try runForeground(CommandLine.arguments[0], ["--authenticate"],
                                           input: Data("test submission".utf8), capture: true,
                                           environment: ["PROXYCTL_HANDOFF_TEST": "1"]) {
                if terminal.nativePasswordInputActive { inputObserved = true }
                else if inputObserved { submissionObserved = true }
            }
            precondition(result.status == 0 && result.output == Data("Captured operation output\n".utf8))
            precondition(inputObserved && submissionObserved)
        }
        precondition(flags(STDIN_FILENO) == raw)
        do {
            try terminal.withCookedInput(echo: false) {
                precondition(flags(STDIN_FILENO) == original & ~tcflag_t(ECHO))
                throw TestError.expected
            }
        } catch TestError.expected {
            precondition(flags(STDIN_FILENO) == raw)
        }
        terminal.send("Raw input restored\r\n")
    }
}
