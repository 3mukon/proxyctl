import Darwin
import Foundation

private struct CommandChoice {
    let title: String
    let detail: String
    let arguments: [String]
    let needsArgument: Bool
    let isValue: Bool
    let help: String

    init(_ title: String, _ detail: String, _ arguments: [String]? = nil, needsArgument: Bool = false,
         isValue: Bool = false, help: String? = nil) {
        self.title = title
        self.detail = detail
        self.arguments = arguments ?? [title]
        self.needsArgument = needsArgument
        self.isValue = isValue
        self.help = help ?? detail
    }
}

private struct FormChoice {
    let title: String
    var detail = ""
    var searchNames: [String] = []
    let choose: (TerminalConsole) throws -> Void
}

private struct ConsoleForm {
    let title: String
    let prompt: String
    var choices: [FormChoice] = []
    var accept: ((TerminalConsole, String) throws -> Void)? = nil
}

private enum EscapeStep {
    case deselect, dismissCompletions, backFromInput, backFromForm, backFromResult
}

private var commands: [CommandChoice] {
    [
        .init("status", localized("查看全机接管、防火墙和当前节点", "Show system capture, firewall status, and the active node"),
              help: localized("查看全机接管、PF 防护、开机自启和当前节点。", "See system capture, PF protection, startup at boot, and the active node.")),
        .init("nodes", localized("查看或添加节点，编辑默认代理组", "View or add nodes and edit the default proxy group"),
              help: localized("查看节点的协议、地址类型和它在默认代理组中的顺位。", "See each node’s protocol, address type, and priority in the default proxy group.")),
        .init("use", localized("固定默认代理组的节点，或按顺位自动切换", "Pin a node in the default group or follow node priority"), needsArgument: true,
              help: localized("内核运行时，指定默认组的当前节点，或用 --auto 恢复按顺位自动选择。", "While the engine runs, choose the active group member or use --auto to follow node priority.")),
        .init("check", localized("检查当前代理路径，也可单独检测指定节点", "Check the active proxy path or test a specific node"),
              help: localized("检查正在运行的全机接管或本机代理。两者均未运行时，单独测试首选节点。", "Check system capture or the running local proxy. If neither is active, test the first node in isolation.")),
        .init("rules", localized("增删分流规则，设置其余流量的出口", "Add or remove rules and choose where unmatched traffic goes"),
              help: localized("查看自定义规则和「其余全部」当前使用的出口。", "List custom rules and see where unmatched traffic goes.")),
        .init("presets", localized("启停分流预设、编辑匹配项、选择出口", "Turn presets on or off, edit matches, and choose outbounds"),
              help: localized("查看 Claude、OpenAI 和自定义分流预设。", "See the Claude, OpenAI, and custom routing presets.")),
        .init("setup", localized("导入节点文件或编辑外部代理地址", "Import a node file or edit the external proxy address"),
              help: localized("打开节点导入向导，也可在这里管理外部代理地址。",
                              "Open the node import guide or choose a subcommand to manage an external proxy address.")),
        .init("system", localized("启停系统代理、回退和开机自启", "Manage the system proxy, recovery, and startup at boot"),
              help: localized("查看系统状态。启动会验证隧道和防火墙。开机自启可单独设置。",
                              "View system status. Start verifies the tunnel and firewall. Startup at boot is separate.")),
        .init("lang", localized("切换简体中文或 English", "Choose Simplified Chinese or English"), needsArgument: true,
              help: localized("设置界面语言。", "Set the interface language.")),
        .init("help", localized("查看命令和按键用法", "Show commands and keyboard shortcuts")),
        .init("quit", localized("退出控制台", "Exit the console"))
    ]
}

private func commandOptions(for command: String) -> [CommandChoice] {
    switch command {
    case "nodes":
        return [
            .init("add", localized("从剪贴板添加分享链接", "Add share links from clipboard"), ["nodes", "add"],
                  help: localized("从剪贴板导入节点分享链接。", "Import share links from the clipboard.")),
            .init("group", localized("编辑默认代理组", "Edit the default proxy group"), ["nodes", "group"],
                  help: localized("用现有节点编辑本机默认代理组的成员和顺位。", "Edit local default group membership and priority using existing nodes."))
        ]
    case "use":
        return [
            .init("--auto", localized("主备自动切换", "Enable ordered failover"), ["use", "--auto"], isValue: true,
                  help: localized("按节点顺位自动切换主备。", "Follow node priority and switch automatically."))
        ]
    case "check":
        return [
            .init("node", localized("检测指定节点", "Check a specific node"), ["check", "node"],
                  help: localized("从已导入节点中选择一个，隔离检测其转发。", "Choose an imported node and test its forwarding in isolation."))
        ]
    case "rules":
        return [
            .init("add", localized("添加分流规则", "Add a routing rule"), ["rules", "add"],
                  help: localized("为域名后缀、IP 地址或 CIDR 网段选择出口。",
                                  "Choose an outbound for a domain suffix, IP address, or CIDR range.")),
            .init("remove", localized("移除分流规则", "Remove a routing rule"), ["rules", "remove"],
                  help: localized("从已有分流规则中选择要移除的一条。", "Select an existing routing rule to remove.")),
            .init("default", localized("设置其余流量的出口", "Choose where unmatched traffic goes"), ["rules", "default"], needsArgument: true,
                  help: localized("为未匹配分流规则的流量选择出口。可选直连、默认代理组、指定节点或外部代理。首次使用外部代理可在这里填写地址。",
                                  "Choose Direct, the default proxy group, a specific node, or an external proxy for unmatched traffic. You can enter its address here on first use."))
        ]
    case "presets":
        return [
            .init("enable", localized("启用预设", "Enable a preset"), ["presets", "enable"], needsArgument: true,
                  help: localized("启用预设，使其中的匹配条件生效。", "Enable a preset so its matches can apply.")),
            .init("disable", localized("停用预设", "Disable a preset"), ["presets", "disable"], needsArgument: true,
                  help: localized("停用预设，保留成员和出口设置。", "Turn off a preset and save its members and outbound for later.")),
            .init("route", localized("更改预设出口", "Change a preset's outbound"), ["presets", "route"], needsArgument: true,
                  help: localized("选择预设的出口。", "Set a preset's outbound.")),
            .init("edit", localized("创建预设，管理成员和出口", "Create a preset or manage its members and outbound"), ["presets", "edit"],
                  help: localized("新建预设，编辑成员和出口，或删除自定义预设。",
                                  "Create a preset, edit its members and outbound, or delete a custom preset."))
        ]
    case "setup":
        return [
            .init("import", localized("从 sing-box JSON 导入节点", "Import nodes from a sing-box JSON file"), ["setup", "import"],
                  help: localized("从 sing-box JSON 导入节点，选择主备顺位或文件里的代理组。",
                                  "Import nodes from sing-box JSON, then set their priority or select a proxy group from the file.")),
            .init("upstream", localized("查看或编辑外部代理地址", "View or edit the external proxy address"), ["setup", "upstream"],
                  help: localized("添加、修改或清除供规则、自定义预设或「其余全部」使用的 SOCKS5 或 HTTP(S) 地址。",
                                  "Set, change, or clear the SOCKS5 or HTTP(S) address used by rules, custom presets, or unmatched traffic."))
        ]
    case "system":
        return [
            .init("start", localized("验证并启动系统代理", "Verify and start the system proxy"), ["system", "start"],
                  help: localized("首次自动准备配置，依次验证 TUN 和 PF，通过后启用。失败时回退。",
                                  "Prepare the profile, verify TUN and PF, and keep the deployment after both checks pass.")),
            .init("apply", localized("应用本机预设和其余流量的出口", "Apply local presets and the catch-all"),
                  ["system", "apply"], help: localized("应用待生效的路由设置。连接可能重连，PF 防护保持启用。",
                                                        "Apply pending routing settings. Connections may reconnect while PF stays enabled.")),
            .init("stop", localized("立即停止系统代理", "Stop the system proxy now"), ["system", "stop"]),
            .init("enable", localized("开启开机自启", "Turn startup at boot on"), ["system", "enable"]),
            .init("disable", localized("关闭开机自启", "Turn startup at boot off"), ["system", "disable"]),
            .init("rollback", localized("完整回退并取消开机自启", "Roll back and disable boot startup"), ["system", "rollback"],
                  help: localized("撤销系统隧道、DNS、PF 防护、验收状态和开机自启登记。",
                                  "Remove the system tunnel, DNS, PF protection, verification, and startup at boot."))
        ]
    case "lang":
        return InterfaceLanguage.allCases.map { language in
            let current = language == interfaceLanguage ? localized("当前", "Current") : ""
            let help = language == .zh
                ? localized("使用简体中文界面。", "Use the interface in Simplified Chinese.")
                : localized("使用英文界面。", "Use the interface in English.")
            return .init(language.name, current, ["lang", language.rawValue], isValue: true, help: help)
        }
    default:
        return []
    }
}

func isConsoleCommand(_ name: String) -> Bool {
    // An explicit preview remains available for loopback diagnostics.
    name == "preview" || commands.contains { $0.title == name }
}

var consoleCommandList: String { commands.map { "/" + $0.title }.joined(separator: "  ") }

private func commandHelpRow(_ choice: CommandChoice) -> [String] {
    ["/" + choice.arguments.joined(separator: " "), choice.help]
}

func consoleHelpRows(_ arguments: [String]) throws -> [[String]] {
    guard arguments == ["help"] else {
        throw UserError(localized("输入 /help 查看命令总览。", "Use /help to open the command catalog."))
    }
    return commands.flatMap { ([$0] + commandOptions(for: $0.title)).map(commandHelpRow) }
}

var consoleHelpTips: [String] {
    [localized("输入 / 打开命令菜单。用 ↑↓ 选择，按 Tab 或 Enter 补全。",
               "Type / for commands. Use ↑↓ to select and Tab or Enter to complete."),
     localized("Esc 每次退一步，可以取消高亮、收起补全、撤回输入或退出当前页。",
               "Esc goes back one step at a time through selections, completions, input, and pages."),
     localized("运行 proxyctl help 查看其他终端命令。", "Run proxyctl help for other shell commands.")]
}

func consoleSystemAction(_ arguments: [String]) throws -> Bool {
    guard arguments.first == "system", arguments.count > 1 else { return false }
    if arguments == ["system", "prepare"] { return true }
    guard commandOptions(for: "system").contains(where: { $0.arguments == arguments }) else {
        throw UserError(localized("输入 /system 查看可用操作。", "Use /system to see the available actions."))
    }
    return true
}

private func shortcutRows(for command: String, actions: [String]) -> [[String]] {
    let options = commandOptions(for: command)
    return actions.compactMap { action in
        options.first { $0.title == action }.map { ["/" + $0.arguments.joined(separator: " "), $0.detail] }
    }
}

private var systemActionRows: [[String]] {
    commandOptions(for: "system").map { ["/" + $0.arguments.joined(separator: " "), $0.detail] }
}

var consoleSystemActionHints: [String] {
    systemActionRows.map { $0.joined(separator: "  ") }
}

private var childEnvironment: [String: String] {
    ProcessInfo.processInfo.environment.merging([
        "PROXYCTL_CONSOLE": "1", "PROXYCTL_LANGUAGE": interfaceLanguage.rawValue
    ]) { _, value in value }
}

private func quoted(_ value: String) -> String {
    if !value.isEmpty && !value.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" }) { return value }
    return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

private enum Ink: String {
    case normal = "0"
    case title = "1;38;2;243;240;236"
    case muted = "38;2;151;146;141"
    case border = "38;2;73;68;64"
    case focus = "38;2;125;117;111"
    case selection = "1;38;2;243;240;236;48;2;42;38;35"
    case selectedDetail = "38;2;204;198;192;48;2;42;38;35"
    case warning = "1;38;2;230;183;112"

    static var base: String {
        color ? "\(csi)0;37;40m\(csi)38;2;221;216;211;48;2;0;0;0m" : ""
    }

    func paint(_ text: String) -> String {
        color && self != .normal ? "\(csi)\(rawValue)m" + text + Self.base : text
    }
}

private extension TerminalSize {
    var footerRow: Int { rows - (rows >= 20 ? 2 : 0) }
}

private struct ConsoleCanvas {
    let size: TerminalSize
    let left: Int
    let width: Int
    private(set) var frame: String

    var right: Int { left + width - 1 }
    var contentInset: Int { width >= 44 ? 3 : 2 }
    var isCompact: Bool { size.rows < 9 || width < 22 }
    var composerRow: Int {
        isCompact ? size.rows - (size.rows >= 4 ? 1 : 0) : size.footerRow - 2
    }
    var composerColumn: Int { left + (isCompact ? 2 : 4) }

    init(_ size: TerminalSize, clearsScreen: Bool = true) {
        self.size = size
        let inset = size.columns >= 96 ? 4 : (size.columns >= 42 ? 2 : (size.columns >= 18 ? 1 : 0))
        left = inset + 1
        width = max(1, size.columns - inset * 2)
        frame = clearsScreen ? "\(csi)?25l" + Ink.base + "\(csi)2J" : Ink.base
    }

    mutating func draw(_ text: String, at row: Int, column: Int? = nil, limit: Int? = nil, ink: Ink = .normal) {
        let column = column ?? left
        let room = min(limit ?? width, right - column + 1)
        guard (1...size.rows).contains(row), column >= left, room > 0, !text.isEmpty else { return }
        frame += "\(csi)\(row);\(column)H" + ink.paint(fitted(text, width: room))
    }

    mutating func panel(top: Int, bottom: Int, caption: String = "", badge: String = "",
                        stroke: Ink = .border, width panelWidth: Int? = nil) {
        let width = panelWidth ?? self.width
        let right = left + width - 1
        let rail = String(repeating: "─", count: width - 2)
        draw("╭" + rail + "╮", at: top, ink: stroke)
        draw("╰" + rail + "╯", at: bottom, ink: stroke)
        for row in (top + 1)..<bottom {
            draw("│", at: row, ink: stroke)
            draw("│", at: row, column: right, ink: stroke)
        }
        if !caption.isEmpty {
            draw(" " + fitted(caption, width: width - 8) + " ", at: top, column: left + 2, ink: .muted)
        }
        if !badge.isEmpty {
            let label = " " + fitted(badge, width: width - 8) + " "
            draw(label, at: bottom, column: right - cellCount(label) - 1, ink: .muted)
        }
    }

    private var versionLabel: String { "proxyctl  \(version)" }

    mutating func versionBadge(at row: Int, through edge: Int? = nil) {
        let edge = edge ?? right
        let room = edge - left + 1
        let label = fitted(cellCount(versionLabel) <= room ? versionLabel : version, width: room)
        draw(label, at: row, column: edge - cellCount(label) + 1, ink: .muted)
    }

    mutating func contentHeading(_ heading: String, at row: Int, inset: Int, width panelWidth: Int? = nil,
                                 framed: Bool = false, page: String = "") {
        let contentWidth = (panelWidth ?? width) - 2 * inset
        let column = left + inset
        let edge = column + contentWidth - 1
        let pagePrefix = page.isEmpty ? "" : page + "  "
        let full = pagePrefix + versionLabel
        let short = pagePrefix + version
        let rightRoom = contentWidth - min(10, cellCount(heading)) - 3
        let rightLabel: String
        if cellCount(full) <= rightRoom {
            rightLabel = full
        } else if cellCount(short) <= rightRoom {
            rightLabel = short
        } else {
            rightLabel = page
            if !framed && row > 1 { versionBadge(at: row - 1, through: edge) }
        }

        let rightWidth = cellCount(rightLabel)
        let titleWidth = contentWidth - (rightLabel.isEmpty ? 0 : rightWidth + 3)
        let padding = framed ? " " : ""
        draw(padding + fitted(heading, width: titleWidth) + padding, at: row,
             column: column - cellCount(padding), ink: .title)
        if !rightLabel.isEmpty {
            draw(padding + rightLabel + padding, at: row,
                 column: edge - rightWidth + 1 - cellCount(padding), ink: .muted)
        }
    }

    mutating func pair(_ label: String, detail: String, at row: Int, column: Int, width: Int, labelWidth: Int,
                       ink: Ink = .title, detailInk: Ink = .muted, selected: Bool = false) {
        if selected { draw(String(repeating: " ", count: width), at: row, column: column, ink: .selection) }
        draw(label, at: row, column: column, limit: labelWidth, ink: selected ? .selection : ink)
        let gap = labelWidth + 2
        draw(detail, at: row, column: column + gap, limit: width - gap, ink: selected ? .selectedDetail : detailInk)
    }

    mutating func cursor(at row: Int, column: Int, visible: Bool = true) {
        frame += "\(csi)\(row);\(min(size.columns, column))H\(csi)?25\(visible ? "h" : "l")"
    }
}

private struct Page {
    let index: Int
    let count: Int
    let rows: Range<Int>

    init(total: Int, capacity: Int, index: Int) {
        let capacity = max(1, capacity)
        count = max(1, (total + capacity - 1) / capacity)
        self.index = min(count - 1, max(0, index))
        let first = self.index * capacity
        rows = first..<min(total, first + capacity)
    }

    var label: String { localized("第 \(index + 1)/\(count) 页", "Page \(index + 1)/\(count)") }
}

private struct ConsoleLine {
    let text: String
    let ink: Ink
    let label: String

    init(_ text: String, _ ink: Ink = .normal, label: String = "") {
        self.text = text
        self.ink = ink
        self.label = label
    }
}

private struct ConsoleTable {
    let headings: [String]
    let rows: [[String]]

    init(_ headings: [String] = [], rows: [[String]]) {
        self.headings = headings
        self.rows = rows
    }

    func layout(width: Int) -> (header: [ConsoleLine], lines: [ConsoleLine]) {
        guard let first = rows.first else { return ([], []) }
        let columns = first.indices
        let gap = width >= 64 ? 3 : 2
        var widths = columns.map { max(4, cellCount(headings[safe: $0] ?? "")) }
        var remaining = width - gap * (columns.count - 1) - widths.reduce(0, +)
        if remaining < 0 {
            let lines = rows.flatMap { row -> [ConsoleLine] in
                let title = wrapped(row[0], width: width).map { ConsoleLine($0, .title) }
                let pairs = zip(headings.dropFirst(), row.dropFirst()).map { "\($0.0) \($0.1)" }
                let details = (pairs.isEmpty ? Array(row.dropFirst()) : pairs).joined(separator: "  ·  ")
                return title + wrapped(details, width: max(1, width - 2)).map { ConsoleLine("  " + $0, .muted) }
            }
            return ([], lines)
        }

        let extra = columns.map { index in
            max(0, (rows.map { cellCount($0[index]) }.max() ?? 0) - widths[index])
        }
        let byNeed = columns.sorted { extra[$0] < extra[$1] }
        for (position, column) in byNeed.enumerated() {
            let cells = min(extra[column], remaining / (byNeed.count - position))
            widths[column] += cells
            remaining -= cells
        }

        func line(_ values: [String]) -> String {
            var text = ""
            var column = 0
            for index in columns {
                if !values[index].isEmpty {
                    text += String(repeating: " ", count: max(0, column - cellCount(text))) + values[index]
                }
                column += widths[index] + gap
            }
            return text
        }

        let tableWidth = widths.reduce(0, +) + gap * (columns.count - 1)
        let header = headings.isEmpty ? [] : [ConsoleLine(line(headings), .muted),
                                             ConsoleLine(String(repeating: "─", count: tableWidth), .border)]
        let lines = rows.flatMap { row -> [ConsoleLine] in
            let cells = zip(row, widths).map { wrapped($0.0, width: $0.1) }
            return (0..<(cells.map(\.count).max() ?? 0)).map { index in
                let values = cells.map { $0[safe: index] ?? "" }
                return ConsoleLine(line(values), label: headings.isEmpty ? values[0] : "")
            }
        }
        return (header, lines)
    }
}

private final class ConsoleProcess {
    let process = Process()
    let onSuccess: ((TerminalConsole) -> Void)?
    private let output = Pipe()
    private(set) var data = Data()
    private let cap = 192 * 1024
    private(set) var truncated = false

    init(_ executable: URL, _ arguments: [String], onSuccess: ((TerminalConsole) -> Void)? = nil) throws {
        self.onSuccess = onSuccess
        process.executableURL = executable
        process.arguments = arguments
        process.environment = childEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let descriptor = output.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw UserError(localized("无法读取命令输出。", "Could not read command output."))
        }
        try process.run()
        try output.fileHandleForWriting.close()
    }

    @discardableResult
    func drain() -> Bool {
        let before = data.count
        var buffer = [UInt8](repeating: 0, count: 4096)
        let descriptor = output.fileHandleForReading.fileDescriptor
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            let room = max(0, cap - data.count)
            data.append(contentsOf: buffer.prefix(min(count, room)))
            if count > room { truncated = true }
        }
        return data.count != before
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }
}

private struct Draft {
    var text = ""
    var cursor = 0

    mutating func replace(_ text: String) {
        self.text = text
        cursor = text.count
    }

    mutating func insert(_ value: String) {
        let value = terminalText(value)
        guard text.utf8.count + value.utf8.count <= 4096 else { return }
        let position = text.index(text.startIndex, offsetBy: cursor)
        let before = String(text[..<position]) + value
        text = before + text[position...]
        cursor = before.count
    }

    mutating func delete(backward: Bool) {
        let index = cursor - (backward ? 1 : 0)
        guard (0..<text.count).contains(index) else { return }
        text.remove(at: text.index(text.startIndex, offsetBy: index))
        cursor = min(index, text.count)
    }

    func viewport(_ width: Int) -> (String, Int) {
        var before = String(text.prefix(cursor))
        var cells = cellCount(before)
        while cells >= width && !before.isEmpty {
            let first = before.removeFirst()
            cells -= cellCount(String(first))
        }
        return (before + cellPrefix(String(text.dropFirst(cursor)), width: width - cells), cells)
    }
}

private final class TerminalConsole {
    private let paths: Paths
    private let executable: URL
    private let terminal: Terminal
    private var status: Status
    private var profile: ManagedProfile?
    private var draft = Draft()
    private var resultTitle: String?
    private var result: [ConsoleLine] = []
    private var resultTable: ConsoleTable?
    private var resultShortcuts: [[String]] = []
    private var pageIndex = 0
    private var lastPage = 0
    private var history: [String] = []
    private var historyIndex: Int?
    private var historyDraft = ""
    private var selection: Int? = 0
    private var deselectedIndex: Int?
    private var completedArgumentCount = 0
    private var dismissed = false
    private var form: ConsoleForm?
    private var formHistory: [(form: ConsoleForm, draft: Draft, selection: Int?, deselectedIndex: Int?, page: Int)] = []
    private var formOriginPage = 0
    private var formError: String?
    private var child: ConsoleProcess?
    private var runningLabel = ""
    private var cancelling = false
    private var done = false

    init(_ paths: Paths, executable: URL, terminal: Terminal) {
        self.paths = paths
        self.executable = executable
        self.terminal = terminal
        status = currentStatus(paths)
        profile = try? ManagedProfile(paths.config)
    }

    func start() {
        var size = terminal.size
        render(size)
        while !done && !terminal.closed && terminal.signal == 0 {
            var changed = false
            if let key = terminal.nextKey() {
                handle(key)
                changed = true
            }
            if finishCommand() { changed = true }
            let nextSize = terminal.size
            if nextSize != size { size = nextSize; changed = true }
            if changed && !done { render(size) }
        }
        child?.cancel()
    }

    private var activeSystem: ProtectionStatus? {
        protectedConsoleStatus(paths, status.protectedSystem)
    }

    private var displayedSelectedNode: String? {
        if let system = activeSystem { return system.selectedNode }
        return status.selectedNode
    }

    private var ruleUpstreamAvailable: Bool {
        if let system = activeSystem { return system.hasUpstream == true }
        return profile?.upstream != nil
    }

    private var visibleChoiceIndex: Int { selection ?? deselectedIndex ?? 0 }

    private var choices: [CommandChoice] {
        if form != nil { return matchingFormChoices.map { CommandChoice($0.title, $0.detail) } }
        guard !dismissed else { return [] }
        return suggestions.filter { $0.arguments.count > completedArgumentCount }
    }

    private var requiresCompletion: Bool {
        guard draft.text.hasPrefix("/"), var arguments = try? parseLine(draft.text), let first = arguments.first else { return false }
        let command = consoleCommand(first)
        arguments[0] = command
        if command == "presets", let name = arguments[safe: 2], let groups = profile?.routing.collections,
           let index = RuleCollection.index(matching: name, in: groups) {
            arguments[2] = groups[index].name
        }
        let options = arguments.count == 1 ? commands : commandOptions(for: command)
        if options.contains(where: { $0.needsArgument && $0.arguments == arguments }) { return true }

        // Optional subcommands only become completions once the draft starts typing their command word.
        let matches = suggestions.filter { $0.isValue || $0.arguments.count <= arguments.count }
        guard !matches.isEmpty else { return false }
        if command == "setup", arguments.count == 2,
           FileManager.default.fileExists(atPath: (arguments[1] as NSString).expandingTildeInPath) {
            return false
        }
        let ignoresValueCase = command == "presets" || command == "rules"
        return !matches.contains { choice in
            guard !choice.needsArgument else { return false }
            if ignoresValueCase && choice.isValue {
                return arguments.elementsEqual(choice.arguments, by: { $0.caseInsensitiveCompare($1) == .orderedSame })
            }
            return arguments == choice.arguments
        }
    }

    private var matchingFormChoices: [FormChoice] {
        let query = draft.text.trimmingCharacters(in: .whitespaces)
        return form?.choices.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) ||
            $0.detail.localizedCaseInsensitiveContains(query) ||
            $0.searchNames.contains { $0.localizedCaseInsensitiveContains(query) }
        } ?? []
    }

    private var argumentContext: (command: String, argument: String)? {
        let input = draft.text.dropFirst()
        guard draft.text.hasPrefix("/"), input.contains(where: \.isWhitespace) else { return nil }
        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first else { return nil }
        let command = consoleCommand(String(first))
        guard isConsoleCommand(command) else { return nil }
        return (command, parts.dropFirst().first.map(String.init) ?? "")
    }

    private var suggestions: [CommandChoice] {
        guard child == nil, draft.text.hasPrefix("/") else { return [] }
        guard let (first, argument) = argumentContext else {
            let query = draft.text.dropFirst().split(whereSeparator: \.isWhitespace).first?.lowercased() ?? ""
            return commands.filter { $0.title.hasPrefix(query) }
        }
        switch first {
        case "lang":
            return commandOptions(for: first).filter {
                $0.arguments.last?.hasPrefix(argument.lowercased()) == true ||
                    $0.title.localizedCaseInsensitiveContains(argument)
            }
        case "presets":
            return profile.map { presetChoices(argument, profile: $0) } ?? []
        case "rules":
            return ruleChoices(argument)
        case "use":
            break
        default:
            return commandOptions(for: first).filter { $0.title.hasPrefix(argument.lowercased()) }
        }
        let order = activeSystem?.order ?? profile?.order ?? []
        let nodes = activeSystem?.nodes ?? profile?.nodes ?? []
        let selected = displayedSelectedNode
        let query = argument.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let choices = order.compactMap { name -> CommandChoice? in
            guard query.isEmpty || name.localizedCaseInsensitiveContains(query),
                  let node = nodes.first(where: { $0.name == name }) else { return nil }
            let marker = selected == name ? localized("当前 · ", "Current · ") : ""
            let endpoint = node.endpoint == "域名" ? localized("域名", "Hostname") : node.endpoint
            return CommandChoice(terminalText(name), marker + "\(node.protocolName) / \(endpoint)", [first, name], isValue: true)
        }
        return choices + commandOptions(for: first).filter { $0.title.hasPrefix(query) }
    }

    private func ruleChoices(_ input: String) -> [CommandChoice] {
        let words = input.split(maxSplits: 2, whereSeparator: \.isWhitespace)
        let current = activeSystem == nil ? profile?.routing.fallback : activeSystem?.fallback
        if words.first == "default", input.contains(where: \.isWhitespace) {
            let query = String(input.dropFirst("default".count))
            let targets = outboundOptions(nodeNames: profile?.nodes.map(\.name) ?? [], hasUpstream: true)
            return outboundChoices(targets, matching: query, command: ["rules", "default"], current: current,
                                   needsUpstreamAddress: profile?.upstream == nil)
        }
        if words.count >= 2, ["add", "remove"].contains(words[0]), input.contains(where: \.isWhitespace) {
            let tail = words.dropFirst(2).first.map(String.init) ?? ""
            let match = (try? parseLine(String(words[1])))?.first ?? String(words[1])
            let available = activeSystem.map { $0.nodeRuleTargets ?? [] } ?? profile?.nodes.map(\.name) ?? []
            let common = RuleTarget.standard.filter { $0 != .upstream || ruleUpstreamAvailable || words.first == "remove" }
            return outboundChoices(common + available.map(RuleTarget.node), matching: tail, command: ["rules", String(words[0]), match])
        }
        return commandOptions(for: "rules").filter { $0.title.hasPrefix(input.lowercased()) }
    }

    private func outboundChoices(_ targets: [RuleTarget], matching input: String, command: [String],
                                 current: RuleTarget? = nil, needsUpstreamAddress: Bool = false) -> [CommandChoice] {
        let query = input.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return targets.filter {
            query.isEmpty || $0.rawValue.lowercased().hasPrefix(query.lowercased()) ||
                $0.displayName.localizedCaseInsensitiveContains(query)
        }.map {
            var detail = $0 == current ? localized("当前", "Current") : ""
            if $0 == .upstream && needsUpstreamAddress {
                detail = localized("填写地址后使用", "Enter an address to use it")
            }
            return CommandChoice($0.displayName, detail, command + [$0.rawValue], isValue: true)
        }
    }

    private func presetChoices(_ input: String, profile: ManagedProfile) -> [CommandChoice] {
        let groups = profile.routing.collections
        let action = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let tail = action.dropFirst().first.map(String.init) ?? ""
        if action.first == "route", input.contains(where: \.isWhitespace) {
            for name in groups.flatMap(\.lookupNames) {
                guard let prefix = tail.range(of: quoted(name) + " ", options: [.anchored, .caseInsensitive]),
                      let index = RuleCollection.index(matching: name, in: groups) else { continue }
                let group = groups[index]
                let targets = outboundOptions(nodeNames: profile.nodes.map(\.name), hasUpstream: profile.upstream != nil,
                                              proxyOnly: group.builtIn)
                return outboundChoices(targets, matching: String(tail[prefix.upperBound...]),
                                       command: ["presets", "route", group.name], current: group.target)
            }
            let query = tail.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return groups.filter { $0.matchesSearch(query) }.map {
                CommandChoice($0.title, $0.target.displayName, ["presets", "route", $0.name], needsArgument: true, isValue: true)
            }
        }
        if let first = action.first, ["enable", "disable"].contains(first), input.contains(where: \.isWhitespace) {
            let query = tail.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return groups.filter { $0.matchesSearch(query) }.map {
                let state = $0.enabled ? localized("已启用", "On") : localized("已停用", "Off")
                return CommandChoice($0.title, state, ["presets", String(first), $0.name], isValue: true)
            }
        }
        return commandOptions(for: "presets").filter { $0.title.hasPrefix(input.lowercased()) }
    }

    private func handle(_ key: ConsoleKey) {
        let available = choices
        if let child {
            switch key {
            case .interrupt, .escape:
                child.cancel()
                cancelling = true
            case .left: pageIndex = max(0, pageIndex - 1)
            case .right: pageIndex = min(lastPage, pageIndex + 1)
            default: break
            }
            return
        }
        switch key {
        case let .text(value): draft.insert(value); edited()
        case .backspace: draft.delete(backward: true); edited()
        case .delete: draft.delete(backward: false); edited()
        case .left:
            if draft.text.isEmpty { pageIndex = max(0, pageIndex - 1) }
            else { draft.cursor = max(0, draft.cursor - 1) }
        case .right:
            if draft.text.isEmpty { pageIndex = min(lastPage, pageIndex + 1) }
            else { draft.cursor = min(draft.text.count, draft.cursor + 1) }
        case .home: draft.cursor = 0
        case .end: draft.cursor = draft.text.count
        case .up: navigate(-1, choices: available)
        case .down: navigate(1, choices: available)
        case .tab:
            if form != nil { navigate(1, choices: available) }
            else if let choice = available[safe: visibleChoiceIndex] { complete(choice) }
            else { _ = reopenCompletions() }
        case .enter:
            if let form {
                if form.accept == nil, selection == nil, !available.isEmpty { selection = visibleChoiceIndex }
                else { submitForm(form) }
            } else if let selection, let choice = available[safe: selection] {
                complete(choice)
            } else if (requiresCompletion || draft.text == "/") && (!available.isEmpty || reopenCompletions()) {
                selection = visibleChoiceIndex
            } else {
                submitDraft()
            }
        case .escape:
            retreat(from: escapeStep(hasChoices: !available.isEmpty))
        case .interrupt:
            if form != nil { backFromForm() }
            else if draft.text.isEmpty { done = true }
            else { draft.replace(""); edited() }
        case .eof:
            if form != nil && draft.text.isEmpty { backFromForm() }
            else if draft.text.isEmpty { done = true }
            else { draft.delete(backward: false); edited() }
        case .clear: showHome()
        }
    }

    private func escapeStep(hasChoices: Bool) -> EscapeStep {
        if hasChoices && selection != nil { return .deselect }
        if form != nil { return draft.text.isEmpty ? .backFromForm : .backFromInput }
        if hasChoices { return .dismissCompletions }
        return draft.text.isEmpty ? .backFromResult : .backFromInput
    }

    private func retreat(from step: EscapeStep) {
        switch step {
        case .deselect:
            deselectedIndex = selection
            selection = nil
        case .dismissCompletions:
            if draft.text == "/" {
                draft.replace("")
                edited(selectFirst: false)
            } else {
                dismissed = true
            }
        case .backFromInput:
            let previous = form == nil ? precedingCommandInput : ""
            draft.replace(previous)
            edited(selectFirst: false)
            dismissed = !previous.isEmpty
        case .backFromForm:
            backFromForm()
        case .backFromResult:
            showHome()
        }
    }

    private var precedingCommandInput: String {
        if historyIndex != nil { return historyDraft }
        guard draft.text.hasPrefix("/"), let words = try? parseLine(draft.text), words.count > 1 else { return "" }
        return words.dropLast().map(quoted).joined(separator: " ") + " "
    }

    private func reopenCompletions() -> Bool {
        guard dismissed, historyIndex == nil else { return false }
        dismissed = false
        let available = choices
        if !available.isEmpty {
            selection = available.indices.contains(visibleChoiceIndex) ? visibleChoiceIndex : 0
            return true
        }
        dismissed = true
        return false
    }

    private func edited(selectFirst: Bool = true) {
        historyIndex = nil
        completedArgumentCount = 0
        formError = nil
        let command = draft.text.trimmingCharacters(in: .whitespaces)
        let ready = form == nil && draft.text.last?.isWhitespace == true &&
            commands.contains { !$0.needsArgument && command == "/" + $0.title }
        selection = selectFirst && !ready ? 0 : nil
        deselectedIndex = nil
        dismissed = false
    }

    private func complete(_ choice: CommandChoice) {
        draft.replace("/" + choice.arguments.map(quoted).joined(separator: " ") + " ")
        edited()
        completedArgumentCount = choice.arguments.count
        selection = choice.needsArgument ? 0 : nil
    }

    private func navigate(_ delta: Int, choices: [CommandChoice]) {
        if !choices.isEmpty {
            if let current = selection ?? deselectedIndex {
                selection = (current + delta + choices.count) % choices.count
            } else {
                selection = delta < 0 ? choices.count - 1 : 0
            }
            return
        }
        guard form == nil, !history.isEmpty else { return }
        if historyIndex == nil {
            guard delta < 0 else { return }
            historyDraft = draft.text
        }
        let index = min(history.count, max(0, (historyIndex ?? history.count) + delta))
        historyIndex = index == history.count ? nil : index
        draft.replace(historyIndex.map { history[$0] } ?? historyDraft)
        dismissed = true
    }

    private func submitDraft() {
        do {
            let arguments = try parseLine(draft.text)
            guard !arguments.isEmpty else { return }
            submit(arguments)
        } catch {
            showResult(localized("命令", "Command"), lines: [ConsoleLine(error.localizedDescription, .warning)])
        }
    }

    private func present(_ next: ConsoleForm, replacing: Bool = false) {
        if let form {
            if !replacing { formHistory.append((form, draft, selection, deselectedIndex, pageIndex)) }
        } else {
            formOriginPage = pageIndex
        }
        form = next
        pageIndex = 0
        draft.replace("")
        edited()
    }

    private func backFromForm() {
        formError = nil
        if let previous = formHistory.popLast() {
            form = previous.form
            draft = previous.draft
            selection = previous.selection
            deselectedIndex = previous.deselectedIndex
            pageIndex = previous.page
        } else {
            form = nil
            pageIndex = formOriginPage
            draft.replace("")
            edited()
        }
    }

    private func submitForm(_ form: ConsoleForm) {
        do {
            if let accept = form.accept { try accept(self, draft.text) }
            else if let selection, let choice = matchingFormChoices[safe: selection] { try choice.choose(self) }
        } catch {
            formError = error.localizedDescription
        }
    }

    private func submit(_ arguments: [String]) {
        var arguments = arguments
        arguments[0] = consoleCommand(arguments[0])
        switch arguments[0] {
        case "quit": done = true; return
        case "home": showHome(); return
        case "lang":
            chooseLanguage(Array(arguments.dropFirst()))
            return
        default: break
        }
        if arguments == ["rules", "default"] {
            draft.replace("/rules default ")
            edited()
            return
        }
        if arguments.starts(with: ["nodes", "add"]), arguments.count > 2 {
            draft.replace("")
            edited()
            showResult(localized("添加节点", "Add nodes"), lines: [
                ConsoleLine(localized("复制分享链接，再运行 /nodes add。", "Copy the share links, then run /nodes add."), .warning)
            ])
            return
        }
        refreshStatus()
        do {
            if try beginForm(arguments) { return }
        } catch {
            draft.replace("")
            edited()
            showResult("/" + arguments[0], lines: [ConsoleLine(error.localizedDescription, .warning)])
            return
        }
        dispatch(arguments)
    }

    private func dispatch(_ arguments: [String]) {
        form = nil
        formHistory.removeAll()
        let label = "/" + arguments.map(quoted).joined(separator: " ")
        draft.replace("")
        edited()
        guard isConsoleCommand(arguments[0]) else {
            showResult(localized("命令", "Command"),
                       lines: [ConsoleLine(localized("输入 / 查看日常命令。", "Type / for daily commands."), .warning)])
            return
        }
        if history.last != label { history.append(label) }
        if history.count > 100 { history.removeFirst() }
        refreshStatus()
        do {
            if try showReport(arguments) { return }
        } catch {
            showResult("›  " + label, lines: [ConsoleLine(terminalText(error.localizedDescription), .warning)])
            return
        }
        showResult("›  " + label)
        let ruleReport = arguments == ["rules"] || arguments == ["rules", "default"]
        let systemCommand = activeSystem != nil && (isProtectedConsoleCommand(arguments) || ruleReport)
        let command = systemCommand && ruleReport ? ["rules"] : arguments
        let invocation = ["--state-dir", paths.state.path] + (systemCommand ? ["system"] : []) + command
        do {
            let directSystemAction = try consoleSystemAction(arguments)
            let applyingPolicy = usesLivePolicy(activeSystem) && changesPolicy(arguments)
            if directSystemAction || applyingPolicy || (systemCommand && arguments[0] != "nodes") {
                let notice: String?
                switch arguments {
                case ["system", "prepare"]:
                    notice = localized("正在验证节点并准备系统配置。", "Checking node forwarding and preparing the system profile.")
                case ["system", "start"]:
                    notice = localized("正在启动系统代理并检查防护。", "Starting the system proxy and checking protection.")
                case ["system", "apply"]:
                    notice = localized("正在应用路由设置。连接可能短暂重连。", "Applying routing settings. Connections may briefly reconnect.")
                default:
                    notice = applyingPolicy ? localized("正在保存并应用路由设置。连接可能短暂重连。",
                                                         "Saving and applying routing settings. Connections may briefly reconnect.") : nil
                }
                let result = try runWithAuthentication(invocation, notice: notice)
                self.result.removeAll()
                let lines = renderOutput(result.output, ink: result.status == 0 ? .normal : .warning)
                refreshStatus()
                if result.status == 0 && systemCommand && ruleReport && showSystemRules(lines) {
                    return
                }
                if lines.isEmpty {
                    let outcome = result.status == 0 ? localized("已完成", "Done") :
                        localized("命令结束（\(result.status)）", "Exited with code \(result.status)")
                    append([ConsoleLine(outcome, result.status == 0 ? .muted : .warning)])
                } else {
                    append(lines)
                }
            } else {
                runningLabel = label
                cancelling = false
                child = try ConsoleProcess(executable, invocation)
            }
        } catch {
            append([ConsoleLine(terminalText(error.localizedDescription), .warning)])
        }
    }

    private func runWithAuthentication(_ invocation: [String], notice: String? = nil) throws -> RunResult {
        let size = terminal.size
        append([ConsoleLine(notice ?? localized("正在执行系统操作。", "Running the system command."), .muted)])
        let frames = passwordFrames(size)
        var environment = childEnvironment
        environment["SUDO_PROMPT"] = frames.prompt
        return try terminal.withCookedInput(echo: false) {
            render(size, authenticating: true)
            var inputStarted: TimeInterval?
            var caretDimmed = false
            return try runForeground(executable.path, invocation, capture: true, environment: environment) { [terminal] in
                guard terminal.signal == 0 else { return }
                if terminal.nativePasswordInputActive {
                    let now = ProcessInfo.processInfo.systemUptime
                    if let inputStarted {
                        let dimmed = Int((now - inputStarted) / 0.5) % 2 == 1
                        if dimmed != caretDimmed {
                            terminal.send(dimmed ? frames.dimCaret : frames.brightCaret)
                            caretDimmed = dimmed
                        }
                    } else {
                        inputStarted = now
                        caretDimmed = false
                        terminal.send(frames.prompt)
                    }
                } else if inputStarted != nil {
                    inputStarted = nil
                    terminal.send(frames.submitted)
                }
            }
        }
    }

    private func passwordFrames(_ size: TerminalSize) -> (prompt: String, brightCaret: String, dimCaret: String, submitted: String) {
        var canvas = ConsoleCanvas(size, clearsScreen: false)
        let row = canvas.composerRow
        let column = canvas.composerColumn
        let edge = canvas.right - (canvas.isCompact ? 0 : 1)
        let blank = String(repeating: " ", count: max(0, edge - column + 1))
        canvas.draw(blank, at: row, column: column)
        let label = fitted(localized("密码", "Password"), width: edge - column - 2)
        canvas.draw(label, at: row, column: column, ink: .title)
        let cursor = min(edge, column + cellCount(label) + 2)
        // sudo writes a newline after input. A drawn caret stays inside the password field.
        canvas.draw("▏", at: row, column: cursor, ink: .title)
        let hintColumn = cursor + 4
        let hintWidth = edge - hintColumn + 1
        let fullHint = localized("输入不回显  ·  Enter 提交", "Input hidden  ·  Enter Submit")
        let hint = cellCount(fullHint) <= hintWidth ? fullHint : localized("Enter 提交", "Enter Submit")
        if cellCount(hint) <= hintWidth {
            canvas.draw(hint, at: row, column: hintColumn, ink: .muted)
        }
        canvas.cursor(at: row, column: cursor, visible: false)

        func caretFrame(dimmed: Bool) -> String {
            var frame = ConsoleCanvas(size, clearsScreen: false)
            let glyph = dimmed && !color ? " " : "▏"
            frame.draw(glyph, at: row, column: cursor, ink: dimmed ? .focus : .title)
            return frame.frame
        }
        var submitted = ConsoleCanvas(size, clearsScreen: false)
        submitted.draw(blank, at: row, column: column)
        submitted.draw(localized("已提交，请稍候…", "Submitted. One moment…"), at: row, column: column,
                       limit: edge - column + 1, ink: .muted)
        return (canvas.frame, caretFrame(dimmed: false), caretFrame(dimmed: true), submitted.frame)
    }

    private func chooseLanguage(_ arguments: [String]) {
        if arguments.isEmpty {
            draft.replace("/lang ")
            edited()
            return
        }
        do {
            guard arguments.count == 1, let language = InterfaceLanguage(rawValue: arguments[0]) else {
                throw UserError(localized("输入 /lang 后按空格选择语言。", "Type /lang followed by Space to choose a language."))
            }
            try selectInterfaceLanguage(language, paths: paths)
            showHome()
        } catch {
            draft.replace("")
            edited()
            showResult(localized("语言", "Language"), lines: [ConsoleLine(error.localizedDescription, .warning)])
        }
    }

    private func showHome() {
        form = nil
        formHistory.removeAll()
        resultTitle = nil
        resultTable = nil
        resultShortcuts.removeAll()
        result.removeAll()
        pageIndex = 0
        draft.replace("")
        edited()
    }

    private func showResult(_ title: String, lines: [ConsoleLine] = [], table: ConsoleTable? = nil, shortcuts: [[String]] = []) {
        resultTitle = title
        resultTable = table
        resultShortcuts = shortcuts
        result = lines
        pageIndex = 0
    }

    private func showReport(_ arguments: [String]) throws -> Bool {
        switch arguments {
        case ["status"], ["system"]:
            showStatus(systemControls: arguments == ["system"])
        case ["nodes"]:
            if let system = activeSystem {
                showNodes(system.nodes, order: system.order, selected: system.selectedNode,
                          source: localized("系统配置", "System profile"))
            } else if FileManager.default.fileExists(atPath: paths.config.path) {
                let local = try profile ?? ManagedProfile(paths.config)
                showNodes(local.nodes, order: local.order, selected: status.selectedNode,
                          source: localized("本机配置", "Local profile"), local: true)
            } else {
                showResult(localized("节点", "Nodes"), lines: [ConsoleLine(addNodesFirst.localizedDescription, .muted)])
            }
        case ["presets"]:
            showPresets()
        case _ where arguments.first == "help":
            let rows = try consoleHelpRows(arguments)
            let headings = [localized("命令", "Command"), localized("说明", "Description")]
            showResult(localized("命令帮助", "Command help"), lines: [ConsoleLine("")] + consoleHelpTips.map { ConsoleLine($0, .muted) },
                       table: ConsoleTable(headings, rows: rows))
        case ["rules"] where activeSystem == nil:
            try showLocalRules()
        default:
            guard arguments.count == 3, arguments.starts(with: ["nodes", "--file"]) else { return false }
            let path = (arguments[2] as NSString).expandingTildeInPath
            let file = try Profile(loadObject(localData(URL(fileURLWithPath: path))))
            showNodes(file.nodes, source: localized("导入文件", "Import file"))
        }
        return true
    }

    private func showNodes(_ nodes: [Node], order: [String] = [], selected: String? = nil, source: String, local: Bool = false) {
        let priorities = Dictionary(order.enumerated().map { ($0.element, $0.offset + 1) }, uniquingKeysWith: { first, _ in first })
        let rows = nodes.map { node in
            let name = terminalText(node.name) + (node.name == selected ? "  ●" : "")
            let address = node.endpoint == "域名" ? localized("域名", "Hostname") : terminalText(node.endpoint)
            return [name, terminalText(node.protocolName).uppercased(), address, priorities[node.name].map(String.init) ?? "—"]
        }
        let headings = [localized("名称", "Name"), localized("协议", "Protocol"), localized("地址类型", "Address"), localized("顺位", "Priority")]
        let shortcuts = local ? shortcutRows(for: "nodes", actions: ["group", "add"]) +
            shortcutRows(for: "setup", actions: ["import"]) : []
        showResult(localized("节点 · \(source)", "Nodes · \(source)"),
                   table: ConsoleTable(headings, rows: rows), shortcuts: shortcuts)
    }

    private func showStatus(systemControls: Bool) {
        let system = status.protectedSystem
        let capture = system?.engineRunning == true ? localized("运行中", "Running") : localized("未启用", "Off")
        let firewall = system?.firewallLoaded == true ? localized("已加载", "Loaded") : localized("未加载", "Not loaded")
        let boot: String
        if let enabled = system?.startsAtBoot {
            boot = enabled ? localized("已启用", "On") : localized("已停用", "Off")
        } else {
            boot = system == nil ? localized("未配置", "Not configured") : localized("未知", "Unknown")
        }
        var rows = [[localized("全机接管", "System capture"), capture],
                    [localized("PF 防护", "PF protection"), firewall],
                    [localized("开机自启", "Start at boot"), boot]]
        if let system {
            rows.append([localized("部署状态", "Deployment"), protectionPhaseText(system.phase)])
            if let node = system.selectedNode { rows.append([localized("系统节点", "System node"), terminalText(node)]) }
            if let automatic = system.automaticSelection { rows.append(selectionField(automatic)) }
            if let seconds = system.secondsLeft { rows.append([localized("回退倒计时", "Rollback in"), localized("约 \(seconds) 秒", "About \(seconds) seconds")]) }
            if let error = system.lastError { rows.append([localized("诊断", "Diagnostics"), terminalText(error)]) }
        }
        if system?.engineRunning != true && system?.firewallLoaded != true {
            rows.append([localized("本机状态", "Local status"), localServiceText(status.service)])
            if let port = status.port, ["system", "preview"].contains(status.service) {
                rows.append([localized("回环监听", "Loopback"), "127.0.0.1:\(port)"])
            }
            if let node = status.selectedNode { rows.append([localized("当前节点", "Current node"), terminalText(node)]) }
            if let automatic = status.automaticSelection { rows.append(selectionField(automatic)) }
        }
        let title = systemControls ? localized("系统代理", "System proxy") : localized("运行状态", "Status")
        let shortcuts = systemControls ? systemActionRows :
            [["/system", localized("启停系统代理和开机自启", "Manage the system proxy and startup")]]
        var notes: [ConsoleLine] = []
        if systemControls, system?.verified != true, system?.phase != .protected {
            let guide = localized("配置好节点和规则后，运行 /system start。", "Set your nodes and rules, then run /system start.")
            notes = [ConsoleLine(""), ConsoleLine(guide, .muted)]
        }
        showResult(title, lines: notes, table: ConsoleTable(rows: rows), shortcuts: shortcuts)
    }

    private func selectionField(_ automatic: Bool) -> [String] {
        [localized("节点选择", "Selection"), automatic ? localized("主备自动", "Automatic failover") : localized("手动固定", "Pinned")]
    }

    private func showPresets() {
        let groups = profile?.routing.collections ?? RuleCollection.defaults([])
        let rows = groups.map { group in
            [group.title, group.enabled ? localized("已启用", "On") : localized("已停用", "Off"),
             group.target.displayName, String(group.domains.count + group.networks.count)]
        }
        let headings = [localized("预设", "Preset"), localized("状态", "State"), localized("出口", "Outbound"),
                        localized("匹配项", "Matches")]
        var title = localized("分流预设", "Routing presets")
        var notes: [ConsoleLine] = []
        if let system = activeSystem, let profile {
            let revision = try? profile.routing.systemPolicy.revision()
            if let live = system.routingRevision, live == revision {
                title += localized(" · 系统配置", " · System profile")
            } else if usesLivePolicy(system) {
                title += localized(" · 待同步", " · Pending")
            } else {
                title += localized(" · 本机配置", " · Local profile")
                notes = [ConsoleLine(""), ConsoleLine(pendingPolicyMessage(system, lookup: "/system apply"), .muted)]
            }
        } else if profile == nil {
            notes = [ConsoleLine(""), ConsoleLine(localized("复制分享链接后用 /nodes add。", "Copy a share link and use /nodes add."), .muted)]
        }
        let shortcuts = profile == nil ? [] : shortcutRows(for: "presets", actions: ["route", "edit"])
        showResult(title, lines: notes, table: ConsoleTable(headings, rows: rows), shortcuts: shortcuts)
    }

    private func localRuleDetails() throws -> (rules: [CustomRule], fallback: RuleTarget, hasUpstream: Bool) {
        guard FileManager.default.fileExists(atPath: paths.config.path) else { throw addNodesFirst }
        return try paths.locked {
            let local = try ManagedProfile(paths.config)
            let rules = try local.routing.ruleFiles(in: paths.state)?.list() ?? []
            return (rules, local.routing.fallback, local.upstream != nil)
        }
    }

    private func showLocalRules() throws {
        let (rules, fallback, hasUpstream) = try localRuleDetails()
        let rows = rules.map { [$0.value, $0.target.displayName] } + [[localized("其余全部", "Everything else"), fallback.displayName]]
        var notes: [ConsoleLine] = []
        if rules.isEmpty { notes.append(ConsoleLine(localized("暂无自定义规则。", "No custom rules yet."), .muted)) }
        if hasUpstream { notes.append(ConsoleLine(localized("外部出站已配置。", "An external upstream is configured."), .muted)) }
        showRules(rows, hasRules: !rules.isEmpty, notes: notes, title: localized("分流规则 · 本机配置", "Routing rules · Local profile"))
    }

    private func showSystemRules(_ output: [ConsoleLine]) -> Bool {
        // A previously installed system driver returns rule values and outbounds separated by this delimiter.
        let separator = "  →  "
        var rows: [[String]] = []
        var fallback: String?
        for line in output {
            if let split = line.text.range(of: separator) {
                let key = String(line.text[..<split.lowerBound])
                let value = String(line.text[split.upperBound...])
                if ["其余全部", "Everything else"].contains(key) {
                    fallback = value
                } else {
                    rows.append([key, legacyRuleTarget(value)?.displayName ?? value])
                }
            }
        }
        guard let fallback else { return false }
        let target = legacyRuleTarget(fallback)
        let hasRules = !rows.isEmpty
        var notes: [ConsoleLine] = []
        if !hasRules { notes.append(ConsoleLine(localized("暂无自定义规则。", "No custom rules yet."), .muted)) }
        if ruleUpstreamAvailable { notes.append(ConsoleLine(localized("外部出站已配置。", "An external upstream is configured."), .muted)) }
        let desired = profile?.routing.systemPolicy.fallback
        let pending = target != nil && desired != target ? desired : nil
        let label = pending == nil ? localized("其余全部", "Everything else") : localized("其余全部 · 当前", "Everything else · Active")
        rows.append([label, target?.displayName ?? fallback])
        if let pending, let system = activeSystem {
            rows.append([localized("其余全部 · 待应用", "Everything else · Pending"), pending.displayName])
            if !usesLivePolicy(system) {
                notes.append(ConsoleLine(pendingPolicyMessage(system, lookup: "/system apply"), .muted))
            }
        }
        showRules(rows, hasRules: hasRules, notes: notes, title: localized("分流规则 · 系统配置", "Routing rules · System profile"))
        return true
    }

    private func legacyRuleTarget(_ value: String) -> RuleTarget? {
        switch value {
        case "直连", "Direct": return .direct
        case "默认代理组", "Default proxy group": return .proxy
        case "外部代理", "External upstream": return .upstream
        default:
            guard let prefix = ["节点 · ", "Node · "].first(where: value.hasPrefix) else { return nil }
            return RuleTarget(rawValue: "node:" + value.dropFirst(prefix.count))
        }
    }

    private func showRules(_ rows: [[String]], hasRules: Bool, notes: [ConsoleLine], title: String) {
        let headings = [localized("匹配条件", "Match"), localized("出口", "Outbound")]
        let actions = hasRules ? ["add", "remove", "default"] : ["add", "default"]
        showResult(title, lines: notes.isEmpty ? [] : [ConsoleLine("")] + notes,
                   table: ConsoleTable(headings, rows: rows), shortcuts: shortcutRows(for: "rules", actions: actions))
    }

    private func finishCommand() -> Bool {
        guard let child else { return false }
        let streamed = child.drain()
        guard !child.process.isRunning else { return streamed }
        child.drain()
        let failed = child.process.terminationStatus != 0
        append(renderOutput(child.data, ink: failed ? .warning : .normal))
        if cancelling { resultTitle = localized("已停止  ", "Stopped  ") + runningLabel }
        else if child.truncated { append([ConsoleLine(localized("输出已截断", "Output truncated"), .muted)]) }
        else if child.data.isEmpty {
            let code = child.process.terminationStatus
            let outcome = failed ? localized("命令失败（\(code)）", "Failed with code \(code)") : localized("已完成", "Done")
            append([ConsoleLine(outcome, failed ? .warning : .muted)])
        }
        self.child = nil
        runningLabel = ""
        refreshStatus()
        if !failed && !cancelling { child.onSuccess?(self) }
        return true
    }

    private func renderOutput(_ bytes: Data, ink: Ink = .normal) -> [ConsoleLine] {
        let lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.dropLast(lines.last?.isEmpty == true ? 1 : 0).suffix(600).map { line in
            let plain = line.replacingOccurrences(of: "\u{1b}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            let text = terminalText(plain.replacingOccurrences(of: "\t", with: "    "))
            let isProbe = text.hasPrefix("  ✓ ") || text.hasPrefix("  × ")
            return ConsoleLine(isProbe ? String(text.dropFirst(2)) : text, ink)
        }
    }

    private func append(_ lines: [ConsoleLine]) {
        result += lines
    }

    private func refreshStatus() {
        status = currentStatus(paths)
        profile = try? ManagedProfile(paths.config)
    }

    private var overviewTitle: String {
        profile != nil || activeSystem != nil
            ? localized("代理概览", "Proxy overview")
            : localized("导入节点，开始使用", "Import nodes to get started")
    }

    private var overviewFields: [(String, String)] {
        guard profile != nil || activeSystem != nil else { return [] }
        let nodes = activeSystem?.nodes ?? profile?.nodes ?? []
        let selected = displayedSelectedNode
        let first = (activeSystem?.order ?? profile?.order)?.first
        let label = selected == nil ? localized("首选节点", "First in order") : localized("当前节点", "Current node")
        return [(label, terminalText(selected ?? first ?? "—")), (localized("节点数", "Nodes"), String(nodes.count))]
    }

    private var overviewShortcuts: [(String, String)] {
        let actions = profile != nil || activeSystem != nil
            ? [("/nodes", localized("查看节点", "List nodes")), ("/presets", localized("分流预设", "Routing presets"))]
            : [("/nodes add", localized("添加分享链接", "Add share links")), ("/setup", localized("导入 sing-box 文件", "Import sing-box file"))]
        return actions + [("/lang", InterfaceLanguage.names)]
    }

    private func statusBadge(width: Int) -> String {
        let indicator = status.protectedSystem?.engineRunning == true ? "● " : "○ "
        let state = indicator + systemCaptureText(status.protectedSystem)
        let firewall = status.protectedSystem?.firewallLoaded == true ? localized("PF 已启用", "PF on") : localized("PF 未启用", "PF off")
        let full = state + "  ·  " + firewall
        return cellCount(full) <= width ? full : state
    }

    private func renderOverview(_ canvas: inout ConsoleCanvas, row: Int, through end: Int, lift: Int) {
        let fields = overviewFields
        let shortcuts = overviewShortcuts
        let sideBySide = canvas.width >= 72 && !fields.isEmpty
        let height = sideBySide || fields.isEmpty ? 7 : 9
        let inset = canvas.contentInset
        let column = canvas.left + inset
        let width = canvas.width - 2 * inset
        guard canvas.width >= 36, end >= height + 1 else {
            let top = max(1, row - lift)
            if end >= top { canvas.contentHeading(overviewTitle, at: top, inset: inset) }
            if end >= top + 2 {
                let (command, detail) = shortcuts[0]
                canvas.pair(command, detail: detail, at: top + 2, column: column,
                            width: width, labelWidth: cellCount(command))
            }
            return
        }

        let top = max(1, min(row, end - height + 1) - lift)
        canvas.panel(top: top, bottom: top + height - 1)
        canvas.contentHeading(overviewTitle, at: top, inset: inset, framed: true)

        let fieldWidth = sideBySide ? width * 2 / 5 : width
        let fieldLabel = fields.map { cellCount($0.0) }.max() ?? 0
        for (index, field) in fields.enumerated() {
            canvas.pair(field.0, detail: field.1, at: top + 2 + index, column: column, width: fieldWidth,
                        labelWidth: fieldLabel, ink: .muted, detailInk: .normal)
        }
        let split = sideBySide ? fieldWidth + 2 : 0
        let shortcutRow = top + (sideBySide || fields.isEmpty ? 2 : 5)
        let shortcutLabel = shortcuts.map { cellCount($0.0) }.max() ?? 0
        for (index, shortcut) in shortcuts.enumerated() {
            canvas.pair(shortcut.0, detail: shortcut.1, at: shortcutRow + index, column: column + split,
                        width: width - split, labelWidth: shortcutLabel)
        }
    }

    private var inputHint: String {
        switch draft.text.trimmingCharacters(in: .whitespaces) {
        case "/rules add":
            return localized("输入域名或 IP/CIDR  Enter 打开引导", "Type a domain or IP/CIDR  Enter for guided entry")
        case "/rules remove":
            return localized("Enter 选择已有规则", "Enter to choose an existing rule")
        default:
            if dismissed && historyIndex == nil && requiresCompletion {
                return localized("Enter 显示选项", "Enter for options")
            }
            return localized("Enter 执行", "Enter Run")
        }
    }

    private func render(_ size: TerminalSize, authenticating: Bool = false) {
        var canvas = ConsoleCanvas(size)
        let available = authenticating ? [] : choices
        if canvas.isCompact {
            renderCompact(&canvas, choices: available, authenticating: authenticating)
            terminal.send(canvas.frame)
            return
        }

        let roomy = size.rows >= 20
        let prompt = canvas.composerRow
        let heading = form?.title ?? resultTitle
        let headingRow = roomy ? 4 : 3
        let framedMenu = size.rows >= 16 && canvas.width >= 36
        let menuBottom = prompt - (roomy ? 3 : 2)
        let menuEdges = framedMenu ? 2 : 1
        let menuCapacity = max(0, menuBottom - headingRow - 1 - menuEdges)
        let isArgument = argumentContext != nil
        let menuRows = form == nil ? min(available.count, isArgument ? 7 : commands.count, menuCapacity) : 0
        let showMenu = menuRows > 0
        let menuTop = menuBottom - menuRows - menuEdges + 1
        let contentEnd = prompt - 2
        let lift = showMenu ? 2 : 0

        if let heading {
            renderBody(&canvas, heading: heading, row: headingRow - lift, through: contentEnd - lift,
                       formChoices: form == nil ? [] : available)
        } else {
            pageIndex = 0
            lastPage = 0
            renderOverview(&canvas, row: headingRow, through: contentEnd, lift: lift)
        }
        if showMenu {
            renderChoices(&canvas, available: available, capacity: menuRows, top: menuTop, bottom: menuBottom,
                          framed: framedMenu, isArgument: isArgument)
        }
        renderComposer(&canvas, row: prompt, showMenu: showMenu, authenticating: authenticating)
        terminal.send(canvas.frame)
    }

    private func renderCompact(_ canvas: inout ConsoleCanvas, choices: [CommandChoice], authenticating: Bool) {
        lastPage = 0
        let prompt = canvas.composerRow
        if prompt > 2 {
            let line = choices[safe: visibleChoiceIndex]?.title ?? form?.prompt ?? resultTable?.rows.first?.first ?? result.first?.text ?? resultTitle ?? overviewTitle
            canvas.draw(line, at: 2, ink: .title)
        }
        if prompt > 1 { canvas.versionBadge(at: 1) }
        canvas.draw("›", at: prompt, ink: .title)
        let column = canvas.composerColumn
        if authenticating {
            canvas.cursor(at: prompt, column: column, visible: false)
            return
        }
        let width = max(1, canvas.width - 2)
        let message = child.map { _ in localized("运行中…", "Running…") }
        let layout = inputLayout(width: width, content: cellCount(message ?? draft.text) + 1, showMenu: !choices.isEmpty)
        let (visible, cursor) = draft.viewport(layout.input)
        canvas.draw(message ?? visible, at: prompt, column: column, limit: layout.input)
        canvas.draw(layout.hint, at: prompt, column: column + layout.hintOffset, ink: .muted)
        if child == nil { canvas.cursor(at: prompt, column: column + cursor) }
    }

    private func renderBody(_ canvas: inout ConsoleCanvas, heading: String, row: Int, through end: Int,
                            formChoices: [CommandChoice]) {
        let capacity = end - row
        let framed = canvas.width >= 44 && capacity >= 10
        let inset = canvas.contentInset
        let reportWidth = form == nil && resultTable?.headings.isEmpty == true ? 62 : 96
        let width = framed ? min(canvas.width, reportWidth) : canvas.width
        let contentWidth = width - 2 * inset
        let topPadding = capacity >= 6 ? 1 : 0
        let availableRows = capacity - topPadding - (framed ? 1 : 0)

        let table = form == nil ? resultTable?.layout(width: contentWidth) : nil
        let headerLimit = availableRows >= 5 ? 2 : max(0, min(1, availableRows - 1))
        let header = (table?.header ?? []).prefix(headerLimit)
        let body: [ConsoleLine]
        if let form {
            body = [formError.map { ConsoleLine(terminalText($0), .warning) } ?? ConsoleLine(form.prompt)]
        } else {
            body = result + (child.map { renderOutput($0.data) } ?? [])
        }
        var lines = (table?.lines ?? []) + body.flatMap { line in
            wrapped(line.text, width: contentWidth).map { ConsoleLine($0, line.ink) }
        }
        if form == nil && !resultShortcuts.isEmpty {
            lines.append(ConsoleLine(""))
            let shortcuts = ConsoleTable(rows: resultShortcuts).layout(width: contentWidth).lines
            lines += shortcuts.map { ConsoleLine($0.text, .muted) }
        }

        let listGap = !formChoices.isEmpty && availableRows >= 4 ? 1 : 0
        let listCapacity = max(1, min(7, availableRows - listGap - 1))
        let list = Page(total: formChoices.count, capacity: listCapacity, index: visibleChoiceIndex / listCapacity)
        let page = Page(total: lines.count, capacity: availableRows - header.count - listGap - list.rows.count, index: pageIndex)
        pageIndex = page.index
        lastPage = page.count - 1

        let firstRow = row + 1 + topPadding
        let listRow = firstRow + header.count + page.rows.count + listGap
        let listLabel = list.count > 1 ? list.label : ""
        if framed {
            canvas.panel(top: row, bottom: listRow + list.rows.count, badge: listLabel, width: width)
        }
        let headingPage = page.count > 1 ? page.label : (framed ? "" : listLabel)
        canvas.contentHeading(heading, at: row, inset: inset, width: width, framed: framed, page: headingPage)

        let column = canvas.left + inset
        for (index, line) in header.enumerated() {
            canvas.draw(line.text, at: firstRow + index, column: column, limit: contentWidth, ink: line.ink)
        }
        for (index, line) in lines[page.rows].enumerated() {
            let bodyRow = firstRow + header.count + index
            canvas.draw(line.text, at: bodyRow, column: column, limit: contentWidth, ink: line.ink)
            canvas.draw(line.label, at: bodyRow, column: column, limit: contentWidth, ink: .muted)
        }
        renderChoiceRows(&canvas, choices: formChoices[list.rows], row: listRow, column: column,
                         width: contentWidth, isArgument: true)
    }

    private func renderChoices(_ canvas: inout ConsoleCanvas, available: [CommandChoice], capacity: Int,
                               top: Int, bottom: Int, framed: Bool, isArgument: Bool) {
        let page = Page(total: available.count, capacity: capacity, index: visibleChoiceIndex / capacity)
        var caption = localized("命令", "Commands")
        if isArgument {
            if draft.text.hasPrefix("/lang ") { caption = localized("语言", "Language") }
            else if draft.text.hasPrefix("/presets ") { caption = localized("分流预设", "Routing presets") }
            else if draft.text.hasPrefix("/use ") { caption = localized("匹配节点", "Matching nodes") }
            else if draft.text.hasPrefix("/system ") { caption = localized("系统代理", "System proxy") }
            else { caption = localized("后续选项", "Next options") }
        }
        if page.count > 1 { caption += "  " + page.label }
        let background = String(repeating: " ", count: canvas.width)
        for row in top...bottom { canvas.draw(background, at: row) }
        if framed {
            canvas.panel(top: top, bottom: bottom, caption: caption)
        } else {
            canvas.draw(caption, at: top, ink: .muted)
        }
        let inset = framed ? 2 : 0
        let column = canvas.left + inset
        let width = canvas.width - inset * 2
        renderChoiceRows(&canvas, choices: available[page.rows], row: top + 1, column: column,
                         width: width, isArgument: isArgument)
    }

    private func renderChoiceRows(_ canvas: inout ConsoleCanvas, choices: ArraySlice<CommandChoice>, row: Int,
                                  column: Int, width: Int, isArgument: Bool) {
        let longest = choices.map { cellCount($0.title) + (isArgument ? 2 : 3) }.max() ?? 0
        let labelWidth = min(max(8, longest), min(29, width * 2 / 3))
        for (index, choice) in choices.enumerated() {
            let selected = choices.startIndex + index == selection
            let marker = selected ? "› " : "  "
            let label = marker + (isArgument ? choice.title : "/" + choice.title)
            canvas.pair(label, detail: choice.detail, at: row + index, column: column, width: width,
                        labelWidth: labelWidth, ink: .normal, selected: selected)
        }
    }

    private func renderComposer(_ canvas: inout ConsoleCanvas, row: Int, showMenu: Bool, authenticating: Bool) {
        let caption = authenticating ? localized("管理员认证", "Administrator authentication") : ""
        canvas.panel(top: row - 1, bottom: row + 1, caption: caption,
                     badge: statusBadge(width: canvas.width - 8), stroke: .focus)
        canvas.draw("❯", at: row, column: canvas.left + 2, ink: .title)
        let column = canvas.composerColumn
        if authenticating {
            canvas.cursor(at: row, column: column, visible: false)
            return
        }
        let width = canvas.width - 6
        let message = child.map { _ in
            cancelling ? localized("正在停止…", "Stopping…") : localized("运行中  ", "Running  ") + runningLabel
        }
        let placeholder: String
        if let form {
            placeholder = form.accept == nil ? localized("输入关键词筛选", "Type to filter") : localized("输入…", "Type here…")
        } else {
            placeholder = localized("输入 / 查看命令", "Type / for commands")
        }
        let content = message.map(cellCount) ?? (draft.text.isEmpty ? cellCount(placeholder) + 2 : cellCount(draft.text) + 1)
        let layout = inputLayout(width: width, content: content, showMenu: showMenu)
        let (visible, cursor) = draft.viewport(layout.input)
        if let message {
            canvas.draw(message, at: row, column: column, limit: layout.input, ink: .muted)
        } else if draft.text.isEmpty {
            canvas.draw(placeholder, at: row, column: column + 2, limit: layout.input - 2, ink: .muted)
        } else {
            canvas.draw(visible, at: row, column: column, limit: layout.input)
        }
        canvas.draw(layout.hint, at: row, column: column + layout.hintOffset, ink: .muted)
        if child == nil { canvas.cursor(at: row, column: column + cursor) }
    }

    private func inputLayout(width: Int, content: Int, showMenu: Bool) -> (input: Int, hint: String, hintOffset: Int) {
        let gap = 5
        let minimumInput = draft.text.isEmpty ? 8 : max(8, min(width / 2, content))
        let room = width - gap - minimumInput
        let full = consoleHint(showMenu: showMenu)
        let hint = cellCount(full) <= room ? full : consoleHint(showMenu: showMenu, compact: true)
        let hintWidth = cellCount(hint)
        guard hintWidth > 0, hintWidth <= room else { return (width, "", width) }
        let input = min(width - hintWidth - gap, max(minimumInput, content))
        return (input, hint, input + gap)
    }

    private func consoleHint(showMenu: Bool, compact: Bool = false) -> String {
        let turnPage = lastPage > 0 ? localized("   ← → 翻页", "   ← → Page") : ""
        if child != nil {
            return compact ? "Ctrl-C" + (lastPage > 0 ? "  ← →" : "") : localized("Ctrl-C 停止", "Ctrl-C Stop") + turnPage
        }
        let hasChoices = form == nil ? showMenu : !matchingFormChoices.isEmpty
        let escape = escapeHint(for: escapeStep(hasChoices: hasChoices))
        if let form {
            if compact { return "Enter  Esc" + (lastPage > 0 ? "  ← →" : "") }
            let keys: String
            if form.accept != nil {
                keys = localized("Enter 确认", "Enter Confirm")
            } else if hasChoices {
                keys = selection == nil
                    ? localized("Enter 或 ↑↓ 选择", "Enter or ↑↓ to select")
                    : localized("↑↓ 选择  Enter 确认", "↑↓ Select  Enter Confirm")
            } else {
                keys = ""
            }
            return (keys.isEmpty ? escape : keys + "  " + escape) + turnPage
        }
        if showMenu {
            if selection == nil {
                if requiresCompletion || draft.text == "/" {
                    return compact ? "Enter/↑↓  Esc"
                        : localized("Enter 或 ↑↓ 选择", "Enter or ↑↓ to select") + "  " + escape
                }
                return compact ? localized("Enter 执行  Esc", "Enter Run  Esc")
                    : localized("Enter 执行  ↑↓ 选择", "Enter Run  ↑↓ Select") + "  " + escape
            }
            return compact ? localized("Tab/Enter  Esc 取消", "Tab/Enter  Esc")
                : localized("↑↓ 选择  Tab/Enter 补全", "↑↓  Tab/Enter Complete") + "  " + escape
        }
        if !draft.text.isEmpty { return compact ? "Enter  Esc" : inputHint + "  " + escape }
        if resultTitle != nil { return compact ? "Esc" + (lastPage > 0 ? "  ← →" : "") : localized("Esc 返回", "Esc Back") + turnPage }
        return ""
    }

    private func escapeHint(for step: EscapeStep) -> String {
        switch step {
        case .deselect: return localized("Esc 取消选中", "Esc Deselect")
        case .dismissCompletions: return localized("Esc 收起", "Esc Close suggestions")
        case .backFromInput:
            if form == nil && !precedingCommandInput.isEmpty {
                return localized("Esc 上一级", "Esc Previous input")
            }
            return localized("Esc 清空", "Esc Clear")
        case .backFromForm, .backFromResult:
            return localized("Esc 返回", "Esc Back")
        }
    }

}

private extension TerminalConsole {
    var addNodesFirst: UserError {
        UserError(localized("先用 /nodes add 添加分享链接，或用 /setup import 导入节点文件。",
                            "Add a share link with /nodes add or import a node file with /setup import."))
    }

    func beginForm(_ arguments: [String]) throws -> Bool {
        switch arguments {
        case ["nodes", "group"]:
            guard FileManager.default.fileExists(atPath: paths.config.path) else { throw addNodesFirst }
            let local = try ManagedProfile(paths.config)
            editDefaultGroup(local, order: local.order)
        case ["check", "node"]: try checkNodeForm()
        case ["presets", "edit"]: try editPresets()
        case ["rules", "add"]: try addRuleForm()
        case ["rules", "remove"]: try removeRuleForm()
        case ["setup", "upstream"], ["rules", "upstream"]: try editUpstream()
        case ["rules", "default", "upstream"] where profile?.upstream == nil: try upstreamForm(useForUnmatched: true)
        case ["system", "start"]:
            let installed = ProtectedService.installedStatus()
            guard installed != nil || FileManager.default.fileExists(atPath: paths.config.path) else { throw addNodesFirst }
            guard installed == nil || installed?.phase == .prepared, try TunnelCheck.competingVPNActive() else { return false }
            let invocation = ["--state-dir", paths.state.path, "system", "_check-start"]
            child = try ConsoleProcess(executable, invocation) { console in
                console.present(ConsoleForm(title: localized("启动系统代理", "Start the system proxy"),
                    prompt: localized("手动暂停当前 VPN 后，按 Enter 继续。Proxyctl 会检查切换后的网络。",
                                      "Pause the current VPN, then press Enter to continue. Proxyctl will check the new network path."),
                    accept: { console, _ in
                        guard try !TunnelCheck.competingVPNActive() else {
                            throw UserError(localized("当前 VPN 仍在运行。", "The current VPN is still running."))
                        }
                        console.dispatch(arguments)
                    }))
            }
            draft.replace("")
            edited()
            cancelling = false
            runningLabel = "/system start"
            showResult("›  " + runningLabel,
                       lines: [ConsoleLine(localized("正在通过当前网络检查出站。", "Checking outbounds on the current network."), .muted)])
        default:
            if arguments.count == 3 && arguments.starts(with: ["presets", "route"]) {
                try changePresetOutbound(arguments[2])
            } else {
                return try setupForm(arguments)
            }
        }
        return true
    }

    func checkNodeForm() throws {
        guard let profile else { throw addNodesFirst }
        let choices = profile.nodes.map { node in
            let endpoint = node.endpoint == "域名" ? localized("域名", "Hostname") : node.endpoint
            return FormChoice(title: terminalText(node.name), detail: "\(node.protocolName) / \(endpoint)") { console in
                console.dispatch(["check", "node", node.name])
            }
        }
        present(ConsoleForm(title: localized("检测本机节点", "Check a local node"),
                            prompt: localized("选择节点进行隔离检测。", "Choose a node to test in isolation."), choices: choices))
    }

    func editDefaultGroup(_ local: ManagedProfile, order: [String], replacing: Bool = false) {
        let title = localized("默认代理组 · 本机配置", "Default proxy group · Local profile")
        var choices: [FormChoice] = []
        if order != local.order {
            choices.append(FormChoice(title: localized("保存更改", "Save changes")) { console in
                let saved = try saveDefaultGroup(order, paths: console.paths, expected: local)
                console.backFromForm()
                console.refreshStatus()
                var lines = [ConsoleLine(saved.map(terminalText).joined(separator: " → "))]
                if console.status.protectedSystem != nil {
                    lines.append(ConsoleLine(localized("下次准备系统配置时应用此代理组。",
                                                       "The next system profile preparation applies this group."), .muted))
                }
                console.showResult(localized("默认代理组已保存", "Default proxy group saved"), lines: lines)
            })
        }
        choices += order.enumerated().map { index, name in
            FormChoice(title: terminalText(name), detail: localized("顺位 \(index + 1)", "Priority \(index + 1)")) { console in
                try console.editGroupMember(local, order: order, index: index)
            }
        }
        let members = Set(order)
        choices += local.nodes.filter { !members.contains($0.name) }.map { node in
            FormChoice(title: terminalText(node.name), detail: localized("加入组", "Add to group")) { console in
                console.editDefaultGroup(local, order: order + [node.name], replacing: true)
            }
        }
        let prompt = localized("选择节点调整顺位、加入或移出组。",
                               "Choose a node to move, add, or remove.")
        present(ConsoleForm(title: title, prompt: prompt, choices: choices), replacing: replacing)
    }

    func editGroupMember(_ local: ManagedProfile, order: [String], index: Int) throws {
        guard order.count > 1 else {
            throw UserError(localized("默认代理组至少保留一个节点。", "The default proxy group needs at least one node."))
        }
        let update = { (console: TerminalConsole, next: [String]) in
            console.backFromForm()
            console.editDefaultGroup(local, order: next, replacing: true)
        }
        let moves = [(-1, localized("上移", "Move up")), (1, localized("下移", "Move down"))]
        var choices = moves.compactMap { offset, title -> FormChoice? in
            let destination = index + offset
            guard order.indices.contains(destination) else { return nil }
            return FormChoice(title: title) { console in
                var next = order
                next.swapAt(index, destination)
                update(console, next)
            }
        }
        choices.append(FormChoice(title: localized("移出组", "Remove from group")) { console in
            var next = order
            next.remove(at: index)
            update(console, next)
        })
        let prompt = localized("选择要对组内节点执行的操作。", "Choose how to update this member.")
        present(ConsoleForm(title: terminalText(order[index]), prompt: prompt, choices: choices))
    }

    func chooseOutbound(_ title: String, targets: [RuleTarget], current: RuleTarget? = nil,
                        choose: @escaping (TerminalConsole, RuleTarget) throws -> Void) {
        let choices = targets.map { target in
            FormChoice(title: target.displayName,
                       detail: target == current ? localized("当前", "Current") : "") { console in
                try choose(console, target)
            }
        }
        present(ConsoleForm(title: title, prompt: localized("选择出站。", "Choose an outbound."), choices: choices))
    }

    func editPresets() throws {
        guard let profile else { throw addNodesFirst }
        var choices = profile.routing.collections.map { group in
            FormChoice(title: group.title, detail: group.target.displayName, searchNames: group.searchNames) { console in
                console.editPreset(group)
            }
        }
        choices.append(FormChoice(title: localized("新建预设", "New preset")) { console in
            console.createPreset(profile)
        })
        present(ConsoleForm(title: localized("编辑预设", "Edit presets"),
                            prompt: localized("选择已有预设或新建。", "Choose an existing preset or create one."), choices: choices))
    }

    func editPreset(_ group: RuleCollection) {
        var actions = [
            FormChoice(title: localized("添加成员", "Add member")) { console in
                console.present(ConsoleForm(title: localized("添加预设成员", "Add preset member"),
                                            prompt: localized("输入域名或 IP/CIDR。", "Enter a domain or IP/CIDR."),
                                            accept: { console, value in
                    console.dispatch(["presets", "add", group.name, try console.ruleValue(value)])
                }))
            },
            FormChoice(title: localized("更改出口", "Change outbound"), detail: group.target.displayName) { console in
                try console.changePresetOutbound(group.name)
            }
        ]
        let members = group.domains + group.networks
        if !members.isEmpty {
            actions.insert(FormChoice(title: localized("移除成员", "Remove member")) { console in
                let choices = members.map { member in
                    FormChoice(title: member) { console in console.dispatch(["presets", "remove", group.name, member]) }
                }
                console.present(ConsoleForm(title: localized("移除预设成员", "Remove preset member"),
                                            prompt: localized("选择要移除的成员。", "Choose a member to remove."), choices: choices))
            }, at: 1)
        }
        if !group.builtIn {
            let delete = localized("删除预设", "Delete preset")
            actions.append(FormChoice(title: delete) { console in
                console.confirmEdit(delete, prompt: group.title, action: FormChoice(title: delete) { console in
                    console.dispatch(["presets", "delete", group.name])
                })
            })
        }
        present(ConsoleForm(title: group.title, prompt: localized("选择要修改的内容。", "Choose what to edit."), choices: actions))
    }

    func changePresetOutbound(_ name: String) throws {
        guard let profile else { throw addNodesFirst }
        let groups = profile.routing.collections
        guard let index = RuleCollection.index(matching: name, in: groups) else {
            throw UserError(localized("未找到该预设。", "Preset not found."))
        }
        let group = groups[index]
        let targets = outboundOptions(nodeNames: profile.nodes.map(\.name), hasUpstream: profile.upstream != nil,
                                      proxyOnly: group.builtIn)
        chooseOutbound(group.title, targets: targets, current: group.target) { console, target in
            console.dispatch(["presets", "route", group.name, target.rawValue])
        }
    }

    func createPreset(_ profile: ManagedProfile) {
        let title = localized("新建预设", "New preset")
        present(ConsoleForm(title: title, prompt: localized("输入预设名称。", "Enter a preset name."), accept: { console, value in
            let name = value.trimmingCharacters(in: .whitespaces)
            guard RuleCollection.validName(name),
                  !profile.routing.collections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw UserError(localized("请输入一个未使用的预设名称。", "Enter an unused preset name."))
            }
            let targets = outboundOptions(nodeNames: profile.nodes.map(\.name), hasUpstream: profile.upstream != nil)
            console.chooseOutbound(title, targets: targets) { console, target in
                let prompt = localized("输入第一个域名或 IP/CIDR。留空按 Enter 可保存空预设。",
                                       "Enter the first domain or IP/CIDR. Press Enter on a blank line to save an empty preset.")
                console.present(ConsoleForm(title: title, prompt: prompt, accept: { console, value in
                    let member = value.trimmingCharacters(in: .whitespaces)
                    let members = member.isEmpty ? [] : [try console.ruleValue(member)]
                    console.dispatch(["presets", "create", name, target.rawValue] + members)
                }))
            }
        }))
    }

    func ruleValue(_ value: String) throws -> String {
        let match = value.trimmingCharacters(in: .whitespaces)
        return try RuleMatch(match).normalize(match)
    }

    func addRuleForm() throws {
        guard profile != nil || activeSystem != nil else { throw addNodesFirst }
        let title = localized("添加规则", "Add a rule")
        present(ConsoleForm(title: title, prompt: localized("输入域名或 IP/CIDR。", "Enter a domain or IP/CIDR."), accept: { console, value in
            let match = try console.ruleValue(value)
            let names = console.activeSystem.map { $0.nodeRuleTargets ?? [] } ?? console.profile?.nodes.map(\.name) ?? []
            console.chooseOutbound(title, targets: outboundOptions(nodeNames: names, hasUpstream: console.ruleUpstreamAvailable)) { console, target in
                console.dispatch(["rules", "add", match, target.rawValue])
            }
        }))
    }

    func removeRuleForm() throws {
        refreshStatus()
        let title = localized("移除规则", "Remove rule")
        let rules: [CustomRule]
        if activeSystem != nil {
            let priorPage = (resultTitle, resultTable, resultShortcuts, result, pageIndex)
            defer { (resultTitle, resultTable, resultShortcuts, result, pageIndex) = priorPage }
            draft.replace("")
            edited()
            showResult(title)
            let response = try runWithAuthentication(["--state-dir", paths.state.path, "system", "rules", "--json"])
            guard response.status == 0 else {
                throw UserError(renderOutput(response.output).first?.text ??
                    localized("未能读取系统分流规则。", "Could not read the system routing rules."))
            }
            rules = try JSONDecoder().decode([CustomRule].self, from: response.output)
        } else {
            rules = try localRuleDetails().rules
        }
        guard !rules.isEmpty else {
            draft.replace("")
            edited()
            showResult(title, lines: [ConsoleLine(localized("暂无自定义规则。", "No custom rules yet."), .muted)])
            return
        }
        let choices = rules.map { rule in
            FormChoice(title: rule.value, detail: rule.target.displayName) { console in
                let prompt = "\(rule.value)  →  \(rule.target.displayName)"
                console.confirmEdit(title, prompt: prompt, action: FormChoice(title: title) { console in
                    console.dispatch(["rules", "remove", rule.value, rule.target.rawValue])
                })
            }
        }
        present(ConsoleForm(title: title,
                            prompt: localized("选择要移除的规则。", "Choose the rule to remove."), choices: choices))
    }

    func confirmEdit(_ title: String, prompt: String, action: FormChoice) {
        let cancel = FormChoice(title: localized("取消", "Cancel")) { $0.backFromForm() }
        present(ConsoleForm(title: title, prompt: prompt, choices: [cancel, action]))
    }

    func editUpstream() throws {
        guard let profile else { throw addNodesFirst }
        guard let upstream = profile.upstream else {
            try upstreamForm()
            return
        }
        let title = localized("外部代理地址 · 本机配置", "External proxy address · Local profile")
        let clear = localized("清除地址", "Clear address")
        let choices = [
            FormChoice(title: localized("修改地址", "Change address")) { try $0.upstreamForm() },
            FormChoice(title: clear) { console in
                console.confirmEdit(clear, prompt: upstream.addressLabel, action: FormChoice(title: clear) { console in
                    console.dispatch(["setup", "upstream", "off"])
                })
            }
        ]
        present(ConsoleForm(title: title, prompt: upstream.addressLabel, choices: choices))
    }

    func upstreamForm(useForUnmatched: Bool = false) throws {
        guard profile != nil else { throw addNodesFirst }
        let title = useForUnmatched ? localized("其余全部 · 外部代理", "Everything else · External proxy")
            : localized("外部代理地址 · 本机配置", "External proxy address · Local profile")
        var prompt = localized("输入独立代理的地址，例如 socks5://host:1080。",
                               "Enter an independent proxy URL, such as socks5://host:1080.")
        if useForUnmatched {
            prompt += activeSystem != nil
                ? localized(" 重新部署系统配置后使用此地址。", " Deploy the system profile again to use this address.")
                : localized(" 保存后将其用于未匹配的流量。", " Saving uses it for unmatched traffic.")
        }
        present(ConsoleForm(title: title, prompt: prompt, accept: { console, value in
            let url = value.trimmingCharacters(in: .whitespaces)
            _ = try Upstream(url: url)
            let arguments = useForUnmatched ? ["rules", "default", "upstream", url] : ["setup", "upstream", url]
            console.dispatch(arguments)
        }))
    }

    func setupForm(_ arguments: [String]) throws -> Bool {
        guard arguments.first == "setup", arguments[safe: 1] != "upstream" else { return false }
        let sourceIndex = arguments[safe: 1] == "import" ? 2 : 1
        if arguments.count == sourceIndex {
            present(ConsoleForm(title: localized("导入节点", "Import nodes"),
                                prompt: localized("拖入 sing-box JSON 文件或输入路径。", "Drop a sing-box JSON file or type its path."),
                                accept: { console, value in
                if value.trimmingCharacters(in: .whitespaces).isEmpty { console.backFromForm(); return }
                let command = arguments + [try setupFilePath(value)]
                if try !console.setupForm(command) { console.dispatch(command) }
            }))
            return true
        }
        let hasOrder = arguments.dropFirst(sourceIndex + 1).enumerated().contains {
            $0.offset.isMultiple(of: 2) && ["--node", "--group"].contains($0.element)
        }
        guard !hasOrder else { return false }
        let source = try setupProfile(arguments[sourceIndex])
        guard source.nodes.count > 1 else { return false }
        setupNodeChoices(arguments, source: source, selected: [])
        return true
    }

    func setupNodeChoices(_ arguments: [String], source: Profile, selected: [String], replacing: Bool = false) {
        let names = selected.isEmpty ? source.nodes.map(\.name) : selected
        let apply = names.flatMap { ["--node", $0] }
        var choices = [FormChoice(title: selected.isEmpty ? localized("导入全部", "Import all") : localized("导入所选", "Import selected")) { console in
            console.dispatch(arguments + apply)
        }]
        if selected.isEmpty {
            choices += source.groups.map { group in
                FormChoice(title: terminalText(group), detail: localized("文件中的代理组", "Proxy group from file")) { console in
                    console.dispatch(arguments + ["--group", group])
                }
            }
        }
        let taken = Set(selected)
        choices += source.nodes.filter { !taken.contains($0.name) }.map { node in
            FormChoice(title: terminalText(node.name), detail: node.protocolName) { console in
                console.setupNodeChoices(arguments, source: source, selected: selected + [node.name], replacing: true)
            }
        }
        let prompt = selected.isEmpty
            ? localized("按优先顺序选择节点，或直接导入已有代理组。", "Pick nodes in priority order or import an existing proxy group.")
            : localized("所选顺序  ", "Selected order  ") + selected.map(terminalText).joined(separator: " → ")
        present(ConsoleForm(title: localized("导入节点", "Import nodes"), prompt: prompt, choices: choices), replacing: replacing)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

func console(_ paths: Paths) {
    let terminal = Terminal()
    guard ProcessInfo.processInfo.environment["TERM"] != "dumb",
          let executable = Bundle.main.executableURL, terminal.enter() else {
        lineConsole(paths)
        return
    }
    defer { terminal.leave() }
    TerminalConsole(paths, executable: executable, terminal: terminal).start()
}
