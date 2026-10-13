import SwiftUI

/// Codex / Hermes 会话页。
///
/// 协议与 Android `nativeui/HermesModel.kt` 对齐：`GET /api/{agent}/sessions` 列表、
/// `GET /api/{agent}/sessions/{id}/messages` 历史、`POST /api/{agent}/runs` 发起任务
/// （带 `Idempotency-Key`），再通过 `GET /api/{agent}/runs/{id}/events` 的 SSE 流消费增量。
///
/// 与 Android 的差距（README 里也列了）：不实现消息编辑 / 回退（rewind）/ 分叉（fork）/
/// 插话（steer）/ 置顶 / 离线队列与附件上传。这些都属于「锦上添花」，
/// 且都建立在同一套 REST + SSE 契约上，不影响互操作性验证。
struct AgentScreen: View {
    let api: NativeApi
    let deviceId: String
    let agent: String
    let onError: (String) -> Void

    @StateObject private var model: AgentModel

    init(api: NativeApi, deviceId: String, agent: String, onError: @escaping (String) -> Void) {
        self.api = api
        self.deviceId = deviceId
        self.agent = agent
        self.onError = onError
        _model = StateObject(wrappedValue: AgentModel(api: api, deviceId: deviceId, agent: agent))
    }

    var body: some View {
        Group {
            if model.selectedId == nil {
                sessionList
            } else {
                conversation
            }
        }
        .onAppear {
            model.attach(report: onError)
            model.loadCapabilities()
            model.refreshSessions()
        }
        .onDisappear { model.stopWatching() }
        .inputSheet($model.renameRequest)
    }

    // MARK: - 会话列表

    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.agentName) 会话").font(.system(size: 15, weight: .medium))
                Spacer()
                Button {
                    model.createSession()
                } label: {
                    Image(systemName: "plus.bubble")
                }
                Button {
                    model.refreshSessions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))

            if let errorText = model.errorText {
                Text(errorText).font(.system(size: 12)).foregroundColor(.red)
                    .padding(.horizontal, 16)
            }

            if model.loadingSessions, model.sessions.isEmpty {
                LoadStateView(isLoading: true, error: nil) { EmptyView() }
                    .frame(maxHeight: .infinity)
            } else if model.sessions.isEmpty {
                LoadStateView(isLoading: false, error: nil, isEmpty: true,
                              emptyText: "还没有会话，点右上角新建一个") { EmptyView() }
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.sessions.indices, id: \.self) { index in
                        sessionRow(model.sessions[index])
                    }
                    if model.hasMoreSessions {
                        Button("载入更多会话") { model.loadMoreSessions() }
                            .font(.system(size: 12))
                    }
                }
                .listStyle(.plain)
            }

            Text("默认模型：\(model.defaultModelText)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
    }

    private func sessionRow(_ session: JSONDict) -> some View {
        let id = session.str("id")
        return Button {
            model.select(id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.str("title", id))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                Text(displayTime(session.str("updated_at", session.str("created_at"))))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("重命名") { model.renamePending(id: id, current: session.str("title", id)) }
            Button("删除", role: .destructive) { model.delete(id) }
        }
        .swipeActions {
            Button("删除", role: .destructive) { model.delete(id) }
        }
    }

    // MARK: - 对话

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    model.closeSession()
                } label: {
                    Image(systemName: "chevron.left")
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.selectedTitle.isEmpty ? "会话" : model.selectedTitle)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Text(model.statusText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if model.running {
                    Button("停止") { model.stop() }
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
                Button {
                    model.loadHistory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
            Divider()

            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.messages) { message in
                            messageBubble(message).id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: model.messages.count) { _ in
                    reader.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: model.messages.last?.text) { _ in
                    reader.scrollTo("bottom", anchor: .bottom)
                }
            }

            if !model.events.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.events.indices, id: \.self) { index in
                            Text(model.events[index])
                                .font(.system(size: 10))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(.tertiarySystemBackground), in: Capsule())
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }

            if let errorText = model.errorText {
                Text(errorText).font(.system(size: 11)).foregroundColor(.red)
                    .padding(.horizontal, 12)
            }

            HStack(spacing: 8) {
                TextField("发送消息…", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                Button {
                    model.send()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || model.running || model.loadingHistory)
            }
            .padding(10)
            .background(Color(.systemBackground))
        }
    }

    private func messageBubble(_ message: AgentMessage) -> some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 3) {
                if message.role == "system" {
                    Text(message.text)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Text(message.text.isEmpty ? "…" : message.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(10)
                        .background(bubbleColor(message),
                                    in: RoundedRectangle(cornerRadius: 12))
                    if message.attachments > 0 {
                        Text("\(message.attachments) 个附件")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }

    private func bubbleColor(_ message: AgentMessage) -> Color {
        if message.role == "user" { return Color.accentColor.opacity(0.22) }
        if message.narration { return Color(.tertiarySystemBackground) }
        return Color(.secondarySystemBackground)
    }
}

/// 对话里的一条消息。`id` 用服务端 id（本地待确认消息用临时 key）。
struct AgentMessage: Identifiable, Equatable {
    let id: String
    let role: String
    var text: String
    var attachments: Int = 0
    var narration = false
}

@MainActor
final class AgentModel: ObservableObject {
    let api: NativeApi
    let deviceId: String
    let agent: String

    var root: String { "/api/\(agent)" }
    var agentName: String { agent == "codex" ? "Codex" : "Hermes" }

    @Published var sessions: [JSONDict] = []
    @Published var selectedId: String? = nil
    @Published var selectedTitle = ""
    @Published var messages: [AgentMessage] = []
    @Published var draft = ""
    @Published var statusText = "就绪"
    @Published var errorText: String? = nil
    @Published var loadingSessions = false
    @Published var loadingHistory = false
    @Published var running = false
    @Published var events: [String] = []
    @Published var hasMoreSessions = false
    @Published var defaultModelText = "—"

    private var report: ((String) -> Void)? = nil
    private var runId: String? = nil
    private var streamTask: Task<Void, Never>? = nil
    private var cursor: String? = nil

    /// 本地待确认消息的临时 id 前缀。服务端回执后由历史刷新替换成真实行。
    private static let pendingPrefix = "local-"
    /// 流式助手气泡的固定 id，历史刷新时会被服务端真实消息替换掉。
    static let streamingId = "streaming-assistant"
    /// 最近一次发送用的幂等键。保留它只为了在轮询历史时把「本地那条」和「服务端那条」对上。
    private var pendingKey: String?

    init(api: NativeApi, deviceId: String, agent: String) {
        self.api = api
        self.deviceId = deviceId
        self.agent = agent
    }

    func attach(report: @escaping (String) -> Void) {
        self.report = report
    }

    // MARK: - 能力与模型

    func loadCapabilities() {
        let api = api
        let path = "\(root)/capabilities"
        Task {
            do {
                let result = try await api.json(path)
                let model = result.str("model")
                if !model.isEmpty {
                    defaultModelText = model
                } else if let features = result.dict("chuckie_features"), let value = features.optStr("model") {
                    defaultModelText = value
                } else {
                    defaultModelText = "由服务端决定"
                }
            } catch {
                defaultModelText = "未知（能力接口不可用）"
            }
        }
    }

    // MARK: - 会话

    func refreshSessions() {
        guard !loadingSessions else { return }
        loadingSessions = true
        let api = api
        let path = agent == "codex" ? "\(root)/sessions" : "\(root)/sessions?offset=0"
        Task {
            do {
                let result = try await api.json(path)
                sessions = result.objects("data")
                hasMoreSessions = result.bool("has_more")
                cursor = result.optStr("next_cursor")
                errorText = nil
            } catch {
                errorText = connectionFailureMessage(error)
            }
            loadingSessions = false
        }
    }

    func loadMoreSessions() {
        guard !loadingSessions else { return }
        if agent == "codex" {
            guard let cursor else { return }
            loadingSessions = true
            let api = api
            let path = "\(root)/sessions?cursor=\(urlQuery(cursor))"
            Task {
                do {
                    let result = try await api.json(path)
                    sessions += result.objects("data")
                    hasMoreSessions = result.bool("has_more")
                    self.cursor = result.optStr("next_cursor")
                } catch {
                    errorText = connectionFailureMessage(error)
                }
                loadingSessions = false
            }
        } else {
            refreshSessions()
        }
    }

    func createSession() {
        let api = api
        let path = "\(root)/sessions"
        let title = "手机对话 " + AgentModel.timestamp()
        Task {
            do {
                let result = try await api.json(path, body: ["title": title, "auto_title": true])
                let session = result.dict("session") ?? [:]
                if !session.isEmpty {
                    sessions.insert(session, at: 0)
                    select(session.str("id"), title: session.str("title", title))
                }
            } catch {
                errorText = connectionFailureMessage(error)
            }
        }
    }

    func renamePending(id: String, current: String) {
        renameRequest = InputRequest(title: "重命名会话", label: "标题", initial: current) { [weak self] value in
            self?.rename(id: id, title: value)
        }
    }

    @Published var renameRequest: InputRequest? = nil

    func rename(id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let api = api
        let path = "\(root)/sessions/\(urlQuery(id))"
        Task {
            do {
                _ = try await api.json(path, body: ["title": trimmed], method: "PATCH")
                sessions = sessions.map { row in
                    guard row.str("id") == id else { return row }
                    var updated = row
                    updated["title"] = trimmed
                    return updated
                }
                if selectedId == id { selectedTitle = trimmed }
            } catch {
                errorText = connectionFailureMessage(error)
            }
        }
    }

    func delete(_ id: String) {
        let api = api
        let path = "\(root)/sessions/\(urlQuery(id))/delete"
        Task {
            do {
                _ = try await api.json(path, body: [:])
                sessions.removeAll { $0.str("id") == id }
                if selectedId == id { closeSession() }
            } catch {
                errorText = connectionFailureMessage(error)
            }
        }
    }

    func select(_ id: String, title: String? = nil) {
        guard !id.isEmpty else { return }
        stopWatching()
        selectedId = id
        let stored = sessions.first { $0.str("id") == id }
        selectedTitle = title ?? stored?.str("title") ?? id
        messages = []
        events = []
        runId = nil
        statusText = "加载历史…"
        loadHistory()
    }

    func closeSession() {
        stopWatching()
        selectedId = nil
        selectedTitle = ""
        messages = []
        events = []
        errorText = nil
    }

    func loadHistory() {
        guard let id = selectedId, !loadingHistory else { return }
        loadingHistory = true
        let api = api
        let path = "\(root)/sessions/\(urlQuery(id))/messages?limit=100"
        Task {
            do {
                let result = try await api.json(path)
                var loaded: [AgentMessage] = result.objects("data").compactMap { row in
                    let role = row.str("role")
                    guard ["user", "assistant", "system"].contains(role) else { return nil }
                    let text = row.str("content")
                    let attachments = row.array("attachments").count
                    guard !(text.isEmpty && attachments == 0) else { return nil }
                    return AgentMessage(id: row.str("id", UUID().uuidString),
                                        role: role == "system" ? "system" : role,
                                        text: text.isEmpty ? "（附件消息）" : text,
                                        attachments: attachments,
                                        narration: row.str("type") == "toolSummary")
                }
                // 历史是权威来源。本地占位气泡（待确认的用户消息、流式助手消息）
                // 只有在「服务端历史里还没有对应内容」时才保留，避免同一条消息出现两次。
                let serverUserTexts = loaded.filter { $0.role == "user" }.map(\.text)
                let pendings = messages.filter { $0.id.hasPrefix(AgentModel.pendingPrefix) }
                let unresolved = pendings.filter { !serverUserTexts.contains($0.text) }
                if unresolved.count < pendings.count { pendingKey = nil }
                var keep = unresolved
                if running, let streaming = messages.last(where: { $0.id == AgentModel.streamingId }) {
                    keep.append(streaming)
                }
                messages = loaded + keep
                errorText = nil
                statusText = "就绪"
            } catch {
                errorText = connectionFailureMessage(error)
            }
            loadingHistory = false
        }
    }

    // MARK: - 发送与流

    func send() {
        guard let id = selectedId, !running else { return }
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let key = "mobile-\(UUID().uuidString)"
        pendingKey = key
        draft = ""
        running = true
        errorText = nil
        statusText = "正在发送…"
        events = []
        messages.append(AgentMessage(id: AgentModel.pendingPrefix + key, role: "user", text: input))

        let api = api
        let path = "\(root)/runs"
        let body: JSONDict = ["input": input, "session_id": id, "attachment_ids": []]
        Task {
            do {
                // `Idempotency-Key` 是服务端判定「重复发送」的唯一依据，必须带。
                let result = try await api.json(path, body: body,
                                               headers: ["Idempotency-Key": key])
                let delivery = result.str("delivery")
                if delivery == "rejected" || delivery == "unknown" {
                    throw ApiRequestFailure("消息是否写入尚未确认，请核对会话历史", status: 409)
                }
                let started = result.str("run_id")
                guard !started.isEmpty else {
                    throw NSError(domain: "RemoteTool", code: 9,
                                  userInfo: [NSLocalizedDescriptionKey: "服务端没有返回 run_id"])
                }
                runId = started
                let status = result.str("status")
                if ["failed", "interrupted", "cancelled", "completed"].contains(status) {
                    running = false
                    statusText = "已完成"
                    loadHistory()
                    return
                }
                statusText = "执行中"
                watch(runId: started)
            } catch is CancellationError {
                running = false
            } catch {
                running = false
                statusText = "发送失败"
                errorText = connectionFailureMessage(error)
                report?(connectionFailureMessage(error))
            }
        }
    }

    func stop() {
        guard let runId else { return }
        let api = api
        let path = "\(root)/runs/\(urlQuery(runId))/stop"
        Task {
            do {
                _ = try await api.json(path, body: [:])
                statusText = "已请求停止"
            } catch {
                errorText = connectionFailureMessage(error)
            }
        }
    }

    func stopWatching() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// 订阅 `runs/{id}/events`。SSE 断流不回退轮询 —— 事件流断了就直接刷新历史，
    /// 因为 run 的最终状态一定落在历史里（这也避免了无脑重试 404 的 run）。
    private func watch(runId: String) {
        streamTask?.cancel()
        let api = api
        let path = "\(root)/runs/\(urlQuery(runId))/events"
        streamTask = Task { [weak self] in
            var pending = ""
            do {
                for try await event in api.eventStream(path) {
                    try Task.checkCancellation()
                    guard let self, self.runId == runId else { return }
                    let kind = event.str("type", event.str("event"))
                    switch kind {
                    case "message.started":
                        if pending.isEmpty { pending = "" }
                    case "message.delta":
                        pending += event.str("delta")
                        self.upsertAssistant(pending)
                    case "message.snapshot", "message.completed":
                        pending = event.str("text")
                        self.upsertAssistant(pending)
                    case "tool.started":
                        let tool = event.str("tool")
                        let preview = event.str("preview").replacingOccurrences(of: "\n", with: " ")
                        self.appendEvent("执行中 · \(tool) \(String(preview.prefix(80)))")
                    case "tool.completed":
                        self.appendEvent("完成 · \(event.str("tool"))")
                    case "tool.failed":
                        self.appendEvent("失败 · \(event.str("tool"))")
                    case "message.interim":
                        let text = event.str("text")
                        if !text.isEmpty { self.appendEvent("进度 · \(String(text.prefix(80)))") }
                    case "approval.request":
                        self.statusText = "等待授权确认"
                    case "run.completed":
                        self.finish(runId: runId, status: "已完成")
                        return
                    case "run.failed":
                        self.finish(runId: runId, status: "执行失败")
                        return
                    case "run.cancelled", "run.interrupted":
                        self.finish(runId: runId, status: "已停止")
                        return
                    default:
                        break
                    }
                }
                // 流自然结束（服务端收起连接）时，状态以历史为准。
                guard let self, self.runId == runId else { return }
                self.finish(runId: runId, status: "已结束")
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.runId == runId else { return }
                self.errorText = connectionFailureMessage(error)
                self.finish(runId: runId, status: "事件流中断，已按历史同步")
            }
        }
    }

    private func finish(runId: String, status: String) {
        running = false
        statusText = status
        self.runId = nil
        loadHistory()
    }

    /// 增量消息始终挂在最后一条 assistant 上，直到历史刷新把它替换成服务端行。
    private func upsertAssistant(_ text: String) {
        let id = AgentModel.streamingId
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = text
        } else {
            messages.append(AgentMessage(id: id, role: "assistant", text: text))
        }
    }

    private func appendEvent(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        events.append(trimmed)
        if events.count > 30 { events.removeFirst(events.count - 30) }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}
