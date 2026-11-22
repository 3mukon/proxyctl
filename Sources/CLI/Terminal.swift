import Darwin
import Foundation

@_silgen_name("proxyctl_terminal_size")
private func terminalSize(_ columns: UnsafeMutablePointer<UInt16>, _ rows: UnsafeMutablePointer<UInt16>) -> Int32
@_silgen_name("proxyctl_terminal_begin")
private func beginTerminalSignals()
@_silgen_name("proxyctl_terminal_end")
private func endTerminalSignals()
@_silgen_name("proxyctl_terminal_interrupt")
private func interruptedTerminalSignal() -> Int32
@_silgen_name("proxyctl_terminal_width")
private func terminalScalarWidth(_ scalar: UInt32) -> Int32

let csi = "\u{1b}["
let consoleInputLimit = 4096

struct TerminalSize: Equatable {
    let columns: Int
    let rows: Int
}

enum ConsoleKey {
    case text(String), paste(String, truncated: Bool), up, down, left, right, home, end
    case enter, escape, tab, backspace, delete, interrupt, eof, clear
}

final class Terminal {
    private static let enableInputModes = "\(csi)?2004h\(csi)?1000h\(csi)?1006h"
    private static let disableInputModes = "\(csi)?1006l\(csi)?1000l\(csi)?2004l"
    private var original: termios?
    private var pending: [UInt8] = []
    private var pasted: [UInt8]?
    private(set) var closed = false

    var signal: Int32 { interruptedTerminalSignal() }

    var nativePasswordInputActive: Bool {
        guard let original else { return false }
        var current = termios()
        guard tcgetattr(STDIN_FILENO, &current) == 0, current.c_lflag & tcflag_t(ECHO) == 0 else { return false }
        // macOS sudo disables the terminal status key while reading a password.
        // Read only the terminal settings, leaving all password input with sudo.
        let status = withUnsafeBytes(of: current.c_cc) { $0[Int(VSTATUS)] }
        let originalStatus = withUnsafeBytes(of: original.c_cc) { $0[Int(VSTATUS)] }
        return status != originalStatus
    }

    var size: TerminalSize {
        var columns: UInt16 = 80
        var rows: UInt16 = 24
        _ = terminalSize(&columns, &rows)
        return TerminalSize(columns: Int(columns), rows: Int(rows))
    }

    func enter() -> Bool {
        var attributes = termios()
        guard tcgetattr(STDIN_FILENO, &attributes) == 0 else { return false }
        var raw = attributes
        cfmakeraw(&raw)
        beginTerminalSignals()
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            endTerminalSignals()
            return false
        }
        original = attributes
        send("\(csi)?1049h" + Self.enableInputModes)
        return true
    }

    func withCookedInput<T>(echo: Bool = true, _ body: () throws -> T) throws -> T {
        guard let original else { throw POSIXError(.ENOTTY) }
        var attributes = original
        if !echo { attributes.c_lflag &= ~tcflag_t(ECHO | ECHONL) }
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &attributes) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        pending.removeAll()
        pasted = nil
        send(Self.disableInputModes)
        defer {
            var raw = original
            cfmakeraw(&raw)
            if tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 { send(Self.enableInputModes) }
            else { closed = true }
        }
        return try body()
    }

    func leave() {
        guard var attributes = original else { return }
        original = nil
        pending.removeAll()
        pasted = nil
        send(Self.disableInputModes + "\(csi)0m\(csi)?25h\(csi)?1049l")
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &attributes)
        endTerminalSignals()
    }

    func send(_ frame: String) {
        Data(frame.utf8).withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = write(STDOUT_FILENO, start + sent, bytes.count - sent)
                if count > 0 { sent += count }
                else if count == 0 || errno != EINTR { closed = true; return }
            }
        }
    }

    private func refill(_ wait: Int32) -> Bool {
        if !pending.isEmpty { return true }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, wait) > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
        if count > 0 { pending = Array(buffer.prefix(count)) }
        else if count == 0 || errno != EINTR { closed = true }
        return !pending.isEmpty
    }

    private func pop(_ wait: Int32) -> UInt8? {
        refill(wait) ? pending.removeFirst() : nil
    }

    func nextKey() -> ConsoleKey? {
        if pasted != nil { return continuePaste() }
        guard let first = pop(80) else { return nil }
        switch first {
        case 3: return .interrupt
        case 4: return .eof
        case 8, 127: return .backspace
        case 9: return .tab
        case 10, 13: return .enter
        case 12: return .clear
        case 27: return escapeKey()
        case 32...126: return .text(String(UnicodeScalar(first)))
        case 0xc2...0xf4:
            let length = first < 0xe0 ? 2 : (first < 0xf0 ? 3 : 4)
            var scalar = [first]
            while scalar.count < length {
                guard let next = pop(35) else { return nil }
                guard (0x80...0xbf).contains(next) else { pending.insert(next, at: 0); return nil }
                scalar.append(next)
            }
            return String(bytes: scalar, encoding: .utf8).map(ConsoleKey.text)
        default: return nil
        }
    }

    private func escapeKey() -> ConsoleKey? {
        guard let next = pop(35) else { return .escape }
        guard next == 91 || next == 79 else {
            pending.insert(next, at: 0)
            return .escape
        }
        var sequence: [UInt8] = []
        while sequence.count < 64, let byte = pop(35) {
            sequence.append(byte)
            if (0x40...0x7e).contains(byte) { break }
        }
        if next == 91 && sequence == [77] {
            // X10-style mouse reports carry three bytes after CSI M.
            for _ in 0..<3 { _ = pop(35) }
            return nil
        }
        switch String(decoding: sequence, as: UTF8.self) {
        case "A": return .up
        case "B": return .down
        case "C": return .right
        case "D": return .left
        case "H", "1~", "7~": return .home
        case "F", "4~", "8~": return .end
        case "3~": return .delete
        case "200~": pasted = []; return continuePaste()
        default: return nil
        }
    }

    private func continuePaste() -> ConsoleKey? {
        let end = Array("\(csi)201~".utf8)
        // Keep a tail for the marker if a paste arrives in several reads.
        guard var buffer = pasted else { return nil }
        while let byte = pop(30) {
            buffer.append(byte)
            if buffer.suffix(end.count).elementsEqual(end) {
                let content = buffer.dropLast(end.count)
                let text = String(decoding: content.prefix(consoleInputLimit), as: UTF8.self)
                pasted = nil
                return .paste(text, truncated: content.count > consoleInputLimit)
            }
            if buffer.count > consoleInputLimit + 1 + end.count { buffer.remove(at: consoleInputLimit + 1) }
        }
        pasted = buffer
        return nil
    }
}

private func cellWidth(_ character: Character) -> Int {
    if character.unicodeScalars.contains(where: { $0.value == 0xfe0f || $0.properties.isEmojiPresentation }) { return 2 }
    return character.unicodeScalars.map { max(0, Int(terminalScalarWidth($0.value))) }.max() ?? 0
}

func cellCount(_ text: String) -> Int {
    text.reduce(0) { $0 + cellWidth($1) }
}

func cellPrefix(_ text: String, width: Int) -> String {
    var used = 0
    return String(text.prefix { character in
        used += cellWidth(character)
        return used <= width
    })
}

func fitted(_ text: String, width: Int) -> String {
    if width <= 0 { return "" }
    return cellCount(text) <= width ? text : cellPrefix(text, width: width - 1) + "…"
}

func wrapped(_ text: String, width: Int) -> [String] {
    var lines: [String] = []
    var line = ""
    var columns = 0
    for character in text {
        let cells = cellWidth(character)
        if cells > width { continue }
        if columns + cells > width {
            lines.append(line)
            line = ""
            columns = 0
        }
        line.append(character)
        columns += cells
    }
    lines.append(line)
    return lines
}
