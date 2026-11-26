"""Exercise the real packaged core against disposable loopback-only SOCKS nodes."""

import base64
import errno
import fcntl
import http.client
import http.server
import json
import os
import pathlib
import pty
import re
import select
import shlex
import socket
import socketserver
import stat
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unicodedata


class Node(socketserver.StreamRequestHandler):
    def handle(self):
        version, size = self.rfile.read(2)
        assert version == 5
        self.rfile.read(size)
        self.wfile.write(b"\x05\x00")
        version, command, reserved, family = self.rfile.read(4)
        assert (version, command, reserved) == (5, 1, 0)
        width = self.rfile.read(1)[0] if family == 3 else {1: 4, 4: 16}[family]
        self.rfile.read(width + 2)
        result = b"\x00" if self.server.available else b"\x04"
        self.wfile.write(b"\x05" + result + b"\x00\x01\x7f\x00\x00\x01\x00\x01")
        if not self.server.available:
            return
        while True:
            request = self.rfile.readline(8192)
            if not request:
                return
            while self.rfile.readline(8192) not in (b"\r\n", b""):
                pass
            time.sleep(0.025)
            self.server.received += 1
            if b"/health" in request:
                status = b"204 No Content" if self.server.healthy else b"503 Service Unavailable"
                self.wfile.write(b"HTTP/1.1 " + status + b"\r\nConnection: close\r\n\r\n")
                return
            body = self.server.identity.encode()
            persistent = b"/persistent" in request
            connection = "keep-alive" if persistent else "close"
            headers = f"HTTP/1.1 200 OK\r\nContent-Length: {len(body)}\r\nConnection: {connection}\r\n\r\n"
            self.wfile.write(headers.encode() + body)
            if not persistent:
                return


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True

    def __init__(self, name):
        super().__init__(("127.0.0.1", 0), Node)
        self.name = name
        self.identity = "served by " + name
        self.available = True
        self.healthy = True
        self.received = 0
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.shutdown()
        self.server_close()

    def outbound(self):
        return {"tag": self.name, "type": "socks", "server": "127.0.0.1", "server_port": self.server_address[1]}


class ConnectFixture(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_CONNECT(self):
        self.send_response(200)
        self.end_headers()
        if not self.rfile.readline(8192):
            return
        while self.rfile.readline(8192) not in (b"\r\n", b""):
            pass
        body = b"served by HTTP CONNECT"
        headers = f"HTTP/1.1 200 OK\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n"
        self.wfile.write(headers.encode() + body)
        self.close_connection = True

    def log_message(self, *_):
        pass


class DirectFixture(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        body = b"served directly"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def unused_ports():
    with socket.socket() as proxy, socket.socket() as controller:
        proxy.bind(("127.0.0.1", 0))
        controller.bind(("127.0.0.1", 0))
        return proxy.getsockname()[1], controller.getsockname()[1]


def stop(process):
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
    process.stdout.close()


def wait_for(condition, limit=12):
    end = time.monotonic() + limit
    while time.monotonic() < end:
        if condition():
            return
        time.sleep(.1)
    assert condition(), "Condition did not become true"


def failover_preview(fixture, state, bundle):
    return subprocess.Popen([str(fixture), str(state), str(bundle / "libexec/sing-box")],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def verify_outer_proxy(inner_port, outer):
    # Emulate a front-end proxy connecting to its remote SOCKS endpoint through Proxyctl.
    # Only that endpoint is visible to the managed route. The inner host is sent afterward.
    address = f"127.0.0.1:{outer.server_address[1]}"
    host = b"api.anthropic.com"
    before = outer.received
    with socket.create_connection(("127.0.0.1", inner_port), timeout=4) as connection, connection.makefile("rwb") as wire:
        def send(packet):
            wire.write(packet)
            wire.flush()

        send(f"CONNECT {address} HTTP/1.1\r\nHost: {address}\r\n\r\n".encode())
        assert b" 200 " in wire.readline()
        while wire.readline() not in (b"\r\n", b""):
            pass
        send(b"\x05\x01\x00")
        assert wire.read(2) == b"\x05\x00"
        send(b"\x05\x01\x00\x03" + bytes([len(host)]) + host + b"\x00\x50")
        assert wire.read(10).startswith(b"\x05\x00")
        send(b"GET /payload HTTP/1.1\r\nHost: " + host + b"\r\nConnection: close\r\n\r\n")
        response = wire.read()
    assert response.endswith(outer.identity.encode()) and outer.received == before + 1


def verify_terminal_handoff(bundle, scratch, product):
    helper = scratch / "terminal-handoff"
    subprocess.run([
        "/usr/bin/xcrun", "swiftc", "-module-cache-path", str(bundle.parent / "module-cache"),
        str(product / "Sources/CLI/Terminal.swift"), str(product / "Sources/Host/Command.swift"),
        str(product / "Tests/TerminalHandoff.swift"),
        str(bundle.parent / "terminal_support.o"), "-o", str(helper),
    ], check=True, timeout=45)
    def controlling_terminal():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY)

    for command, terminal, prompt, response in (
        ([str(helper)], "xterm-256color", b"Native input ready", b"test-value\r"),
        ([str(bundle / "bin/proxyctl"), "--state-dir", str(scratch / "basic-console")], "dumb", b"/lang  /help  /quit",
         b"/help\r/system start\r/system prepare\r/quit\r"),
    ):
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, env={**os.environ, "TERM": terminal},
                                   preexec_fn=controlling_terminal if terminal != "dumb" else None)
        output = bytearray()
        try:
            deadline = time.monotonic() + 8
            while prompt not in output and time.monotonic() < deadline:
                if select.select([master], [], [], .08)[0]:
                    output.extend(os.read(master, 16384))
            assert prompt in output and b"\x1b[?1049l" not in output, output
            os.write(master, response)
            deadline = time.monotonic() + 8
            while process.poll() is None and time.monotonic() < deadline:
                if select.select([master], [], [], .08)[0]:
                    output.extend(os.read(master, 16384))
            assert process.poll() == 0, output
            while select.select([master], [], [], .04)[0]:
                try:
                    remaining = os.read(master, 16384)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not remaining:
                    break
                output.extend(remaining)
            if terminal != "dumb":
                assert b"test-value" not in output
                assert output.count(b"\x1b[?1049h") == output.count(b"\x1b[?1049l") == 1
                assert output.index(b"Raw input restored") < output.index(b"\x1b[?1049l")
            else:
                assert b"/rules default" in output and b"/rules upstream" in output and b"proxyctl help" in output
                assert all(b"/system " + action in output for action in (b"start", b"stop", b"enable", b"disable", b"rollback"))
                assert b"/nodes import" in output.rsplit(b"/system prepare", 1)[-1]
                assert b"/help system" not in output
                mask = termios.ECHO | termios.ICANON | termios.ISIG
                assert termios.tcgetattr(slave)[3] & mask == original[3] & mask
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            os.close(master)
            os.close(slave)


def tty_smoke(command, port, fetch, health, source, preview):
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)

    def resize(columns, rows):
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

    resize(120, 30)
    terminal_env = dict(os.environ, TERM="xterm-256color")
    terminal_env.pop("NO_COLOR", None)
    terminal_env.pop("PROXYCTL_LANGUAGE", None)
    process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave,
                               env=terminal_env)
    result = bytearray()

    def expect(fragment, *, after=0):
        fragment = fragment.encode() if isinstance(fragment, str) else fragment
        deadline = time.monotonic() + 9
        while fragment not in result[after:] and time.monotonic() < deadline:
            if select.select([master], [], [], 0.08)[0]:
                result.extend(os.read(master, 16_384))
            elif process.poll() is not None:
                break
        assert fragment in result[after:], (fragment, result[after:][-5000:].decode(errors="replace"))

    def type_keys(keys, expected, *, wait_for_input=False):
        offset = len(result)
        os.write(master, keys)
        expect(expected, after=offset)
        if wait_for_input:
            marker = expected.encode() if isinstance(expected, str) else expected
            expect(b"\x1b[?25h", after=result.index(marker, offset) + len(marker))

    def complete_form(keys, expected):
        type_keys(keys, expected)
        expect("Type / for commands", after=result.rfind(expected.encode()))

    def assert_reselection(highlight):
        marker = highlight.encode()
        original = result.rsplit(b"\x1b[2J", 1)[-1]
        assert marker in original
        type_keys(b"\x1b", "Enter or ↑↓ to select  Esc Close suggestions", wait_for_input=True)
        assert marker not in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\r", marker, wait_for_input=True)
        assert result.rsplit(b"\x1b[2J", 1)[-1] == original

    def assert_shortcuts(frame, *commands):
        rows = []
        offsets = set()
        for name in commands:
            item = re.search(rb"\x1b\[(\d+);8H\x1b\[38;2;151;146;141m" + re.escape(name) + rb"( +)\S", frame)
            assert item, name
            rows.append(int(item[1]))
            offsets.add(len(name) + len(item[2]))
        assert rows == list(range(rows[0], rows[0] + len(commands))) and len(offsets) == 1

    try:
        expect(b"\x1b[?1049h")
        expect(b"48;2;0;0;0m\x1b[2J")
        version_label = b"proxyctl  " + subprocess.check_output(command + ["--version"], timeout=6).strip()
        version_badge = b" " + version_label + b" "
        version_column = 115 - len(version_badge)
        home_version = f"\x1b[4;{version_column}H".encode() + b"\x1b[38;2;151;146;141m" + version_badge
        expect(home_version)
        expect(b"\x1b[?1006h")
        expect("❯")
        expect("代理概览")
        expect("首选节点")
        expect(b"\x1b[4;5H")
        expect("全机接管未启用  ·  PF 未启用")
        expect(b"\x1b[26;9H\x1b[?25h")
        start = result.index(b"\x1b[2J")
        home = bytes(result[start:result.index(b"\x1b[25;5H", start)])
        assert home.count(version_label) == 1
        assert b"\x1b[4;7H\x1b[1;38;2;243;240;236m " + "代理概览".encode() in home
        composer_start = result.index(b"\x1b[25;5H", start)
        cursor_on = result.index(b"\x1b[26;9H\x1b[?25h", composer_start)
        assert version_label not in result[composer_start:cursor_on]
        offset = len(result)
        type_keys(b"/", "Esc 取消选中", wait_for_input=True)
        menu_frame = result[offset:].rsplit(b"\x1b[2J", 1)[-1]
        hint = re.search(rb"\x1b\[26;(\d+)H\x1b\[38;2;151;146;141m" + "↑↓ 选择  Tab/Enter 补全".encode(), menu_frame)
        cursor = re.search(rb"\x1b\[26;(\d+)H\x1b\[\?25h", menu_frame)
        assert hint and cursor and 5 <= int(hint[1]) - int(cursor[1]) <= 14
        assert b"\x1b[2;5H\x1b[38;2;73;68;64m" + "╭".encode() in menu_frame
        assert b"\x1b[8;5H\x1b[38;2;73;68;64m" + "╰".encode() in menu_frame
        assert re.search(rb"\x1b\[(9|10);\d+H", menu_frame) is None
        menu_version = f"\x1b[2;{version_column}H".encode() + b"\x1b[38;2;151;146;141m" + version_badge
        assert menu_version in menu_frame and menu_frame.count(version_label) == 1
        assert b"\x1b[12;5H\x1b[38;2;73;68;64m" + "╭".encode() in menu_frame
        expect("› /status", after=offset)
        for name in (b"/nodes", b"/groups", b"/check", b"/rules", b"/presets", b"/system", b"/lang", b"/help", b"/quit"):
            expect(b"H  " + name, after=offset)
        expect("增删规则，设置其余流量和外部代理", after=offset)
        expect("查看代理组及其主备顺位", after=offset)
        expect("检查当前代理路径，也可单独检测指定节点", after=offset)
        for command_name in (b"/use", b"/setup", b"/rules default", b"/service", b"/preview", b"/firewall", b"/doctor", b"/logs"):
            assert command_name not in result[offset:]
        type_keys(b"\x1b\x1b", home, wait_for_input=True)
        type_keys(b"/", "› /status", wait_for_input=True)
        type_keys(b"\x1b[B", "› /nodes")
        offset = len(result)
        type_keys(b"\r", b"H/nodes ")
        expect("通过分享链接添加节点", after=offset)
        expect("Enter 执行", after=offset)
        assert "节点 · 本机配置".encode() not in result[offset:]
        type_keys(b"\r", "节点 · 本机配置", wait_for_input=True)
        frame = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"\x1b[4;5H\x1b[38;2;73;68;64m" + "╭".encode() in frame
        assert f"\x1b[4;{99-len(version_badge)}H".encode() + b"\x1b[38;2;151;146;141m" + version_badge in frame
        assert re.search(rb"\x1b\[4;7H\x1b\[[0-9;]+m " + "节点 · 本机配置".encode(), frame)
        assert b"\x1b[5;8H" not in frame
        assert b"\x1b[6;8H\x1b[38;2;151;146;141m" + "名称".encode() in frame
        assert b"\x1b[7;8H\x1b[38;2;73;68;64m" + "────".encode() in frame
        rows = re.findall(rb"\x1b\[\d+;8H([^\x1b]*SOCKS +IPv4 +[^\x1b]+)", frame)
        assert len(rows) == 3, rows
        protocol_offsets = {
            sum(2 if unicodedata.east_asian_width(char) in "WF" else 1 for char in row.decode().split("SOCKS", 1)[0])
            for row in rows
        }
        assert len(protocol_offsets) == 1, rows
        assert "地址类型".encode() in frame and "顺位".encode() in frame
        assert_shortcuts(frame, b"/nodes add", b"/nodes import")
        type_keys(b"/", "› /status", wait_for_input=True)
        type_keys(b"\x1b", "Esc 收起", wait_for_input=True)
        deselected_menu = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"H  /status" in deselected_menu and "› /status".encode() not in deselected_menu
        nodes_heading = b"\x1b[4;7H\x1b[1;38;2;243;240;236m " + "节点 · 本机配置".encode()
        type_keys(b"\x1b", nodes_heading, wait_for_input=True)
        assert b"H/" not in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"/help\r", b"\x1b[26;9H/help ", wait_for_input=True)
        help_draft = result.rsplit(b"\x1b[2J", 1)[-1]
        assert "后续选项".encode() not in help_draft
        type_keys(b"\r", "命令帮助", wait_for_input=True)
        help_frame = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"/check node" in help_frame and b"/rules" in help_frame
        assert re.search(rb"\x1b\[4;\d+H\x1b\[38;2;151;146;141m " +
                         "第 1/".encode() + rb"\d+" + " 页  ".encode() + version_label, help_frame)
        type_keys(b"\x1b", "代理概览")
        type_keys(b"/nodes ", "通过分享链接添加节点")
        type_keys(b"\x1b[B", "› add")
        type_keys(b"\r", b"H/nodes add ")
        type_keys(b"\x1b", "Enter 执行  Esc 清空", wait_for_input=True)
        assert b"H/nodes " in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\x1b", "输入 / 查看命令", wait_for_input=True)
        type_keys(b"/nodes add with-an-argument\r", "运行 /nodes add 打开添加页，再粘贴分享链接。")
        type_keys(b"/node add\r", b"H/nodes add", wait_for_input=True)
        assert "› add".encode() in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\r", b"H/nodes add ", wait_for_input=True)
        type_keys(b"\r", "粘贴分享链接，每行一条。", wait_for_input=True)
        type_keys(b"\x1b", "输入 / 查看命令", wait_for_input=True)
        type_keys(b"/use --auto\r", "输入 / 查看日常命令。", wait_for_input=True)
        nodes_query = command + ["nodes", "--json"]
        original_group = json.loads(subprocess.check_output(nodes_query, timeout=8))
        type_keys(b"/nodes group\r\r", "默认代理组 · 本机配置", wait_for_input=True)
        group_frame = result.rsplit(b"\x1b[2J", 1)[-1]
        assert all(label.encode() in group_frame for label in ("顺位 1", "顺位 2", "加入组"))
        assert b"\x1b[4;7H\x1b[1;38;2;243;240;236m " + "默认代理组 · 本机配置".encode() in group_frame
        assert f"\x1b[4;{99-len(version_badge)}H".encode() + b"\x1b[38;2;151;146;141m" + version_badge in group_frame
        assert b"\x1b[6;8H" + "选择节点调整顺位".encode() in group_frame
        assert group_frame.count("╭".encode()) == 2
        assert b"\x1b[11;5H\x1b[38;2;73;68;64m" + "╰".encode() in group_frame
        type_keys(b"IPv6\r", "上移", wait_for_input=True)
        type_keys(b"\x1b", "Enter 或 ↑↓ 选择  Esc 返回", wait_for_input=True)
        member_frame = result.rsplit(b"\x1b[2J", 1)[-1]
        assert "上移".encode() in member_frame and "› 上移".encode() not in member_frame
        type_keys(b"\x1b", "选择节点调整顺位", wait_for_input=True)
        assert b"\x1b[26;9HIPv6" in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\x1b", "Esc 清空", wait_for_input=True)
        type_keys(b"\x1b", "输入关键词筛选", wait_for_input=True)
        assert "顺位 1".encode() in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\r", "› 美国", wait_for_input=True)
        type_keys(b"IPv6\r", "上移", wait_for_input=True)
        type_keys(b"\r", "保存更改", wait_for_input=True)
        type_keys(b"\x1b", "Enter 或 ↑↓ 选择  Esc 返回", wait_for_input=True)
        assert "保存更改".encode() in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\x1b", "输入 / 查看命令", wait_for_input=True)
        assert json.loads(subprocess.check_output(nodes_query, timeout=8)) == original_group
        type_keys(b"\x1b", "代理概览", wait_for_input=True)
        running_preview = preview("美国")
        try:
            group_edit = subprocess.run(command + ["groups", "default", "美国 IPv6"], capture_output=True, timeout=8)
            assert group_edit.returncode != 0 and "结束本机回环诊断后再保存代理组".encode() in group_edit.stderr
        finally:
            stop(running_preview)
        type_keys(b"/presets \x1b[B", "› enable")
        type_keys(b"\x1b", "Enter 执行  ↑↓ 选择  Esc 收起", wait_for_input=True)
        frame = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"H/presets " in frame and "› enable".encode() not in frame
        type_keys(b"\r", "Claude   已启用")
        assert "分流预设".encode() in result
        while select.select([master], [], [], 0.04)[0]:
            result.extend(os.read(master, 16_384))
        os.write(master, b"\x1b[5~\x1b[6~\x1b[<64;12;5M\x1b[Mabc")
        assert not select.select([master], [], [], 0.3)[0], "Scrolling changed the fixed page"
        type_keys(b"\x1b", "代理概览")
        type_keys(b"/presets \x1b[B", "› enable")
        type_keys(b"\x1b", "Enter 执行  ↑↓ 选择  Esc 收起", wait_for_input=True)
        type_keys(b"\x1b", "Enter 执行  Esc 清空", wait_for_input=True)
        assert b"H/presets " in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\t", "› enable", wait_for_input=True)
        type_keys(b"\x1b\x1b\x1b", "输入 / 查看命令", wait_for_input=True)
        frame = result.rsplit(b"\x1b[2J", 1)[-1]
        assert "代理概览".encode() in frame and b"H/presets " not in frame
        type_keys(b"/presets ", "启用预设")
        type_keys(b"d\t", "› Claude")
        type_keys(b"open\r", b"H/presets disable openai ")
        groups = json.loads(subprocess.check_output(command + ["presets", "--json"], timeout=8))
        assert next(group for group in groups if group["name"] == "openai")["enabled"]
        type_keys(b"\r", "预设 OpenAI · 已停用", wait_for_input=True)
        type_keys(b"/presets enable open\r\r", "预设 OpenAI · 已启用", wait_for_input=True)
        type_keys(b"/presets disable open\r\r", "预设 OpenAI · 已停用", wait_for_input=True)
        type_keys(b"/presets \r", "OpenAI   已停用")
        type_keys(b"/rou", b"H/rou", wait_for_input=True)
        assert " 命令 ".encode() not in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\x03", "输入 / 查看命令", wait_for_input=True)
        type_keys(b"/presets rou", "› route", wait_for_input=True)
        type_keys(b"\t", b"H/presets route ", wait_for_input=True)
        assert "› Claude".encode() in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\x03", "输入 / 查看命令", wait_for_input=True)
        type_keys(b"/home\r", "代理概览")
        offset = len(result)
        type_keys(f"/check --url {health}\r".encode(), "隔离节点检测 · 美国", wait_for_input=True)
        assert b"/preview" not in result[offset:]

        type_keys(b"/lang\r", "› 简体中文")
        type_keys(b"\x1b[B\r", b"H/lang en ")
        type_keys(b"\r", "Proxy overview")
        type_keys(b"/presets \r", "OpenAI   Off", wait_for_input=True)
        preset_frame = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"Routing presets" in preset_frame and b"Esc Back" in preset_frame
        assert_shortcuts(preset_frame, b"/presets route", b"/presets edit")
        for query in (b"/rou", b"/route", b"/oup", b"/proxy group"):
            type_keys(query, b"H" + query, wait_for_input=True)
            assert b" Commands " not in result.rsplit(b"\x1b[2J", 1)[-1]
            type_keys(b"\x03", "Type / for commands", wait_for_input=True)
        type_keys(b"/ru ", b"H/ru ", wait_for_input=True)
        assert_reselection("› /rules")
        type_keys(b"\r", b"H/rules ", wait_for_input=True)
        assert b"Choose where unmatched traffic goes" in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\x03", "Type / for commands", wait_for_input=True)
        type_keys(b"/presets rou", b"H/presets rou", wait_for_input=True)
        assert_reselection("› route")
        type_keys(b"\r", b"H/presets route ", wait_for_input=True)
        assert "› Claude".encode() in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"open\r", b"H/presets route openai ", wait_for_input=True)
        assert "› Default proxy group".encode() in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\x03", "Type / for commands", wait_for_input=True)
        type_keys(b"/nodes \r", "Nodes · Local profile", wait_for_input=True)
        type_keys(b"/groups edit default\r\r", "Default proxy group · Local profile", wait_for_input=True)
        type_keys(b"Other\r", "Priority 3", wait_for_input=True)
        type_keys(b"IPv6\r", "Move up", wait_for_input=True)
        type_keys(b"\r", "Save changes", wait_for_input=True)
        type_keys(b"Other\r", "Remove from group", wait_for_input=True)
        type_keys(b"\x1b[B\r", "Add to group", wait_for_input=True)
        type_keys(b"\r", "Default proxy group saved", wait_for_input=True)
        group = json.loads(subprocess.check_output(nodes_query, timeout=8))
        assert group["order"] == ["美国 IPv6", "美国"] and group["nodes"] == original_group["nodes"]
        type_keys(b"/nodes group\r\r", "Default proxy group · Local profile", wait_for_input=True)
        type_keys(b"IPv6\r", "Move down", wait_for_input=True)
        type_keys(b"\r", "Save changes", wait_for_input=True)
        subprocess.run(command + ["nodes", "group", "Other Region"], check=True, capture_output=True, timeout=8)
        type_keys(b"\r", "The default proxy group changed.", wait_for_input=True)
        assert json.loads(subprocess.check_output(nodes_query, timeout=8))["order"] == ["Other Region"]
        type_keys(b"\x1b\x1b", "Type / for commands", wait_for_input=True)
        subprocess.run(command + ["nodes", "group", *original_group["order"]], check=True, capture_output=True, timeout=8)
        type_keys(b"/groups \r", "Proxy groups · Local profile", wait_for_input=True)
        assert_shortcuts(result.rsplit(b"\x1b[2J", 1)[-1], b"/groups edit")
        type_keys(b"/groups edit ", "New proxy group", wait_for_input=True)
        assert_reselection("› Default proxy group")
        type_keys(b"new\r", b"H/groups edit --new ", wait_for_input=True)
        type_keys(b"\r", "Enter a proxy group name.", wait_for_input=True)
        type_keys(b"Work Group\r", "Choose a node to move", wait_for_input=True)
        type_keys(b"Other\r", "Priority 1", wait_for_input=True)
        type_keys(b"IPv6\r", "Priority 2", wait_for_input=True)
        type_keys(b"\r", "Proxy group saved.", wait_for_input=True)
        groups_query = command + ["groups", "--json"]
        groups = json.loads(subprocess.check_output(groups_query, timeout=8))
        assert groups["groups"] == [{"name": "Work Group", "order": ["Other Region", "美国 IPv6"]}]
        type_keys(b"/presets route claude Work\r", b'H/presets route claude "group:Work Group" ', wait_for_input=True)
        type_keys(b"\r", "Claude  →  Group · Work Group", wait_for_input=True)
        type_keys(b"/presets route claude proxy\r\r", "Claude  →  Default proxy group", wait_for_input=True)
        type_keys(b"/groups edit Work\r\r", "Delete proxy group", wait_for_input=True)
        type_keys(b"Delete\r", "› Cancel", wait_for_input=True)
        type_keys(b"\x1b[B\r", "Proxy group deleted.", wait_for_input=True)
        assert not json.loads(subprocess.check_output(groups_query, timeout=8))["groups"]
        type_keys(b"/status \r", "Local profile ready", wait_for_input=True)
        status_frame = result.rsplit(b"\x1b[2J", 1)[-1]
        assert re.search(rb"\x1b\[4;7H\x1b\[[0-9;]+m Status ", status_frame)
        status_version = f"\x1b[4;{65-len(version_badge)}H".encode() + b"\x1b[38;2;151;146;141m" + version_badge
        assert status_version in status_frame and status_frame.count(version_label) == 1
        assert version_label not in status_frame[status_frame.index(b"\x1b[25;5H"):]
        assert b"\x1b[5;8H" not in status_frame
        assert b"\x1b[6;8H\x1b[38;2;151;146;141mSystem capture" in status_frame
        assert b"\x1b[7;8H\x1b[38;2;151;146;141mPF protection" in status_frame
        assert re.search(rb"Start at boot +Not configured", status_frame)
        assert b"/system  Manage the system proxy and startup" in status_frame
        type_keys(b"/", "› /status", wait_for_input=True)
        lifted_status = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"\x1b[2;7H\x1b[1;38;2;243;240;236m Status " in lifted_status
        assert status_version.replace(b"\x1b[4;", b"\x1b[2;", 1) in lifted_status
        assert b"\x1b[4;8H\x1b[38;2;151;146;141mSystem capture" in lifted_status
        type_keys(b"\x1b\x1b", status_version, wait_for_input=True)
        assert b"Local profile ready" in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\x1b", "Proxy overview", wait_for_input=True)
        type_keys(b"/rules \r", "No custom rules yet.", wait_for_input=True)
        rules_frame = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"Everything else" in rules_frame
        assert_shortcuts(rules_frame, b"/rules add", b"/rules default", b"/rules upstream")
        type_keys(b"/rules add\r", "Type a domain or IP/CIDR")
        type_keys(b"sample.test ", b"H/rules add sample.test ", wait_for_input=True)
        assert_reselection("› Direct")
        type_keys(b"p", b"H/rules add sample.test p", wait_for_input=True)
        assert_reselection("› Default proxy group")
        type_keys(b"\r", b"H/rules add sample.test proxy ")
        type_keys(b"\r", "sample.test  →  Default proxy group", wait_for_input=True)
        type_keys(b"/rules remove sample.test ", b"H/rules remove sample.test ", wait_for_input=True)
        removal_targets = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"Outbounds" in removal_targets and b"External upstream" not in removal_targets
        assert b"Node \xc2\xb7 " not in removal_targets and b" Direct " not in removal_targets
        assert_reselection("› Default proxy group")
        type_keys(b"\x03", "Type / for commands", wait_for_input=True)
        type_keys(b"/rules remove\r", b"H/rules remove ", wait_for_input=True)
        remove_frame = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"Existing rules" in remove_frame and b"Default proxy group" in remove_frame
        assert_reselection("› sample.test")
        type_keys(b"\r", b"H/rules remove sample.test proxy ", wait_for_input=True)
        assert json.loads(subprocess.check_output(command + ["rules", "--json"], timeout=8))
        type_keys(b"\r", "Removed", wait_for_input=True)
        rules_left = json.loads(subprocess.check_output(command + ["rules", "--json"], timeout=8))
        assert not rules_left
        type_keys(b"/rules add fixed.test IPv6\r\r", "fixed.test  →  Node · 美国 IPv6", wait_for_input=True)
        type_keys('/rules remove fixed.test "node:美国 IPv6"\r\r'.encode(), "Removed", wait_for_input=True)
        form_start = len(result)
        type_keys(b"/presets edit\r", b"H/presets edit ", wait_for_input=True)
        edit_choices = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"Routing presets" in edit_choices and b"New preset" in edit_choices
        assert_reselection("› Claude")
        type_keys(b"\r", b"H/presets edit claude ", wait_for_input=True)
        assert b"Choose what to edit." not in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\r", "Choose what to edit.")
        type_keys(b"\r", "Enter a domain or IP/CIDR.")
        type_keys(b"\x1b", "Choose what to edit.")
        type_keys(b"\x1b", "Enter or ↑↓ to select  Esc Back", wait_for_input=True)
        type_keys(b"\x1b", b"H/presets edit ", wait_for_input=True)
        assert b"New preset" in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"New preset\r", b"H/presets edit --new ", wait_for_input=True)
        type_keys(b"\r", "Enter a preset name.")
        type_keys(b"\x1b", b"H/presets edit ", wait_for_input=True)
        type_keys(b"New preset\r\r", "Enter a preset name.")
        type_keys(b"Fixture collection\r", "Default proxy group")
        type_keys(b"\x1b[B\r", "Enter the first domain")
        complete_form(b"wizard.test\r", "Preset saved.")
        type_keys(b"/presets \r", "Fixture collection   On")
        type_keys(b"/presets route Fixture\r", "› Direct", wait_for_input=True)
        assert b'H/presets route "Fixture collection" ' in result.rsplit(b"\x1b[2J", 1)[-1]
        assert_reselection("› Direct")
        type_keys(b"\x03", "Type / for commands", wait_for_input=True)

        type_keys(b"/presets edit Fixture\r\r", "Choose what to edit.")
        type_keys(b"Add\r", "Enter a domain or IP/CIDR.")
        complete_form(b"companion.test\r", "Preset saved.")
        type_keys(b"/presets edit Fixture\r\r", "Choose what to edit.")
        type_keys(b"Remove\r", "Choose a member to remove.")
        complete_form(b"companion\r", "Preset saved.")
        groups = json.loads(subprocess.check_output(command + ["presets", "--json"], timeout=8))
        assert next(group for group in groups if group["name"] == "Fixture collection")["domains"] == ["wizard.test"]
        type_keys(b"/presets edit Fixture\r\r", "Delete preset", wait_for_input=True)
        type_keys(b"Delete\r", "› Cancel", wait_for_input=True)
        type_keys(b"\x1b[B\r", "Preset deleted.", wait_for_input=True)
        groups = json.loads(subprocess.check_output(command + ["presets", "--json"], timeout=8))
        assert all(group["name"] != "Fixture collection" for group in groups)
        subprocess.run(command + ["presets", "create", "--new", "proxy"], check=True, capture_output=True, timeout=8)
        type_keys(b"/presets \r", "--new", wait_for_input=True)
        type_keys(b"/presets edit --new\r", b"H/presets edit --new ", wait_for_input=True)
        assert b"Esc Previous input" in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\r", "Enter a preset name.", wait_for_input=True)
        type_keys(b"\x1b", b"H/presets edit ", wait_for_input=True)
        type_keys(b"\x03", "Type / for commands", wait_for_input=True)
        type_keys(b"/presets edit -- --new\r", b"H/presets edit -- --new ", wait_for_input=True)
        type_keys(b"\r", "Choose what to edit.", wait_for_input=True)
        type_keys(b"\x1b\x1b", b"H/presets edit ", wait_for_input=True)
        type_keys(b"\x03", "Type / for commands", wait_for_input=True)
        subprocess.run(command + ["presets", "delete", "--new"], check=True, capture_output=True, timeout=8)

        type_keys(b"/rules add\r\r", "Enter a domain or IP/CIDR.")
        type_keys(b"form.test\r", b"H/rules add form.test ", wait_for_input=True)
        assert b"Outbounds" in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"IPv6\r", 'H/rules add form.test "node:美国 IPv6" ', wait_for_input=True)
        complete_form(b"\r", "form.test  →  Node · 美国 IPv6")
        complete_form('/rules remove form.test "node:美国 IPv6"\r\r'.encode(), "Removed")
        default_query = command + ["rules", "default", "--json"]
        before = json.loads(subprocess.check_output(default_query, timeout=8))
        type_keys(b"/setup ", "View or edit the external proxy address", wait_for_input=True)
        assert b"Import nodes from a sing-box JSON file" in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"upstream\r", b"\x1b[26;9H/setup upstream ")
        type_keys(b"\r", "Enter an independent proxy URL")
        complete_form(b"socks5://127.0.0.1:42179\r", "External upstream settings saved.")
        assert json.loads(subprocess.check_output(default_query, timeout=8)) == before
        address = subprocess.check_output(command + ["setup", "upstream"], text=True, timeout=8)
        assert "127.0.0.1 · 42179" in address
        type_keys(b"/setup upstream\r\r", "Change address", wait_for_input=True)
        upstream_editor = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"Clear address" in upstream_editor and b"127.0.0.1" in upstream_editor
        type_keys(b"\r", "Enter an independent proxy URL", wait_for_input=True)
        type_keys(b"socks5://127.0.0.1:42180", "Esc Clear", wait_for_input=True)
        type_keys(b"\x1b", "Enter Confirm  Esc Back", wait_for_input=True)
        assert b"Enter an independent proxy URL" in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\x1b", "Change address", wait_for_input=True)
        type_keys(b"Clear\r", "› Cancel", wait_for_input=True)
        type_keys(b"\x1b[B\r", "External upstream settings saved.", wait_for_input=True)
        address = subprocess.check_output(command + ["setup", "upstream"], text=True, env={**os.environ, "PROXYCTL_LANGUAGE": "en"}, timeout=8)
        assert "No external upstream is configured." in address

        type_keys(b"/setup import\r\r", "Drop a sing-box JSON")
        type_keys(f"'{source}'\r".encode(), "Pick nodes in priority order")
        type_keys(b"IPv6\r", "Selected order  美国 IPv6", wait_for_input=True)
        type_keys(b"\x1b", "Enter or ↑↓ to select  Esc Back", wait_for_input=True)
        type_keys(b"\x1b", "Drop a sing-box JSON", wait_for_input=True)
        assert b"Esc Clear" in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\x1b", "Enter Confirm  Esc Back", wait_for_input=True)
        type_keys(b"\x1b", "Type / for commands", wait_for_input=True)
        assert b"\x1b[?1049l" not in result[form_start:]

        type_keys("/presets route 'OpenAI 服务' ".encode(), "› Default proxy group", wait_for_input=True)
        assert b"Outbounds" in result.rsplit(b"\x1b[2J", 1)[-1]
        assert_reselection("› Default proxy group")
        type_keys(b"\x03", "Type / for commands", wait_for_input=True)
        type_keys(b"/presets route open\r", "› Default proxy group", wait_for_input=True)
        type_keys(b"\x1b[B\x1b[B", "› Node · 美国 IPv6", wait_for_input=True)
        assert_reselection("› Node · 美国 IPv6")
        type_keys(b"\x1b", "Esc Close suggestions", wait_for_input=True)
        type_keys(b"\x1b", "Enter for options  Esc Previous input", wait_for_input=True)
        type_keys(b"\r", "› Node · 美国 IPv6", wait_for_input=True)
        type_keys(b"IPv6", b"H/presets route openai IPv6", wait_for_input=True)
        assert_reselection("› Node · 美国 IPv6")
        type_keys(b"\r", 'H/presets route openai "node:美国 IPv6" ', wait_for_input=True)
        groups = json.loads(subprocess.check_output(command + ["presets", "--json"], timeout=8))
        assert next(group for group in groups if group["name"] == "openai")["target"] == "proxy"
        type_keys(b"\r", "OpenAI  →  Node · 美国 IPv6", wait_for_input=True)
        for command_input, highlight in (
            (b"/hel", "› /help"),
            (b"/presets rou", "› route"),
            (b"/setup im", "› import"),
            (b"/check node IPv6", "› 美国 IPv6"),
            (b"/lang Eng", "› English"),
            (b"/presets enable ope", "› OpenAI"),
            (b"/presets route gem", "› Gemini"),
            (b"/presets disable ope", "› OpenAI"),
            (b"/rules default IPv6", "› Node · 美国 IPv6"),
        ):
            type_keys(command_input, b"H" + command_input, wait_for_input=True)
            assert_reselection(highlight)
            type_keys(b"\x03", "Type / for commands", wait_for_input=True)
        type_keys(b"/help \r", "Command help", wait_for_input=True)
        help_pages = [bytes(result.rsplit(b"\x1b[2J", 1)[-1])]
        page_count = re.search(rb"Page 1/(\d+)", help_pages[0])
        assert page_count
        for page in range(2, int(page_count[1]) + 1):
            type_keys(b"\x1b[C", f"Page {page}/", wait_for_input=True)
            help_pages.append(bytes(result.rsplit(b"\x1b[2J", 1)[-1]))
        catalog = b"\n".join(help_pages)
        assert b"Start verifies the tunnel and firewall" in catalog
        system_actions = (b"start", b"apply", b"stop", b"enable", b"disable", b"rollback")
        assert b"/system prepare" not in catalog and b"/system trial" not in catalog
        system_rows = (b"/system ", *(b"/system " + action for action in system_actions))
        positions = [catalog.index(row) for row in system_rows]
        assert positions == sorted(set(positions))
        for group, children in (
            (b"nodes", (b"add", b"import")),
            (b"groups", (b"edit",)),
            (b"check", (b"node",)),
            (b"rules", (b"add", b"remove", b"default", b"upstream")),
            (b"presets", (b"enable", b"disable", b"route", b"edit")),
            (b"lang", (b"zh", b"en")),
        ):
            root = b"/" + group + b" "
            rows = (root, *(root + child for child in children))
            positions = [catalog.index(row) for row in rows]
            assert positions == sorted(set(positions)), group
        for leaf in (b"status", b"help", b"quit"):
            assert b"/" + leaf + b" " in catalog, leaf
        assert b"/help system" not in catalog

        completion_cases = {
            b"/status": b"Enter Run",
            b"/nodes": b"Add nodes from share links",
            b"/nodes add": b"Enter Open form",
            b"/nodes import": b"Type a file path",
            b"/groups": b"Create a group or change its members and order",
            b"/groups edit": b"New proxy group",
            b"/check": b"Check a specific node",
            b"/check node": b"Matching nodes",
            b"/rules": b"Choose where unmatched traffic goes",
            b"/rules add": b"Type a domain or IP/CIDR",
            b"/rules remove": b"No rules to remove",
            b"/rules default": b"Outbounds",
            b"/rules upstream": b"Enter Open editor",
            b"/presets": b"Enable a preset",
            b"/presets enable": "› Claude".encode(),
            b"/presets disable": "› Claude".encode(),
            b"/presets route": "› Claude".encode(),
            b"/presets edit": b"New preset",
            b"/system": b"Verify and start the system proxy",
            **{b"/system " + action: b"Enter Run" for action in system_actions},
            b"/lang": b"Language",
            b"/lang zh": b"Enter Run",
            b"/lang en": b"Enter Run",
            b"/help": b"Enter Run",
            b"/quit": b"Enter Run",
        }
        command_cell = rb"\x1b\[\d+;8H(?:\x1b\[[0-9;]*m)*(/[a-z]+(?: (?:--)?[a-z]+)?) {2,}"
        catalogued = set(re.findall(command_cell, catalog))
        covered = completion_cases.keys()
        assert catalogued == covered, (catalogued - covered, covered - catalogued)
        type_keys(b"\x1b", "Proxy overview", wait_for_input=True)
        for path, next_step in completion_cases.items():
            for key in (b"\r", b"\t"):
                type_keys(path + key, b"H" + path + b" ", wait_for_input=True)
                assert next_step in result.rsplit(b"\x1b[2J", 1)[-1], (path, key, next_step)
                type_keys(b"\x03", "Type / for commands", wait_for_input=True)

        type_keys(b"/help system\r", "Use /help to open the command catalog.", wait_for_input=True)
        type_keys(b"/system\r", b"\x1b[26;9H/system ", wait_for_input=True)
        system_menu = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b" System proxy " in system_menu
        assert all(b"H  " + action in system_menu for action in system_actions)
        type_keys(b"start\r", b"\x1b[26;9H/system start ", wait_for_input=True)
        assert b"Starting the system proxy" not in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\x1b", "Enter Run  Esc Clear", wait_for_input=True)
        assert b"\x1b[26;9H/system " in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\x1b", "Type / for commands", wait_for_input=True)
        type_keys(b"\x1b", "Proxy overview", wait_for_input=True)
        type_keys(b"/system \r", "Local profile ready", wait_for_input=True)
        system_status = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"Start at boot" in system_status and b"/system disable" in system_status
        assert b"Set your nodes and rules, then run /system start." in system_status
        assert_shortcuts(system_status, *(b"/system " + action for action in system_actions))
        type_keys(b"/system apply\r\r", "This requires a running system proxy", wait_for_input=True)
        type_keys(b"/system invalid-action\r", "Use /system to see the available actions.", wait_for_input=True)

        # Record child dispatch from the running console with a stub in its disposable install.
        executable = pathlib.Path(command[0]).resolve()
        with tempfile.TemporaryDirectory(prefix="system-dispatch-", dir=executable.parent) as directory:
            original_executable = pathlib.Path(directory) / "binary"
            shim = pathlib.Path(directory) / "record"
            trace = pathlib.Path(directory) / "calls"
            trace.touch()
            os.link(executable, original_executable)
            shim.write_text(
                '#!/bin/sh\n'
                'test "$#" = 4 && test "$1" = --state-dir && test "$3" = system || exit 64\n'
                f'printf "%s\\n" "$4" >> {shlex.quote(str(trace))}\n'
                'printf "Test dispatch /system %s\\n" "$4"\n'
                'test "$4" != _check-start\n'
            )
            shim.chmod(0o700)
            try:
                os.replace(shim, executable)
                for action in system_actions:
                    path = b"/system " + action
                    before = trace.read_bytes()
                    type_keys(path + b"\r", b"H" + path + b" ", wait_for_input=True)
                    assert trace.read_bytes() == before
                    type_keys(b"\r", b"Test dispatch /system ", wait_for_input=True)
                    accepted = (action, b"_check-start") if action == b"start" else (action,)
                    dispatched = trace.read_bytes()[len(before):].splitlines()
                    assert len(dispatched) == 1 and dispatched[0] in accepted, dispatched
            finally:
                os.replace(original_executable, executable)

        profile_path = pathlib.Path(command[-1]) / "profile.json"
        with tempfile.TemporaryDirectory(prefix="missing-profile-", dir=profile_path.parent) as directory:
            original_profile = pathlib.Path(directory) / "profile.json"
            profile_path.rename(original_profile)
            try:
                type_keys(b"/status \r", "No nodes configured", wait_for_input=True)
                type_keys(b"/rules default\r\r", "Add a share link with /nodes add", wait_for_input=True)
            finally:
                original_profile.rename(profile_path)
        type_keys(b"/status \r", "Local profile ready", wait_for_input=True)

        type_keys(b"/rules ", "Choose where unmatched traffic goes", wait_for_input=True)
        rule_menu = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"Add a routing rule" in rule_menu and b"Remove a routing rule" in rule_menu
        assert b"H  upstream" in rule_menu
        type_keys(b"default\r", b"\x1b[26;9H/rules default ", wait_for_input=True)
        assert b"Default proxy group" in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\x1b[B\r", b"H/rules default proxy ")
        type_keys(b"\r", "Everything else  →  Default proxy group", wait_for_input=True)
        type_keys(b"/rules default IPv6\r\r", "Everything else  →  Node · 美国 IPv6", wait_for_input=True)
        type_keys(b"/rules default direct", b"H/rules default direct", wait_for_input=True)
        type_keys(b"\x1b", "Enter Run  ↑↓ Select  Esc Close suggestions", wait_for_input=True)
        type_keys(b"\r", "Everything else  →  Direct", wait_for_input=True)
        type_keys(b"/rules default ", "Enter an address to use it", wait_for_input=True)
        type_keys(b"upstream\r", b"\x1b[26;9H/rules default upstream ")
        type_keys(b"\r", "Saving uses it for unmatched")
        type_keys(b"\x1b", "Type / for commands")
        assert json.loads(subprocess.check_output(default_query, timeout=8)) == "direct"
        type_keys(b"/rules default upstream\r\r", "Saving uses it for unmatched")
        complete_form(b"socks5://127.0.0.1:42179\r", "Everything else  →  External upstream")
        assert json.loads(subprocess.check_output(default_query, timeout=8)) == "upstream"
        type_keys(b"/rules default direct\r\r", "Everything else  →  Direct", wait_for_input=True)
        complete_form(b"/rules upstream off\r", "External upstream settings saved.")
        type_keys(b"\x1b", "Type / for commands")
        type_keys(b"/nodes ", "Add nodes from share links")
        type_keys(b"\x1b", "Enter Run  Esc Clear", wait_for_input=True)
        type_keys(b"\x1b", "Type / for commands", wait_for_input=True)
        type_keys(b"/check node ", b"H/check node ", wait_for_input=True)
        assert b"Matching nodes" in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\x03", "Type / for commands", wait_for_input=True)
        type_keys(b"/check \t", b"H/check node ", wait_for_input=True)
        node_panel = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"Matching nodes" in node_panel and b"Other Region" in node_panel
        type_keys(b'"Other', b'H/check node "Other', wait_for_input=True)
        assert_reselection("› Other Region")
        type_keys(b"\x1b\x1b", "Enter for options  Esc Previous input", wait_for_input=True)
        type_keys(b"\x1b", b"H/check node ", wait_for_input=True)
        assert b"Matching nodes" not in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\r", "Matching nodes", wait_for_input=True)
        type_keys(b"Other", b"H/check node Other", wait_for_input=True)
        assert_reselection("› Other Region")
        type_keys(b"\r", b'H/check node "Other Region" ', wait_for_input=True)
        completed_check = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"Matching nodes" not in completed_check and b"Isolated node check" not in completed_check
        type_keys(f"--url {health}\r".encode(), "Isolated node check · Other Region", wait_for_input=True)
        type_keys(f"/check --url {health}\r".encode(), "Isolated node check · 美国", wait_for_input=True)
        restarted = subprocess.check_output(command + ["status"], env=terminal_env, text=True, timeout=10)
        capture = restarted.splitlines()[0].partition(" · ")[0]
        assert capture == "System capture is off" and "Local profile ready" in restarted
        type_keys(b"/lang zh\r\r", "代理概览")

        offset = len(result)
        resize(44, 9)
        expect(b"\x1b[8;5H\x1b[?25h", after=offset)
        type_keys(b"/", "› /status", wait_for_input=True)
        type_keys(b"\x1b", "  /status", wait_for_input=True)
        assert "› /status".encode() not in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\r", "› /status", wait_for_input=True)
        type_keys(b"\x1b\x1b", "代理概览", wait_for_input=True)

        offset = len(result)
        resize(44, 11)
        expect(b"\x1b[9;7H\x1b[?25h", after=offset)
        type_keys(b"/nodes group\r\r", "选择节点调整顺位", wait_for_input=True)
        narrow_group = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"\x1b[3;5H" in narrow_group and "顺位 1".encode() in narrow_group
        assert b"\x1b[9;7H\x1b[?25h" in narrow_group
        type_keys(b"\x1b[B\x1b[B", "加入组", wait_for_input=True)
        type_keys(b"\x1b", "第 2/2 页", wait_for_input=True)
        deselected_page = result.rsplit(b"\x1b[2J", 1)[-1]
        assert "加入组".encode() in deselected_page and "› Other Region".encode() not in deselected_page
        type_keys(b"\x1b", "代理概览", wait_for_input=True)
        type_keys(b"/status \r", "运行状态", wait_for_input=True)
        narrow_status = result.rsplit(b"\x1b[2J", 1)[-1]
        assert b"\x1b[3;5H" in narrow_status and "开机自启".encode() in narrow_status
        assert "╭".encode() not in narrow_status.split(b"\x1b[8;3H", 1)[0]
        if "本机配置已就绪".encode() not in narrow_status:
            type_keys(b"\x1b[C", "本机配置已就绪", wait_for_input=True)
        type_keys(b"/status --json\r", "Esc 返回   ← → 翻页")
        type_keys(b"\x1b[C", "第 2/", wait_for_input=True)
        type_keys(b"/setup\r", b"H/setup ")
        type_keys(b"\r", "拖入 sing-box JSON", wait_for_input=True)
        type_keys(b"\x1b", "第 2/", wait_for_input=True)
        type_keys(b"\x1b[D", "第 1/")
        type_keys(b"\x1b", "代理概览")
        type_keys(b"\x1b[A", b"H/status --json")
        type_keys(b"\x1b", "输入 / 查看命令")
        type_keys(b"\x1b[200~/quit\n/presets\x1b[201~", b"/quit /presets")
        type_keys(b"\x03", "输入 / 查看命令")
        type_keys(b"/setup\r", b"H/setup ")
        type_keys(b"\r", "拖入 sing-box JSON")
        type_keys(b"\x1b", "输入 / 查看命令")
        type_keys(b"/preview\r", f"127.0.0.1:{port}")
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            result_from_engine = fetch("http://api.anthropic.com/payload")
            if result_from_engine.returncode == 0:
                break
            time.sleep(0.04)
        assert result_from_engine.stdout == "served by 美国", result_from_engine
        type_keys(b"\x03", "已停止", wait_for_input=True)
        resize(90, 28)
        type_keys(b"/nodes import\r\r", "拖入 sing-box JSON")
        type_keys(f"'{source}'\r".encode(), "按优先顺序选择节点")
        type_keys(b"IPv6\r", "所选顺序  美国 IPv6")
        type_keys("美国\r".encode(), "所选顺序  美国 IPv6 → 美国")
        type_keys(b"\r", "已校验配置 · 美国 IPv6 → 美国", wait_for_input=True)
        inventory = json.loads(subprocess.check_output(command + ["nodes", "--json"], timeout=8))
        assert inventory["order"] == ["美国 IPv6", "美国"]
        type_keys(b"/nodes add\r", b"H/nodes add ", wait_for_input=True)
        assert "Enter 打开添加页".encode() in result.rsplit(b"\x1b[2J", 1)[-1]
        type_keys(b"\r", "粘贴分享链接，每行一条。", wait_for_input=True)
        type_keys(b"\x1b[200~broken://fixture-value\x1b[201~", "•••", wait_for_input=True)
        type_keys(b"\r", "第 1 条链接", wait_for_input=True)
        assert json.loads(subprocess.check_output(command + ["nodes", "--json"], timeout=8)) == inventory
        type_keys(b"\x1b", "粘贴分享链接，每行一条。", wait_for_input=True)
        type_keys(b"\x1b[200~" + b"x" * 4200 + b"\x1b[201~", "链接超出输入长度", wait_for_input=True)
        links = (b"socks5://fixture:private-example-a@127.0.0.1:9#First%20paste\r\n"
                 b"socks5://fixture:private-example-b@127.0.0.1:19#Second%20paste")
        paste_start = len(result)
        type_keys(b"\x1b[200~" + links + b"\x1b[201~", "•••", wait_for_input=True)
        type_keys(b"\r", "已添加 2 个节点。", wait_for_input=True)
        added = json.loads(subprocess.check_output(command + ["nodes", "--json"], timeout=8))
        assert added["order"] == inventory["order"] + ["First paste", "Second paste"]
        type_keys(b"\x1b[A", b"H/nodes add", wait_for_input=True)
        assert b"private-example-" not in result[paste_start:] and b"--stdin" not in result[paste_start:]
        type_keys(b"\x03", "输入 / 查看命令", wait_for_input=True)
        offset = len(result)
        resize(20, 7)
        expect(b"\x1b[6;", after=offset)
        type_keys(b"\x1b", "代理概览", wait_for_input=True)
        compact_frame = result.rsplit(b"\x1b[2J", 1)[-1]
        compact_column = 20 - len(version_label)
        assert f"\x1b[1;{compact_column}H".encode() + b"\x1b[38;2;151;146;141m" + version_label in compact_frame
        type_keys(b"/quit\r", b"H/quit ")
        type_keys(b"\r", b"\x1b[?1049l")
        assert b"\x1b[?1000l" in result
        assert all(hint.encode() not in result for hint in ("↑↓ 历史", "↑↓ History"))
        assert process.wait(timeout=4) == 0
        restored = termios.tcgetattr(slave)
        # BSD can keep its internal input-retype bit set until the next terminal read.
        restored[3] &= ~getattr(termios, "PENDIN", 0)
        original[3] &= ~getattr(termios, "PENDIN", 0)
        assert restored == original, (restored, original)
    finally:
        os.close(master)
        os.close(slave)
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)


def verify(bundle, scratch, fixture, first, second, outside):
    source = scratch / "fixture.json"
    state = scratch / "state with spaces"
    home = scratch / "install with spaces"
    home.mkdir()
    port, control = unused_ports()
    health = "http://127.0.0.1:9/health"
    source.write_text(json.dumps({"outbounds": [first.outbound(), second.outbound(), outside.outbound(),
                                               {"type": "direct", "tag": "DIRECT"}]}))

    env = {**os.environ, "PROXYCTL_INSTALL_ROOT": str(home), "PATH": f"{home}/.local/bin:/usr/bin:/bin"}
    (home / ".local/bin").mkdir(parents=True)
    retired = home / ".local/bin/sbctl"
    retired.symlink_to(home / ".local/share/proxyctl/versions/0.1.0/bin/proxyctl")
    for _ in range(2):
        subprocess.run(["/bin/sh", str(bundle / "install.sh")], env=env, check=True, capture_output=True, timeout=15)
    bundled_version = subprocess.check_output([str(bundle / "bin/proxyctl"), "--version"], text=True).strip()
    assert subprocess.check_output(["proxyctl", "--version"], env=env, text=True).strip() == bundled_version
    assert not retired.is_symlink()
    retired.write_text("unrelated command")
    subprocess.run(["/bin/sh", str(bundle / "install.sh")], env=env, check=True, capture_output=True, timeout=15)
    assert retired.read_text() == "unrelated command"
    command = [str(home / ".local/bin/proxyctl"), "--state-dir", str(state)]

    def cli(*args, ok=True):
        result = subprocess.run(command + list(args), capture_output=True, text=True, timeout=23)
        assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
        return result.stdout

    inventory = json.loads(cli("nodes", "--file", str(source), "--json"))
    assert [item["name"] for item in inventory["nodes"]] == [first.name, second.name, outside.name]
    cli("legacy", ok=False)
    cli("setup", "--legacy", ok=False)
    cli("nodes", "--legacy", ok=False)
    cli("use", "--auto", ok=False)
    cli("system", "use", "--auto", ok=False)
    cli("system", "_manage-installed", "en", "shell", "check", ok=False)
    cli("setup", str(source), "--port", str(port), "--control-port", str(control), "--default", "proxy",
        "--node", first.name, "--node", second.name.lower())
    config = state / "profile.json"
    baseline = config.read_bytes()
    cli("setup", str(source), "--node", "DIRECT", ok=False)
    assert config.read_bytes() == baseline
    assert first.name in cli("nodes", "group")
    cli("nodes", "group", first.name, first.name, ok=False)
    assert config.read_bytes() == baseline
    cli("nodes", "group", outside.name, first.name)
    expected = json.loads(baseline)
    selector = next(outbound for outbound in expected["outbounds"] if outbound["tag"] == "proxyctl-selected")
    selector["outbounds"] = [outside.name, first.name]
    selector["default"] = outside.name
    assert json.loads(config.read_bytes()) == expected
    assert json.loads(cli("system", "plan", "--json"))["order"] == [outside.name, first.name]
    cli("nodes", "group", first.name, second.name)
    assert config.read_bytes() == baseline
    assert stat.S_IMODE(config.stat().st_mode) == 0o600
    assert stat.S_IMODE(state.stat().st_mode) == 0o700
    staged = json.loads(cli("status", "--json"))
    assert staged["service"] == "ready" and staged["port"] == port
    assert first.name in cli("service", "plan")
    for language in ("zh", "en"):
        help_text = subprocess.check_output(command + ["--help"], env={**os.environ, "PROXYCTL_LANGUAGE": language}, text=True)
        assert "proxyctl preview" not in help_text and "proxyctl service" not in help_text
        assert "proxyctl start | stop" in help_text
    assert f"隔离节点检测 · {first.name}" in cli("check", "--url", health)
    assert json.loads(cli("status", "--json"))["service"] == "ready"
    assert config.read_bytes() == baseline
    planned = json.loads(cli("system", "plan", "--json"))
    assert planned["fallback"] == "direct" and planned["presets"] == ["claude", "openai", "gemini"]

    def preview(expected, automatic=False):
        if automatic:
            installed = (home / ".local/bin/proxyctl").resolve().parents[1]
            process = failover_preview(fixture, state, installed)
        else:
            process = subprocess.Popen(command + ["preview"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            for _ in range(24):
                if process.poll() is not None:
                    raise AssertionError(process.stdout.read().decode())
                status = json.loads(cli("status", "--json"))
                if status.get("selectedNode") == expected:
                    return process
                time.sleep(0.13)
            raise AssertionError("real core did not become ready with the expected selection")
        except BaseException:
            stop(process)
            raise

    def fetch(url):
        return subprocess.run(["/usr/bin/curl", "-q", "-fsS", "--max-time", "3", "--noproxy", "",
                               "--proxy", f"http://127.0.0.1:{port}", url], text=True, capture_output=True, timeout=4)

    def payload(expected, url="http://127.0.0.1:9/payload"):
        result = fetch(url)
        assert result.returncode == 0 and result.stdout == expected.identity, result

    old_preference = state / "selection-mode.json"
    old_preference.write_text(json.dumps({
        "scope": json.loads(baseline)["experimental"]["clash_api"]["secret"],
        "automatic": False,
        "url": health,
    }))
    process = preview(first.name, automatic=True)
    try:
        mode = cli("status")
        capture = mode.splitlines()[0].partition(" · ")[0]
        assert capture == "全机接管未启用" and "仅本机回环诊断在运行" in mode
        payload(first)
        assert first.name in cli("check", "--url", health)
        assert second.name in cli("test", second.name, "--url", health)
        cli("setup", str(source), "--node", outside.name, ok=False)
        first.available = False
        output = cli("test", "--url", health)
        assert output.index(first.name) < output.index(second.name) and "探测失败" in output
        wait_for(lambda: json.loads(cli("nodes", "--json"))["selected"] == second.name)
        payload(second)
        assert process.poll() is None
        second.available = False
        cli("test", "--url", health, ok=False)
        assert json.loads(cli("nodes", "--json"))["selected"] == second.name
        assert outside.received == 0
    finally:
        stop(process)
        first.available = second.available = True

    process = preview(second.name, automatic=True)
    try:
        payload(second)
        wait_for(lambda: json.loads(cli("nodes", "--json"))["selected"] == first.name)
        payload(first)
        assert process.poll() is None
    finally:
        stop(process)

    cli("setup", str(source), "--port", str(port), "--control-port", str(control),
        "--node", first.name, "--node", second.name, "--preset", "claude", "--preset", "gemini")
    enabled = {entry["name"]: entry["enabled"] for entry in json.loads(cli("presets", "--json"))}
    assert enabled == {"claude": True, "openai": False, "gemini": True}
    cli("presets", "enable", "openai")
    cli("presets", "disable", "claude")
    plan = json.loads(cli("system", "plan", "--json"))
    assert plan["presets"] == ["openai", "gemini"] and plan["fallback"] == "direct" and len(plan["addresses"]) == 2
    cli("presets", "enable", "claude")
    plan = json.loads(cli("system", "plan", "--json"))
    assert plan["presets"] == ["claude", "openai", "gemini"] and plan["order"] == [first.name, second.name]
    rules = cli("firewall", "plan")
    assert "on utun99" in rules and "user = 0 group =" in rules
    assert "block drop out quick inet all" in rules and "block drop out quick inet6 all" in rules

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), DirectFixture) as direct:
        thread = threading.Thread(target=direct.serve_forever, daemon=True)
        thread.start()
        direct_url = f"http://localhost:{direct.server_address[1]}/payload"
        process = preview(first.name)
        try:
            assert fetch(direct_url).stdout == "served directly"
            payload(first, "http://api.anthropic.com/payload")
            payload(first, "http://chatgpt.com/payload")
            payload(first, "http://gemini.google.com/payload")
            first.available = second.available = False
            assert fetch("http://api.anthropic.com/payload").returncode != 0
            assert fetch("http://chatgpt.com/payload").returncode != 0
            assert fetch("http://gemini.google.com/payload").returncode != 0
            result = fetch(direct_url)
            assert result.returncode == 0 and result.stdout == "served directly", result
            assert outside.received == 0
            verify_outer_proxy(port, outside)
        finally:
            stop(process)
            first.available = second.available = True
            direct.shutdown()
            thread.join(timeout=4)
    tty_smoke(command, port, fetch, health, source, preview)



def verify_policy(bundle, scratch, fixture, first, second, upstream):
    source = scratch / "policy.json"
    state = scratch / "editable policy"
    port, controller = unused_ports()
    command = [str(bundle / "bin/proxyctl"), "--state-dir", str(state)]
    order = {"type": "selector", "tag": "Preferred", "outbounds": [first.name, second.name]}
    source.write_text(json.dumps({"outbounds": [first.outbound(), second.outbound(), upstream.outbound(), order]}))

    def cli(*args, ok=True):
        result = subprocess.run(command + list(args), capture_output=True, text=True, timeout=20)
        assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
        return result.stdout

    def fetch(url):
        return subprocess.run(["/usr/bin/curl", "-q", "-fsS", "--max-time", "2", "--noproxy", "",
                               "--proxy", f"http://127.0.0.1:{port}", url], capture_output=True, text=True, timeout=3)

    def selected(node):
        return json.loads(cli("status", "--json")).get("selectedNode") == node.name

    def persistent(channel):
        channel.sendall(b"GET /persistent HTTP/1.1\r\nHost: api.anthropic.com\r\n\r\n")
        response = http.client.HTTPResponse(channel)
        response.begin()
        return response.read().decode()

    cli("setup", str(source), "--group", order["tag"], "--port", str(port), "--control-port", str(controller))
    legacy_file = state / "profile.json"
    legacy = json.loads(legacy_file.read_bytes())
    definitions = {item["tag"]: item for item in legacy["route"].pop("rule_set")}
    legacy["route"]["final"] = "proxyctl-selected"
    original_routes = []
    for rule in legacy["route"]["rules"]:
        tags = rule.get("rule_set", [])
        if tags and tags[0].startswith("proxyctl-preset:"):
            for entry in definitions[tags[0]]["rules"]:
                original_routes.append({**entry, "action": "route", "outbound": rule["outbound"]})
        if not tags:
            original_routes.append(rule)
    legacy["route"]["rules"] = original_routes
    legacy["dns"]["rules"] = [rule for rule in legacy["dns"]["rules"] if "rule_set" not in rule]
    legacy["outbounds"] = [entry for entry in legacy["outbounds"] if entry["tag"] != "proxyctl-direct"]
    legacy_file.write_text(json.dumps(legacy))
    cli("rules", "add", "192.0.2.1", "direct")
    cli("rules", "remove", "192.0.2.1", "direct")
    assert json.loads(cli("rules", "--json")) == []
    cli("setup", str(source), "--group", order["tag"], "--port", str(port), "--control-port", str(controller))
    cli("rules", "upstream", f"socks5://127.0.0.1:{port}", ok=False)
    cli("rules", "upstream", f"socks5://127.0.0.1:{upstream.server_address[1]}")
    cli("rules", "add", "*.External.Test.", "upstream")
    cli("rules", "add", "API.Anthropic.com", "direct")
    cli("rules", "add", "192.0.2.133/24", "proxy")
    cli("rules", "add", "face:broken::/64", "direct", ok=False)
    cli("rules", "upstream", "off", ok=False)
    managed = (state / "profile.json").read_bytes()
    plan = json.loads(cli("system", "plan", "--json"))
    assert plan["upstream"] and plan["order"] == order["outbounds"]
    assert {r["value"] for r in plan["rules"]} == {"api.anthropic.com", "external.test", "192.0.2.0/24"}

    process = failover_preview(fixture, state, bundle)
    try:
        wait_for(lambda: selected(first))
        assert fetch("http://api.anthropic.com/payload").stdout == first.identity
        assert fetch("http://new.external.test/payload").stdout == upstream.identity
        upstream.available = False
        assert fetch("http://new.external.test/payload").returncode != 0
        assert fetch("http://api.anthropic.com/payload").stdout == first.identity
        upstream.available = True

        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), DirectFixture) as direct:
            server = threading.Thread(target=direct.serve_forever, daemon=True)
            server.start()
            direct_url = f"http://127.0.0.1:{direct.server_address[1]}/payload"
            try:
                assert fetch(direct_url).stdout == "served directly"
                cli("rules", "add", "127.0.0.1/32", "proxy")
                wait_for(lambda: fetch(direct_url).stdout == first.identity, limit=5)
                cli("rules", "remove", "127.0.0.1", "proxy")
                wait_for(lambda: fetch(direct_url).stdout == "served directly", limit=5)
                assert process.poll() is None and (state / "profile.json").read_bytes() == managed
            finally:
                direct.shutdown()
                server.join(timeout=4)

        with socket.create_connection(("127.0.0.1", port), timeout=4) as held:
            held.sendall(b"CONNECT api.anthropic.com:80 HTTP/1.1\r\nHost: api.anthropic.com:80\r\n\r\n")
            header = b""
            while not header.endswith(b"\r\n\r\n"):
                byte = held.recv(1)
                assert byte
                header += byte
            assert b" 200 " in header
            assert persistent(held) == first.identity
            first.available = False
            wait_for(lambda: selected(second))
            assert fetch("http://api.anthropic.com/payload").stdout == second.identity
            assert persistent(held) == first.identity

        second.available = False
        assert fetch("http://api.anthropic.com/payload").returncode != 0
        assert fetch("http://new.external.test/payload").stdout == upstream.identity
        second.available = first.available = True
        wait_for(lambda: selected(first))
    finally:
        first.available = second.available = upstream.available = True
        stop(process)
    cli("rules", "remove", "external.test", "upstream")
    cli("rules", "upstream", "off")
    assert not json.loads(cli("system", "plan", "--json"))["upstream"]

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), ConnectFixture) as http_upstream:
        thread = threading.Thread(target=http_upstream.serve_forever, daemon=True)
        thread.start()
        try:
            address = f"127.0.0.1:{http_upstream.server_address[1]}"
            cli("rules", "upstream", f"https://{address}")
            assert json.loads(cli("system", "plan", "--json"))["upstream"]
            cli("rules", "upstream", f"http://{address}")
            cli("rules", "add", "external.test", "upstream")
            process = subprocess.Popen(command + ["preview"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            try:
                wait_for(lambda: fetch("http://new.external.test/payload").stdout == "served by HTTP CONNECT")
                assert fetch("http://api.anthropic.com/payload").stdout == first.identity
            finally:
                stop(process)
        finally:
            http_upstream.shutdown()
            thread.join(timeout=4)


def verify_share_links(bundle, scratch):
    state = scratch / "link profile"
    command = [str(bundle / "bin/proxyctl"), "--state-dir", str(state)]
    identifier = "b89ad67c-fbf7-431f-9a36-a15ef61c3cec"

    def encoded(value):
        data = value.encode() if isinstance(value, str) else value
        return base64.urlsafe_b64encode(data).decode().rstrip("=")

    vmess = encoded(json.dumps({"add": "127.0.0.1", "port": "443", "id": identifier,
                               "net": "ws", "path": "/fixture", "tls": "tls", "ps": "VMess fixture"}))
    vless_public = encoded(bytes(range(32)))
    username = encoded("aes-128-gcm:fixture-secret")
    links = [
        (f"ss://{username}@127.0.0.1:448#Repeated", "shadowsocks"),
        (f"ss://{encoded('aes-128-gcm:fixture-secret@127.0.0.1:449')}#Repeated", "shadowsocks"),
        (f"vmess://{vmess}", "vmess"),
        (f"vless://{identifier}@127.0.0.1:440?security=reality&pbk={vless_public}&sid=cb23&fp=chrome&sni=fixture.test#Reality", "vless"),
        ("trojan://fixture-secret@127.0.0.1:441?security=tls&type=grpc&serviceName=fixture#Trojan", "trojan"),
        ("hysteria://127.0.0.1:442?auth=fixture-secret&upmbps=10&downmbps=50#Hysteria", "hysteria"),
        ("hy2://fixture-secret@[::1]:443,4000-4002?obfs=salamander&obfs-password=fixture-key#Hopping", "hysteria2"),
        (f"tuic://{identifier}:fixture-secret@127.0.0.1:445?congestion_control=bbr&udp_relay_mode=native#TUIC", "tuic"),
        ("anytls://fixture-secret@127.0.0.1:446?sni=fixture.test#AnyTLS", "anytls"),
        ("socks5://fixture:fixture-secret@127.0.0.1:1090#Local", "socks"),
        ("https://fixture:fixture-secret@127.0.0.1:450#CONNECT", "http"),
        ("ssh://fixture:fixture-secret@127.0.0.1:22#SSH", "ssh"),
        ("snell://fixture-secret@127.0.0.1:444?version=4#Snell", "snell"),
        ("naive+https://fixture:fixture-secret@127.0.0.1:447#Naive", "naive")
    ]

    def cli(*args, data=None, ok=True):
        result = subprocess.run(command + list(args), input=data, text=True, capture_output=True, timeout=20)
        assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
        assert "fixture-secret" not in result.stdout + result.stderr
        return result.stdout

    cli("nodes", "add", "--stdin", data="\n".join(url for url, _ in links))
    inventory = json.loads(cli("nodes", "--json"))
    assert [node["protocolName"] for node in inventory["nodes"]] == [proto for _, proto in links]
    assert inventory["order"][:2] == ["Repeated", "Repeated 2"]
    assert inventory["nodes"][6]["endpoint"] == "IPv6"
    profile = state / "profile.json"
    raw = json.loads(profile.read_bytes())
    assert next(item for item in raw["outbounds"] if item["tag"] == "Reality")["tls"]["reality"]["short_id"] == "cb23"
    assert next(item for item in raw["outbounds"] if item["tag"] == "Hopping")["server_ports"] == ["443:443", "4000:4002"]
    old = profile.read_bytes()
    cli("nodes", "add", "--stdin", data=links[0][0])
    cli("nodes", "add", "--stdin", data=links[0][0] + "\ninvalid://fixture-secret", ok=False)
    cli("nodes", "add", "--stdin", data=f"vless://{identifier}@127.0.0.1:443?type=xhttp", ok=False)
    cli("nodes", "add", "--stdin", data="hy2://fixture-secret@127.0.0.1:443?pinSHA256=000", ok=False)
    assert profile.read_bytes() == old
    cli("system", "plan", "--json")


def verify_catch_all(bundle, scratch, primary, upstream):
    state = scratch / "catch all"
    source = scratch / "fallback.json"
    source.write_text(json.dumps({"outbounds": [primary.outbound(), upstream.outbound()]}))
    port, controller = unused_ports()
    command = [str(bundle / "bin/proxyctl"), "--state-dir", str(state)]

    def cli(*args, ok=True):
        result = subprocess.run(command + list(args), capture_output=True, text=True, timeout=20)
        assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
        return result.stdout

    cli("setup", str(source), "--node", primary.name, "--port", str(port), "--control-port", str(controller))
    cli("rules", "default", "upstream", ok=False)
    cli("rules", "upstream", f"socks5://127.0.0.1:{upstream.server_address[1]}", "--default")
    assert json.loads(cli("rules", "default", "--json")) == "upstream"
    cli("rules", "upstream", "off", ok=False)
    cli("presets", "create", "Work", "proxy", "*.work.test")
    cli("presets", "create", "Google", "upstream", "google.com")
    cli("presets", "add", "Work", "192.0.2.4/24")
    cli("presets", "add", "claude", "renamed.test")
    cli("presets", "create", "Empty", "direct")
    cli("presets", "disable", "Empty")
    cli("presets", "delete", "Empty")
    cli("presets", "remove", "openai", "openai.com")
    plan = json.loads(cli("system", "plan", "--json"))
    assert plan["fallback"] == "upstream" and plan["upstream"]
    assert any(x["name"] == "Work" and x["networks"] == ["192.0.2.0/24"] for x in plan["collections"])
    process = subprocess.Popen(command + ["preview"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def fetch(url):
        return subprocess.run(["/usr/bin/curl", "-q", "-fsS", "--max-time", "2", "--noproxy", "",
                               "--proxy", f"http://127.0.0.1:{port}", url], capture_output=True, text=True, timeout=3)

    try:
        for _ in range(25):
            if json.loads(cli("status", "--json")).get("selectedNode") == primary.name:
                break
            time.sleep(.1)
        assert fetch("http://no-match.test/").stdout == upstream.identity
        gemini_hosts = (
            "gemini.google.com", "gemini.google", "bard.google.com", "gemini.gstatic.com",
            "geminiweb-pa.clients6.google.com",
            "robinfrontend-pa.googleapis.com", "webchannel-robinfrontend-pa.googleapis.com",
            "robinfrontend-pa.mtls.googleapis.com", "webchannel-robinfrontend-pa.mtls.googleapis.com",
            "aistudio.google.com", "makersuite.google.com", "alkalimakersuite-pa.clients6.google.com",
            "webchannel-alkalimakersuite-pa.clients6.google.com",
            "alkalimakersuiteapplets.pa.clients6.google.com", "alkalimakersuiteapplets.pa.googleapis.com",
            "generativelanguage.googleapis.com", "cloudcode-pa.googleapis.com", "cloudaicompanion.googleapis.com",
        )
        for host in gemini_hosts:
            assert fetch(f"http://{host}/").stdout == primary.identity, host
        for host in ("www.google.com", "www.gstatic.com", "accounts.google.com", "oauth2.googleapis.com",
                     "aiplatform.googleapis.com", "www.youtube.com"):
            assert fetch(f"http://{host}/").stdout == upstream.identity
        assert fetch("http://api.openai.com/").stdout == upstream.identity
        assert fetch("http://api.anthropic.com/").stdout == primary.identity
        assert fetch("http://api.renamed.test/").stdout == primary.identity
        assert fetch("http://new.work.test/").stdout == primary.identity
        assert fetch("http://192.0.2.31/").stdout == primary.identity
        upstream.available = False
        assert fetch("http://no-match.test/").returncode != 0
        assert fetch("http://new.work.test/").stdout == primary.identity
    finally:
        upstream.available = True
        stop(process)
    cli("presets", "disable", "Work")
    cli("presets", "remove", "Work", "192.0.2.0/24")
    cli("presets", "enable", "Work")
    cli("rules", "default", "direct")
    assert json.loads(cli("system", "plan", "--json"))["fallback"] == "direct"

    labels = [
        ("claude", "Claude", "Claude"),
        ("openai", "OpenAI", "OpenAI"),
        ("gemini", "Gemini", "Gemini"),
        ("apple-relay", "Apple 中继", "Apple Relay"),
        ("direct-services", "常用直连服务", "Direct Services"),
        ("local-network", "局域网", "Local Network"),
        ("international-services", "国际服务", "International Services"),
    ]
    for name, _, _ in labels[3:]:
        cli("presets", "create", name, "proxy", f"{name}.example.test")
    cli("presets", "disable", "国际服务")
    assert not next(group for group in json.loads(cli("presets", "--json")) if group["name"] == "international-services")["enabled"]
    cli("presets", "enable", "International Services")
    cli("presets", "route", "Claude 服务", "direct", ok=False)
    policy = cli("presets", "--json")
    for language, label_column in (("zh", 1), ("en", 2)):
        env = {**os.environ, "PROXYCTL_LANGUAGE": language}
        visible = subprocess.check_output(command + ["presets"], env=env, text=True, timeout=8)
        assert all(f"● {label[label_column]}  →" in visible for label in labels)
        assert "● Work  →" in visible
        assert subprocess.check_output(command + ["presets", "--json"], env=env, text=True, timeout=8) == policy


def verify_node_routes(bundle, scratch, fixture, primary, backup, dedicated):
    state = scratch / "node routes"
    source = scratch / "fixed-nodes.json"
    source.write_text(json.dumps({"outbounds": [primary.outbound(), backup.outbound(), dedicated.outbound()]}))
    port, controller = unused_ports()
    profile = state / "profile.json"
    command = [str(bundle / "bin/proxyctl"), "--state-dir", str(state)]
    pin = f"node:{dedicated.name}"
    primary_pin = f"node:{primary.name}"
    setup = ["setup", str(source), "--node", primary.name, "--node", backup.name,
             "--port", str(port), "--control-port", str(controller)]

    def cli(*args, ok=True, data=None):
        result = subprocess.run(command + list(args), capture_output=True, input=data, text=True, timeout=20)
        assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
        return result.stdout

    cli(*setup)
    cli("presets", "route", "openai", "node:other region")
    cli("presets", "route", "openai", "direct", ok=False)
    cli("presets", "create", "Work", primary_pin, "work.test")
    cli("rules", "add", "override.test", "proxy")
    cli("rules", "add", "192.0.2.0/24", primary_pin)
    cli("rules", "add", "localhost", "direct")
    cli("rules", "default", "node:unknown", ok=False)
    with socket.socket() as occupied:
        occupied.bind(("127.0.0.1", port))
        occupied.listen(1)
        cli("rules", "default", pin)

    plan = json.loads(cli("system", "plan", "--json"))
    assert plan["fallback"] == pin and dedicated.name not in plan["order"]
    assert {entry["name"]: entry["target"] for entry in plan["collections"]} == {
        "claude": "proxy", "openai": pin, "gemini": "proxy", "Work": primary_pin,
    }
    assert any(item["target"] == primary_pin and item["match"] == "ip_cidr" for item in plan["rules"])
    candidate = json.loads(profile.read_text())
    dns = candidate["dns"]
    assert next(server for server in dns["servers"] if server["tag"] == dns["final"])["detour"] == dedicated.name
    assert any(rule.get("domain_suffix") == next(entry["domains"] for entry in plan["collections"] if entry["name"] == "openai")
               and rule["server"] == dns["final"] for rule in dns["rules"])

    def fetch(url):
        return subprocess.run(["/usr/bin/curl", "-q", "-fsS", "--max-time", "3", "--noproxy", "",
                               "--proxy", f"http://127.0.0.1:{port}", url], capture_output=True, text=True, timeout=4)

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), DirectFixture) as direct:
        thread = threading.Thread(target=direct.serve_forever, daemon=True)
        thread.start()
        direct_url = f"http://localhost:{direct.server_address[1]}/payload"
        process = failover_preview(fixture, state, bundle)
        try:
            wait_for(lambda: fetch("http://api.anthropic.com/").stdout == primary.identity)
            assert fetch("http://api.openai.com/").stdout == dedicated.identity
            assert fetch("http://unmatched.test/").stdout == dedicated.identity
            assert fetch("http://work.test/").stdout == primary.identity
            assert fetch("http://192.0.2.30/").stdout == primary.identity
            primary.healthy = False
            wait_for(lambda: fetch("http://api.anthropic.com/").stdout == backup.identity)
            assert fetch("http://override.test/").stdout == backup.identity
            assert fetch("http://api.openai.com/").stdout == dedicated.identity
            assert fetch("http://unmatched.test/").stdout == dedicated.identity
            assert fetch("http://work.test/").stdout == primary.identity
            assert fetch("http://192.0.2.30/").stdout == primary.identity

            cli("rules", "add", "override.test", primary_pin)
            wait_for(lambda: fetch("http://override.test/").stdout == primary.identity)
            cli("rules", "remove", "override.test", primary_pin)
            wait_for(lambda: fetch("http://override.test/").stdout == backup.identity)

            dedicated.available = False
            assert fetch("http://api.openai.com/").returncode != 0
            assert fetch("http://unmatched.test/").returncode != 0
            assert fetch("http://api.anthropic.com/").stdout == backup.identity
            assert fetch(direct_url).stdout == "served directly"
            assert process.poll() is None
        finally:
            primary.healthy = True
            dedicated.available = True
            stop(process)
            direct.shutdown()
            thread.join(timeout=4)

    baseline = profile.read_bytes()
    source.write_text(json.dumps({"outbounds": [primary.outbound(), backup.outbound()]}))
    cli(*setup, ok=False)
    assert profile.read_bytes() == baseline
    cli("nodes", "add", "--stdin", data="socks5://127.0.0.1:9#Added%3A%20Node")
    assert json.loads(cli("rules", "default", "--json")) == pin
    assert any(rule["target"] == primary_pin for rule in json.loads(cli("rules", "--json")))
    cli("rules", "add", "new.test", "node:Added: Node")
    assert any(rule["target"] == "node:Added: Node" for rule in json.loads(cli("system", "plan", "--json"))["rules"])


def verify_group_routes(bundle, scratch, fixture, primary, backup, dedicated):
    state = scratch / "group routes"
    source = scratch / "group-nodes.json"
    source.write_text(json.dumps({"outbounds": [primary.outbound(), backup.outbound(), dedicated.outbound()]}))
    port, controller = unused_ports()
    command = [str(bundle / "bin/proxyctl"), "--state-dir", str(state)]
    group = "Git Work"
    target = f"group:{group}"
    main_target = "group:Main Work"

    def cli(*args, ok=True):
        result = subprocess.run(command + list(args), capture_output=True, text=True, timeout=20)
        assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
        return result.stdout

    cli("nodes", "import", str(source), "--node", primary.name, "--node", backup.name,
        "--port", str(port), "--control-port", str(controller))
    cli("groups", "set", group, dedicated.name, dedicated.name, ok=False)
    cli("groups", "set", group, dedicated.name, backup.name)
    cli("groups", "set", "Main Work", primary.name, backup.name)
    cli("presets", "create", "GitHub", "group:git work", "github.test")
    cli("rules", "add", "single.test", target)
    cli("rules", "add", "localhost", "direct")
    cli("presets", "route", "openai", main_target)
    cli("presets", "route", "Gemini", "direct", ok=False)
    cli("presets", "route", "Gemini", main_target)
    cli("rules", "default", target)
    plan = json.loads(cli("system", "plan", "--json"))
    assert plan["fallback"] == target
    assert plan["groups"] == [{"name": group, "order": [dedicated.name, backup.name]},
                              {"name": "Main Work", "order": [primary.name, backup.name]}]
    assert any(rule["target"] == target and rule["value"] == "single.test" for rule in plan["rules"])
    assert next(preset for preset in plan["collections"] if preset["name"] == "GitHub")["target"] == target
    config = json.loads((state / "profile.json").read_text())
    dns = config["dns"]
    group_resolver = next(server for server in dns["servers"] if server.get("detour") == "proxyctl-group:" + group)
    assert group_resolver["tag"] == dns["final"]
    assert any(rule.get("domain_suffix") == ["github.test"] and rule["server"] == dns["final"] for rule in dns["rules"])
    cli("groups", "remove", group, ok=False)
    cli("rules", "default", "direct")
    cli("presets", "delete", "GitHub")
    cli("groups", "remove", group, ok=False)  # Still used by the independent rule file.
    cli("presets", "create", "GitHub", target, "github.test")
    cli("rules", "default", target)

    def fetch(host):
        return subprocess.run(["/usr/bin/curl", "-q", "-fsS", "--max-time", "2", "--noproxy", "",
                               "--proxy", f"http://127.0.0.1:{port}", f"http://{host}/"],
                              capture_output=True, text=True, timeout=3)

    process = failover_preview(fixture, state, bundle)
    try:
        wait_for(lambda: fetch("github.test").stdout == dedicated.identity)
        assert fetch("single.test").stdout == fetch("unmatched.test").stdout == dedicated.identity
        healthy = ("api.anthropic.com", "api.openai.com", "generativelanguage.googleapis.com")
        assert all(fetch(host).stdout == primary.identity for host in healthy)

        dedicated.available = False
        wait_for(lambda: fetch("github.test").stdout == backup.identity, limit=18)
        assert fetch("single.test").stdout == fetch("unmatched.test").stdout == backup.identity
        groups = json.loads(cli("groups", "--json"))
        assert groups["defaultMember"] == primary.name
        assert [group["selectedNode"] for group in groups["groups"]] == [backup.name, primary.name]

        backup.available = False
        assert fetch("github.test").returncode != 0
        assert all(fetch(host).stdout == primary.identity for host in healthy)
        dedicated.available = True
        wait_for(lambda: fetch("github.test").stdout == dedicated.identity, limit=18)
    finally:
        dedicated.available = backup.available = True
        stop(process)


def verify_routing_update(bundle, scratch, product, primary, backup):
    helper = scratch / "routing-update-test"
    profiles = product / "Sources/Profiles"
    host = product / "Sources/Host"
    subprocess.run([
        "/usr/bin/xcrun", "swiftc", "-module-cache-path", str(bundle.parent / "module-cache"),
        *(str(path) for path in sorted(profiles.glob("*.swift"))),
        *(str(host / path) for path in ("Command.swift", "Host.swift", "OperationLock.swift", "RoutingRollback.swift")),
        str(product / "Tests/RoutingUpdate.swift"), "-o", str(helper),
    ], check=True, timeout=60)
    port, controller = unused_ports()
    state = scratch / "routing-update"
    core = bundle / "libexec/sing-box"
    subprocess.run([str(helper), str(state), str(core), str(port), str(controller),
                    str(primary.server_address[1]), str(backup.server_address[1])], check=True, timeout=12)
    process = subprocess.Popen([str(core), "-D", str(state), "run", "-c", str(state / "loopback.json")],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def fetch(url):
        return subprocess.run(["/usr/bin/curl", "-q", "-fsS", "--max-time", "2", "--noproxy", "",
                               "--proxy", f"http://127.0.0.1:{port}", url], capture_output=True, text=True, timeout=3)

    try:
        wait_for(lambda: fetch("http://single.test/").stdout == primary.identity)
        assert fetch("http://generativelanguage.googleapis.com/").stdout == primary.identity
        for host in ("api.anthropic.com", "new.openai.com", "unmatched.test", "group.test"):
            assert fetch(f"http://{host}/").stdout == backup.identity
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), DirectFixture) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                assert fetch(f"http://127.0.0.1:{server.server_address[1]}/").stdout == "served directly"
            finally:
                server.shutdown()
                thread.join(timeout=4)
    finally:
        stop(process)


if __name__ == "__main__":
    bundle = pathlib.Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="proxyctl-test-") as scratch:
        scratch = pathlib.Path(scratch)
        product = pathlib.Path(__file__).resolve().parents[1]
        lifecycle = scratch / "protection-test"
        subprocess.run([
            "/usr/bin/xcrun", "swiftc", "-module-cache-path", str(bundle.parent / "module-cache"),
            str(product / "Sources/Host/ProtectionState.swift"),
            str(product / "Sources/Host/OperationLock.swift"),
            str(product / "Sources/Host/PacketFilterRoot.swift"),
            str(product / "Sources/Host/TunnelHTTPSProbe.swift"),
            str(product / "Tests/ProtectionLifecycle.swift"), "-o", str(lifecycle),
        ], check=True, timeout=45)
        subprocess.run([str(lifecycle)], check=True, timeout=5)
        fixture = scratch / "managed-core-fixture"
        host = product / "Sources/Host"
        subprocess.run([
            "/usr/bin/xcrun", "swiftc", "-module-cache-path", str(bundle.parent / "module-cache"),
            *(str(path) for path in sorted((product / "Sources/Profiles").glob("*.swift"))),
            *(str(host / path) for path in
              ("Command.swift", "Host.swift", "OperationLock.swift", "Engine.swift", "ManagedCore.swift", "Probe.swift")),
            str(product / "Tests/ManagedCoreFixture.swift"), "-o", str(fixture),
        ], check=True, timeout=60)
        verify_terminal_handoff(bundle, scratch, product)
        with Server("美国") as first, Server("美国 IPv6") as second, Server("Other Region") as outside:
            verify(bundle, scratch, fixture, first, second, outside)
            verify_policy(bundle, scratch, fixture, first, second, outside)
            verify_share_links(bundle, scratch)
            verify_catch_all(bundle, scratch, first, outside)
            verify_node_routes(bundle, scratch, fixture, first, second, outside)
            verify_group_routes(bundle, scratch, fixture, first, second, outside)
            verify_routing_update(bundle, scratch, product, first, second)
    print("Passed bilingual console, node import, proxy groups, failover, live routing policies, and TUN/PF configuration checks.")
