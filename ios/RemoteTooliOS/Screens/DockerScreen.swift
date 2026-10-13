import SwiftUI

/// Docker 管理页。对应 Android `nativeui/DockerScreen.kt`：
/// 容器（启停 / 日志 / 删除）、镜像（拉取 / 检查更新）、Compose（读改验证 / 流式执行）。
struct DockerScreen: View {
    let api: NativeApi
    let onError: (String) -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case containers, images, compose

        var id: String { rawValue }

        var title: String {
            switch self {
            case .containers: return "容器"
            case .images: return "镜像"
            case .compose: return "Compose"
            }
        }
    }

    @State private var tab: Tab = .containers
    @State private var items: [JSONDict]? = nil
    @State private var errorText: String? = nil
    @State private var reloadToken = 0
    @State private var busy = false
    @State private var confirm: ConfirmRequest? = nil
    @State private var document: DocumentRequest? = nil
    @State private var imageTag = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Tab.allCases) { item in
                    Button {
                        tab = item
                        items = nil
                    } label: {
                        Text(item.title)
                            .font(.system(size: 13, weight: tab == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundColor(tab == item ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(.systemBackground))
            Divider()

            if busy { ProgressView().padding(.vertical, 4) }

            if tab == .compose {
                ComposeScreen(api: api, onError: onError, initialPath: nil)
            } else {
                list
            }
        }
        .task(id: "\(tab.rawValue)|\(reloadToken)") { await load() }
        .confirmAlert($confirm)
        .documentSheet($document)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Text("\(items?.count ?? 0) 个\(tab == .containers ? "容器" : "镜像")")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Button {
                        reloadToken += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }

                if tab == .images {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("镜像名称，如 nginx:latest", text: $imageTag)
                            .font(.system(size: 13, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        Button {
                            let tag = imageTag
                            confirm = ConfirmRequest(title: "Docker 操作", message: "拉取 \(tag)？") {
                                perform { _ = try await api.json("/api/docker/images/pull",
                                                                 body: ["imageTag": tag]) }
                            }
                        } label: {
                            Text("拉取镜像").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(imageTag.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }

                if items == nil {
                    LoadStateView(isLoading: errorText == nil,
                                  error: errorText,
                                  onRetry: { reloadToken += 1 }) {
                        EmptyView()
                    }
                    .frame(height: 140)
                } else if tab == .containers {
                    ForEach((items ?? []).indices, id: \.self) { index in
                        containerCard((items ?? [])[index])
                    }
                } else {
                    ForEach((items ?? []).indices, id: \.self) { index in
                        imageCard((items ?? [])[index])
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - 容器

    private func containerCard(_ item: JSONDict) -> some View {
        let id = item.str("id")
        let running = item.str("state") == "running"
        return VStack(alignment: .leading, spacing: 8) {
            Text(item.str("names", id)).font(.system(size: 15, weight: .medium))
            Text(item.str("image")).font(.system(size: 11)).foregroundColor(.secondary)
            Text(item.str("status"))
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
            if !item.str("ports").isEmpty {
                Text(item.str("ports")).font(.system(size: 11)).foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                Button(running ? "停止" : "启动") {
                    confirm = ConfirmRequest(title: "Docker 操作",
                                             message: "\(running ? "停止" : "启动")此容器？") {
                        perform {
                            _ = try await api.json("/api/docker/containers/\(urlQuery(id))/\(running ? "stop" : "start")",
                                                   body: [:])
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(busy)

                Button("日志") { showLogs(item) }
                    .buttonStyle(.bordered)

                Button {
                    confirm = ConfirmRequest(title: "Docker 操作",
                                             message: "删除容器 \(item.str("names"))？",
                                             destructive: true) {
                        perform {
                            _ = try await api.json("/api/docker/containers/\(urlQuery(id))", body: [:])
                        }
                    }
                } label: {
                    Image(systemName: "trash").foregroundColor(.red)
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func showLogs(_ item: JSONDict) {
        let api = api
        let report = onError
        let id = item.str("id")
        let title = item.str("names", id)
        busy = true
        Task {
            do {
                let result = try await api.json("/api/docker/containers/\(urlQuery(id))/logs?lines=500")
                document = DocumentRequest(title: "\(title) · 日志",
                                           text: result.str("logs"),
                                           editable: false)
            } catch {
                report(connectionFailureMessage(error))
            }
            busy = false
        }
    }

    // MARK: - 镜像

    private func imageCard(_ item: JSONDict) -> some View {
        let tag = item.str("repository") + ":" + item.str("tag")
        return VStack(alignment: .leading, spacing: 6) {
            Text(tag).font(.system(size: 14, weight: .medium))
            Text(item.str("size") + " · " + item.str("created"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            HStack(spacing: 10) {
                Button("检查更新") {
                    perform {
                        let result = try await api.json("/api/docker/images/check-update",
                                                        body: ["imageTag": tag])
                        onError(result.bool("hasUpdate") ? "有可用更新" : "当前镜像没有更新")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                Button("拉取") {
                    confirm = ConfirmRequest(title: "Docker 操作", message: "拉取 \(tag)？") {
                        perform { _ = try await api.json("/api/docker/images/pull", body: ["imageTag": tag]) }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(busy)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 请求

    private func load() async {
        guard tab != .compose else { return }
        let api = api
        do {
            let path = tab == .containers ? "/api/docker/containers" : "/api/docker/images"
            let result = try await api.json(path)
            items = result.objects("data")
            errorText = nil
        } catch is CancellationError {
            return
        } catch {
            items = nil
            errorText = connectionFailureMessage(error)
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        let report = onError
        Task {
            do {
                try await action()
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

// MARK: - Compose

/// Compose 管理。对应 Android `ComposeScreen`：
/// 读取 / 校验 / 保存 YAML，`up|pull|stop|down` 走流式接口并把输出实时贴到界面上。
struct ComposeScreen: View {
    let api: NativeApi
    let onError: (String) -> Void
    let initialPath: String?

    @State private var path = ""
    @State private var content = ""
    @State private var projects: [JSONDict] = []
    @State private var busy = false
    @State private var confirm: ConfirmRequest? = nil
    @State private var picker: PathPickerRequest? = nil
    @State private var selectedProject: String? = nil
    @State private var document: DocumentRequest? = nil

    private struct Action: Identifiable {
        let id: String
        let label: String
    }

    private let actions = [Action(id: "up", label: "启动"),
                           Action(id: "pull", label: "拉取"),
                           Action(id: "stop", label: "停止"),
                           Action(id: "down", label: "移除项目")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let selectedProject {
                    Text("正在管理：\(selectedProject)").font(.system(size: 14, weight: .medium))
                }

                TextField("服务器上的 Compose 文件路径", text: $path)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .disabled(busy)

                HStack(spacing: 10) {
                    Button {
                        picker = PathPickerRequest(api: api, title: "选择 Compose 配置",
                                                   initial: parentPath(path),
                                                   directoryOnly: false) { target in
                            openFile(target)
                        }
                    } label: {
                        Label("浏览配置文件", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)

                    Button("读取") { openFile(path, keepProject: true) }
                        .buttonStyle(.bordered)
                        .disabled(busy || path.isEmpty)

                    Button("验证") { validate() }
                        .buttonStyle(.bordered)
                        .disabled(busy || content.isEmpty)

                    Button("保存") {
                        confirm = ConfirmRequest(title: "Compose",
                                                 message: "保存文件：\(path)？") {
                            let api = api
                            let report = onError
                            task {
                                _ = try await api.json("/api/docker/compose/write",
                                                       body: ["path": path, "content": content])
                                report("已保存")
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || path.isEmpty)
                }

                TextEditor(text: $content)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 300)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                    .disabled(busy)

                HStack(spacing: 10) {
                    ForEach(actions) { action in
                        Button(action.label) {
                            confirm = ConfirmRequest(title: "Compose",
                                                     message: "执行 \(action.id)：\(path)？") {
                                runStream(action.id)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy || path.isEmpty)
                    }
                }

                if busy { ProgressView() }

                ForEach(projects.indices, id: \.self) { index in
                    let project = projects[index]
                    Button {
                        let config = project.str("configFiles")
                            .components(separatedBy: ",")
                            .first?
                            .trimmingCharacters(in: .whitespaces) ?? ""
                        if config.isEmpty {
                            onError("此项目没有可读取的配置文件路径")
                        } else {
                            openFile(config, project: project.str("name"))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.str("name")).font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                            Text(project.str("status")).font(.system(size: 11)).foregroundColor(.secondary)
                            Text(project.str("configFiles")).font(.system(size: 11)).foregroundColor(.secondary)
                            Text("点击读取配置并管理").font(.system(size: 11)).foregroundColor(.accentColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }
            .padding(16)
        }
        .task { await loadProjects() }
        .onAppear {
            if let initialPath, !initialPath.isEmpty, path.isEmpty {
                openFile(initialPath)
            }
        }
        .confirmAlert($confirm)
        .pathPickerSheet($picker)
        .documentSheet($document)
    }

    private func loadProjects() async {
        let api = api
        do {
            let result = try await api.json("/api/docker/compose/status")
            projects = result.objects("data")
        } catch is CancellationError {
            return
        } catch {
            onError(connectionFailureMessage(error))
        }
    }

    private func openFile(_ target: String, project: String? = nil, keepProject: Bool = false) {
        guard !target.isEmpty else { return }
        task {
            path = target
            if !keepProject { selectedProject = project }
            let result = try await api.json("/api/docker/compose/read?path=\(urlQuery(target))")
            content = result.str("content")
        }
    }

    private func validate() {
        task {
            let result = try await api.json("/api/docker/compose/validate",
                                            body: ["path": path, "content": content])
            onError(result.str("message", "验证通过"))
        }
    }

    /// 流式执行：把 stdout 实时累积，结束后弹成只读文档。
    /// 长任务（pull）必须流式，否则要等命令跑完才看得到任何东西。
    private func runStream(_ action: String) {
        guard !busy else { return }
        busy = true
        let api = api
        let report = onError
        let buffer = StreamBuffer()
        Task {
            do {
                try await api.stream("/api/docker/compose/\(action)/stream",
                                     body: ["composePath": path]) { chunk in
                    buffer.append(chunk)
                }
            } catch is CancellationError {
                busy = false
                return
            } catch {
                report(connectionFailureMessage(error))
            }
            busy = false
            document = DocumentRequest(title: "Compose 输出", text: buffer.text, editable: false)
            await loadProjects()
        }
    }

    private func task(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        let report = onError
        Task {
            do {
                try await action()
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
