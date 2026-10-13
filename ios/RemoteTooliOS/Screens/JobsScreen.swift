import SwiftUI

/// Hangfire 任务页。对应 Android `nativeui/JobsScreen.kt`：
/// 概览统计 + 定时/失败/执行中/排队/延迟/完成/删除/服务 八个视图 + 详情与执行日志。
struct JobsScreen: View {
    let api: NativeApi
    let onError: (String) -> Void

    private struct JobTab: Identifiable {
        let id: String
        let label: String
    }

    private let tabs = [JobTab(id: "recurring", label: "定时"),
                        JobTab(id: "failed", label: "失败"),
                        JobTab(id: "processing", label: "执行中"),
                        JobTab(id: "enqueued", label: "排队"),
                        JobTab(id: "scheduled", label: "延迟"),
                        JobTab(id: "succeeded", label: "完成"),
                        JobTab(id: "deleted", label: "删除"),
                        JobTab(id: "servers", label: "服务")]

    @State private var overview: JSONDict? = nil
    @State private var jobs: [JSONDict] = []
    @State private var errorText: String? = nil
    @State private var tab = "recurring"
    @State private var queue = "default"
    @State private var offset = 0
    @State private var reloadToken = 0
    @State private var busy = false
    @State private var confirm: ConfirmRequest? = nil
    @State private var cronRequest: InputRequest? = nil
    @State private var detailJob: JobDetailItem? = nil

    private let pageSize = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if busy { ProgressView() }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tabs) { item in
                            Button {
                                tab = item.id
                                offset = 0
                            } label: {
                                Text(item.label)
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(tab == item.id ? Color.accentColor.opacity(0.2) : Color.clear,
                                                in: Capsule())
                                    .overlay(Capsule().stroke(Color.secondary.opacity(0.35)))
                            }
                            .foregroundColor(tab == item.id ? .accentColor : .secondary)
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack {
                    Text("Hangfire").font(.system(size: 15, weight: .medium))
                    Spacer()
                    Button {
                        reloadToken += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }

                if let stats = overview?.dict("stats") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(statsChips(stats)) { chip in
                                Button {
                                    tab = chip.id
                                    offset = 0
                                } label: {
                                    Text(chip.label)
                                        .font(.system(size: 12))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color(.tertiarySystemBackground), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if let errorText {
                    Text(errorText).font(.system(size: 12)).foregroundColor(.red)
                }

                if tab == "recurring" {
                    let recurring = overview?.objects("recurring") ?? []
                    ForEach(recurring.indices, id: \.self) { index in
                        recurringCard(recurring[index])
                    }
                } else if tab == "servers" {
                    let servers = overview?.objects("servers") ?? []
                    let queues = overview?.objects("queues") ?? []
                    ForEach(servers.indices, id: \.self) { index in
                        infoCard(servers[index])
                    }
                    ForEach(queues.indices, id: \.self) { index in
                        infoCard(queues[index])
                    }
                } else {
                    if tab == "enqueued" {
                        TextField("队列名称", text: $queue)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { offset = 0 }
                    }
                    ForEach(jobs.indices, id: \.self) { index in
                        jobCard(jobs[index])
                    }
                    HStack {
                        Button("上一页") { offset = max(offset - pageSize, 0) }
                            .disabled(offset == 0)
                        Text("第 \(offset / pageSize + 1) 页").font(.system(size: 12))
                        Button("下一页") { offset += pageSize }
                            .disabled(jobs.count < pageSize)
                    }
                }
            }
            .padding(16)
        }
        .task(id: "\(tab)|\(offset)|\(reloadToken)|\(queue)") { await load() }
        .confirmAlert($confirm)
        .inputSheet($cronRequest)
        .sheet(item: $detailJob) { item in
            JobDetailsSheet(api: api, jobId: item.id) {
                detailJob = nil
                reloadToken += 1
            }
        }
    }

    private struct StatChip: Identifiable {
        let id: String
        let label: String
    }

    private func statsChips(_ stats: JSONDict) -> [StatChip] {
        [StatChip(id: "enqueued", label: "排队"),
         StatChip(id: "processing", label: "执行"),
         StatChip(id: "failed", label: "失败"),
         StatChip(id: "succeeded", label: "完成"),
         StatChip(id: "scheduled", label: "延迟")]
            .map { StatChip(id: $0.id, label: "\($0.label) \(stats.int($0.id))") }
    }

    // MARK: - 卡片

    private func recurringCard(_ job: JSONDict) -> some View {
        let id = job.str("id")
        let lastState = job.str("lastJobState")
        return VStack(alignment: .leading, spacing: 6) {
            Text(id).font(.system(size: 15, weight: .medium))
            Text("\(job.str("cron")) · \(job.str("timeZoneId"))")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Text("下次（手机时间）：\(displayTime(job.str("nextExecution")))")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Text("最近状态：\(lastState.isEmpty || lastState == "null" ? "尚未执行" : lastState)")
                .font(.system(size: 11)).foregroundColor(.secondary)
            let jobError = job.str("error")
            if !jobError.isEmpty, jobError != "null" {
                Text(jobError).font(.system(size: 11)).foregroundColor(.red)
            }
            HStack(spacing: 10) {
                let lastJobId = job.str("lastJobId")
                if !lastJobId.isEmpty, lastJobId != "null" {
                    Button("上次执行 / 日志") { detailJob = JobDetailItem(id: lastJobId) }
                        .font(.system(size: 12))
                }
                Button("立即执行") {
                    confirm = ConfirmRequest(title: "任务操作", message: "立即触发 \(id)？") {
                        action("/api/job/\(urlQuery(id))/trigger")
                    }
                }
                .font(.system(size: 12))
                Button("修改计划") {
                    cronRequest = InputRequest(title: "修改 Cron", label: "Cron 表达式",
                                               initial: job.str("cron")) { value in
                        confirm = ConfirmRequest(title: "任务操作",
                                                 message: "将 \(id) 的计划修改为 \(value)？") {
                            action("/api/native-jobs/recurring/\(urlQuery(id))/update",
                                   body: ["cron": value, "timeZoneId": job.str("timeZoneId")])
                        }
                    }
                }
                .font(.system(size: 12))
                Button("删除") {
                    confirm = ConfirmRequest(title: "任务操作",
                                             message: "移除定时任务 \(id)？",
                                             destructive: true) {
                        action("/api/native-jobs/recurring/\(urlQuery(id))/delete")
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(.red)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func jobCard(_ job: JSONDict) -> some View {
        let id = job.str("id")
        return VStack(alignment: .leading, spacing: 6) {
            Text("# \(id)").font(.system(size: 15, weight: .medium))
            Text(job.str("type") + "." + job.str("method"))
                .font(.system(size: 11)).foregroundColor(.secondary)
            HStack(spacing: 10) {
                Button("详情 / 日志") { detailJob = JobDetailItem(id: id) }
                    .font(.system(size: 12))
                Button("重试") {
                    confirm = ConfirmRequest(title: "任务操作", message: "重新排队任务 \(id)？") {
                        action("/api/native-jobs/jobs/\(urlQuery(id))/retry")
                    }
                }
                .font(.system(size: 12))
                Button("删除") {
                    confirm = ConfirmRequest(title: "任务操作", message: "删除任务 \(id)？",
                                             destructive: true) {
                        action("/api/native-jobs/jobs/\(urlQuery(id))/delete")
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(.red)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func infoCard(_ object: JSONDict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(object.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top, spacing: 8) {
                    Text(key).font(.system(size: 11)).foregroundColor(.secondary)
                        .frame(width: 110, alignment: .leading)
                    Text(render(object[key]))
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func render(_ value: Any?) -> String {
        guard let value else { return "未设置" }
        if value is NSNull { return "未设置" }
        if let array = value as? [Any] {
            return array.prefix(20).map { "\($0)" }.joined(separator: "、")
        }
        if let object = value as? JSONDict {
            return object.keys.sorted().map { "\($0)=\(object[$0] ?? "")" }.joined(separator: ", ")
        }
        return "\(value)"
    }

    // MARK: - 请求

    private func load() async {
        let api = api
        do {
            overview = try await api.json("/api/native-jobs/overview")
            if tab != "recurring", tab != "servers" {
                let result = try await api.json("/api/native-jobs/jobs?state=\(urlQuery(tab))&queue=\(urlQuery(queue))&offset=\(offset)&count=\(pageSize)")
                jobs = result.objects("data")
            }
            errorText = nil
        } catch is CancellationError {
            return
        } catch {
            errorText = connectionFailureMessage(error)
        }
    }

    private func action(_ path: String, body: JSONDict = [:]) {
        guard !busy else { return }
        busy = true
        let api = api
        let report = onError
        Task {
            do {
                _ = try await api.json(path, body: body)
                reloadToken += 1
            } catch is CancellationError {
                busy = false
                return
            } catch {
                report(connectionFailureMessage(error))
            }
            busy = false
        }
    }
}

struct JobDetailItem: Identifiable {
    let id: String
}

/// 任务详情 + 执行日志。对应 Android `JobDetailsDialog.kt` 的核心部分：
/// 详情字段 / 参数展开 / 历史状态 / Hangfire.Console 的分页日志。
struct JobDetailsSheet: View {
    let api: NativeApi
    let jobId: String
    let onClose: () -> Void

    @State private var detail: JSONDict? = nil
    @State private var lines: [JSONDict] = []
    @State private var attempt: String? = nil
    @State private var nextOffset = 0
    @State private var total = 0
    @State private var hasMore = false
    @State private var errorText: String? = nil
    @State private var loading = false

    var body: some View {
        NavigationView {
            List {
                if let detail {
                    Section(header: Text("任务")) {
                        KeyValue(detail.str("id"), "任务号")
                        KeyValue(detail.str("type") + "." + detail.str("method"), "方法")
                        KeyValue(detail.str("state"), "当前状态")
                        KeyValue(detail.str("queue"), "队列")
                        KeyValue(displayTime(detail.str("createdAt")), "创建时间")
                        KeyValue(displayTime(detail.str("expireAt")), "过期时间")
                    }

                    let parameters = detail.objects("parameters")
                    if !parameters.isEmpty {
                        Section(header: Text("参数")) {
                            ForEach(parameters.indices, id: \.self) { index in
                                let parameter = parameters[index]
                                KeyValue(describe(parameter["value"]),
                                         "\(parameter.str("name")) : \(parameter.str("type"))")
                            }
                        }
                    }

                    let history = detail.objects("history")
                    if !history.isEmpty {
                        Section(header: Text("状态历史")) {
                            ForEach(history.indices, id: \.self) { index in
                                let row = history[index]
                                KeyValue(displayTime(row.str("createdAt")), row.str("stateName", "—"))
                            }
                        }
                    }
                }

                Section(header: Text("执行日志\(total > 0 ? "（\(total) 行）" : "")")) {
                    if loading && lines.isEmpty {
                        ProgressView()
                    }
                    if lines.isEmpty && !loading {
                        Text("暂无日志").foregroundColor(.secondary)
                    }
                    ForEach(lines.indices, id: \.self) { index in
                        let line = lines[index]
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(line.int("index"))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(line.str("text"))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if hasMore {
                        Button("载入更早的日志") { loadConsole(older: true) }
                            .font(.system(size: 12))
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).font(.system(size: 12)).foregroundColor(.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("任务详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onClose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        loadDetail()
                        loadConsole(older: false)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                loadDetail()
                loadConsole(older: false)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func describe(_ value: Any?) -> String {
        guard let value else { return "未设置" }
        if value is NSNull { return "未设置" }
        if let array = value as? [Any] { return array.prefix(20).map { "\($0)" }.joined(separator: "、") }
        if let object = value as? JSONDict {
            return object.keys.sorted().map { "\($0)=\(object[$0] ?? "")" }.joined(separator: ", ")
        }
        return "\(value)"
    }

    private func loadDetail() {
        let api = api
        let id = jobId
        Task {
            do {
                detail = try await api.json("/api/native-jobs/jobs/\(urlQuery(id))")
                errorText = nil
            } catch {
                errorText = connectionFailureMessage(error)
            }
        }
    }

    private func loadConsole(older: Bool) {
        guard !loading else { return }
        loading = true
        let api = api
        let id = jobId
        let currentAttempt = attempt
        let requestOffset = older ? nextOffset : 0
        Task {
            do {
                var path = "/api/native-jobs/jobs/\(urlQuery(id))/console?count=200&offset=\(requestOffset)"
                if let currentAttempt { path += "&attempt=\(urlQuery(currentAttempt))" }
                let page = try await api.json(path)
                attempt = page.optStr("attempt")
                nextOffset = page.int("nextOffset")
                total = page.int("total")
                hasMore = page.bool("hasMore")
                let fresh = page.objects("data")
                if older, !page.bool("reset") {
                    lines = merge(lines, fresh)
                } else {
                    lines = merge([], fresh)
                }
                errorText = nil
            } catch {
                errorText = connectionFailureMessage(error)
            }
            loading = false
        }
    }

    /// 与 Android `JobConsoleBuffer.merge` 同语义：按 `index` 去重后重新排序，保留最近 2000 行。
    private func merge(_ previous: [JSONDict], _ fresh: [JSONDict]) -> [JSONDict] {
        var map: [Int: JSONDict] = [:]
        for row in previous + fresh { map[row.int("index")] = row }
        return map.keys.sorted().compactMap { map[$0] }.suffix(2000).map { $0 }
    }
}

private struct KeyValue: View {
    let value: String
    let label: String

    init(_ value: String, _ label: String) {
        self.value = value
        self.label = label
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
