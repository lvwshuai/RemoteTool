import SwiftUI

/// 终端页。对应 Android `nativeui/TerminalScreen.kt`：
/// `URLSessionWebSocketTask` 连 `/ws/terminal?type=...`，**按行输入协议**（非 PTY，
/// 不保证 vim 之类的全屏程序），输出经 `TerminalBuffer` 做 ANSI 增量渲染后可复制。
struct TerminalScreen: View {
    let api: NativeApi
    let onError: (String) -> Void

    @StateObject private var session: TerminalSession

    private struct Kind: Identifiable {
        let id: String
        let label: String
    }

    private let kinds = [Kind(id: "shell", label: "Shell"),
                         Kind(id: "powershell", label: "PowerShell"),
                         Kind(id: "cmd", label: "CMD")]

    @State private var kind = "powershell"
    @State private var input = ""

    init(api: NativeApi, onError: @escaping (String) -> Void) {
        self.api = api
        self.onError = onError
        _session = StateObject(wrappedValue: TerminalSession(api: api))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(kinds) { option in
                    Button {
                        kind = option.id
                        session.reconnect(kind: option.id, onError: onError)
                    } label: {
                        Text(option.label)
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(kind == option.id ? Color.accentColor.opacity(0.2) : Color.clear,
                                        in: Capsule())
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.35)))
                    }
                    .foregroundColor(kind == option.id ? .accentColor : .secondary)
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            HStack {
                Text(session.state).font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Button("重连") {
                    session.reconnect(kind: kind, onError: onError)
                }
                .font(.system(size: 12))
            }

            ScrollViewReader { reader in
                ScrollView {
                    Text(session.output.isEmpty ? "正在等待终端输出…" : session.output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(red: 0xc7 / 255, green: 0xde / 255, blue: 0xd7 / 255))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("terminal-bottom")
                }
                .background(Color(red: 0x0a / 255, green: 0x11 / 255, blue: 0x1b / 255))
                .onChange(of: session.output) { _ in
                    reader.scrollTo("terminal-bottom", anchor: .bottom)
                }
            }

            HStack(spacing: 8) {
                Button("Ctrl+C") { _ = session.send("\u{03}") }
                    .font(.system(size: 12))
                Button("Ctrl+D") { _ = session.send("\u{04}") }
                    .font(.system(size: 12))
                Button("清屏") { session.clear() }
                    .font(.system(size: 12))
                Spacer()
            }

            HStack(spacing: 8) {
                TextField("输入命令", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .font(.system(size: 13, design: .monospaced))
                Button("发送") {
                    if session.send(input) { input = "" } else { onError("终端未连接") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.state != "已连接")
            }
        }
        .padding(12)
        .onAppear { session.connect(kind: kind, onError: onError) }
        .onDisappear { session.disconnect() }
    }
}

// MARK: - 会话

/// `/ws/terminal` 的薄封装：负责连接、按行发送、把原始输出喂给 `TerminalBuffer`。
@MainActor
final class TerminalSession: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var state = "连接中"

    private let api: NativeApi
    private let buffer = TerminalBuffer()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connected = false

    init(api: NativeApi) {
        self.api = api
    }

    func connect(kind: String, onError: @escaping (String) -> Void) {
        disconnect()
        output = ""
        state = "连接中"
        buffer.clear()

        let base = webSocketBase(api.base)
        let cookie = api.cookie()
        guard let url = URL(string: base + "/ws/terminal?type=\(urlQuery(kind))") else {
            state = "地址无效"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // 与 `/ws/input` 同样的原因：WebSocket 不会自动带 cookie 存储里的 cookie，必须显式写头。
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieAcceptPolicy = .always
        let created = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        session = created

        let webSocket = created.webSocketTask(with: request)
        task = webSocket
        webSocket.resume()
        connected = true

        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await webSocket.receive()
                    guard let self, self.connected else { return }
                    switch message {
                    case .string(let text):
                        self.append(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.append(text) }
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self, self.connected else { return }
                    self.state = "已断开"
                    if let response = webSocket.response as? HTTPURLResponse, response.statusCode != 101 {
                        onError("终端连接失败：HTTP \(response.statusCode)")
                    } else {
                        onError("终端连接失败：\(error.localizedDescription)")
                    }
                    return
                }
            }
        }
        state = "已连接"
    }

    func reconnect(kind: String, onError: @escaping (String) -> Void) {
        connect(kind: kind, onError: onError)
    }

    func disconnect() {
        connected = false
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if state == "已连接" { state = "已断开" }
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard connected, let task else { return false }
        // 服务端按行读：必须补一个换行，否则命令不会被解释执行。
        task.send(.string(text + "\n")) { _ in }
        return true
    }

    func clear() {
        buffer.clear()
        output = ""
    }

    private func append(_ text: String) {
        output = buffer.append(text)
    }
}

/// `TerminalBuffer`（Android `TerminalScreen.kt` 同名类）的 Swift 复刻。
///
/// 处理三件事：跨包被截断的 ANSI 转义序列、回车覆盖式进度输出、以及滚动区域裁剪。
/// 这与「真终端模拟器」不同 —— 服务端本身不是 PTY，我们只求把行式输出渲染得可读。
final class TerminalBuffer {
    private var lines: [[Character]] = [[]]
    private var row = 0
    private var column = 0
    private var escape = ""
    private var savedRow = 0
    private var savedColumn = 0

    func clear() {
        lines = [[]]
        row = 0
        column = 0
        escape = ""
    }

    func append(_ text: String) -> String {
        for character in text {
            if !escape.isEmpty {
                escape.append(character)
                if escape.hasPrefix("\u{1b}[") {
                    if isAsciiRange(character), escape.count > 2 {
                        sequence(String(escape.dropFirst(2)))
                        escape = ""
                    }
                } else if escape.hasPrefix("\u{1b}]") {
                    if character == "\u{07}" || escape.hasSuffix("\u{1b}\\") { escape = "" }
                } else if escape.count >= 2, character != "[", character != "]" {
                    escape = ""
                }
                if escape.count > 4096 { escape = "" }
                continue
            }
            switch character {
            case "\u{1b}":
                escape = String(character)
            case "\r":
                column = 0
            case "\n":
                row += 1
                column = 0
                ensure()
            case "\u{08}":
                column = max(column - 1, 0)
            case "\t":
                column = ((column / 8) + 1) * 8
            default:
                if character >= " " {
                    ensure()
                    while lines[row].count <= column { lines[row].append(" ") }
                    lines[row][column] = character
                    column += 1
                }
            }
        }
        while lines.count > 4000 {
            lines.removeFirst()
            row = max(row - 1, 0)
        }
        let joined = lines.map { String($0) }.joined(separator: "\n")
        return joined.count > 250_000 ? String(joined.suffix(250_000)) : joined
    }

    /// Kotlin 用 `c in '@'..'~'` 判定「这是 CSI 的终止字节」。
    private func isAsciiRange(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        return scalar.value >= 0x40 && scalar.value <= 0x7E
    }

    private func ensure() {
        row = min(max(row, 0), 4999)
        column = min(max(column, 0), 4095)
        while lines.count <= row { lines.append([]) }
    }

    private func sequence(_ raw: String) {
        guard let command = raw.last else { return }
        var parameters = String(raw.dropLast())
        if parameters.hasPrefix("?") { parameters.removeFirst() }
        let args = parameters.components(separatedBy: ";").map { Int($0) ?? 0 }
        let n = max(args.first ?? 0, 1)

        switch command {
        case "A": row = max(row - n, 0)
        case "B": row += n
        case "C": column += n
        case "D": column = max(column - n, 0)
        case "G": column = n - 1
        case "H", "f":
            row = n - 1
            column = max((args.count > 1 ? args[1] : 1), 1) - 1
        case "J":
            if args.first == 2 || args.first == 3 {
                lines = [[]]
                row = 0
                column = 0
            }
        case "K":
            ensure()
            switch args.first {
            case 2:
                lines[row] = []
            case 1:
                for index in 0..<min(lines[row].count, column + 1) { lines[row][index] = " " }
            default:
                if column < lines[row].count {
                    lines[row].removeLast(lines[row].count - column)
                }
            }
        case "s":
            savedRow = row
            savedColumn = column
        case "u":
            row = savedRow
            column = savedColumn
        default:
            break
        }
        ensure()
    }
}
