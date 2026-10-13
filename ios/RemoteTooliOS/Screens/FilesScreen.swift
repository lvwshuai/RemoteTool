import SwiftUI
import AVKit
import UIKit
import UniformTypeIdentifiers

/// 文件管理页。对应 Android `nativeui/FilesScreen.kt`：
/// 目录浏览 + 上传 / 下载 / 复制 / 移动 / 重命名 / 压缩 / 解压 / 删除，
/// 文本与十六进制编辑，图片与音视频预览，以及 `.git` / compose 文件的专用入口。
struct FilesScreen: View {
    let api: NativeApi
    let onError: (String) -> Void
    let onCompose: (String) -> Void

    @State private var path = ""
    @State private var inputPath = ""
    @State private var files: [JSONDict]? = nil
    @State private var loadedPath: String? = nil
    @State private var errorText: String? = nil
    @State private var reloadToken = 0

    @State private var selection: Set<String> = []
    @State private var busy = false
    @State private var operationTargets: [JSONDict] = []

    @State private var confirm: ConfirmRequest? = nil
    @State private var input: InputRequest? = nil
    @State private var document: DocumentRequest? = nil
    @State private var picker: PathPickerRequest? = nil
    @State private var media: MediaItem? = nil
    @State private var share: ShareItem? = nil
    @State private var gitJob: FileGitRequest? = nil

    @State private var showUploadPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if busy { ProgressView().padding(.vertical, 4) }

            if files == nil || loadedPath != path {
                LoadStateView(isLoading: errorText == nil,
                              error: errorText,
                              onRetry: { reloadToken += 1 }) {
                    EmptyView()
                }
                .frame(maxHeight: .infinity)
            } else {
                list
            }
        }
        .task(id: "\(path)|\(reloadToken)") { await load() }
        .confirmAlert($confirm)
        .inputSheet($input)
        .documentSheet($document)
        .pathPickerSheet($picker)
        .sheet(isPresented: $showUploadPicker) {
            DocumentPicker { urls in
                showUploadPicker = false
                upload(urls)
            } onCancel: {
                showUploadPicker = false
            }
        }
        .sheet(item: $media) { item in
            MediaViewerSheet(api: api, file: item.file) {
                media = nil
            } onDownload: {
                download(item.file)
            }
        }
        .sheet(item: $share) { item in
            ShareSheet(items: [item.url]) { share = nil }
        }
        .sheet(item: $gitJob) { request in
            FileGitSheet(api: api, request: request) {
                gitJob = nil
                reloadToken += 1
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    navigate(parentPath(path))
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(path.isEmpty)

                TextField("路径", text: $inputPath)
                    .font(.system(size: 12, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { navigate(inputPath) }

                Button {
                    navigate(inputPath)
                } label: {
                    Image(systemName: "arrow.right")
                }
                Button {
                    reloadToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }

            HStack(spacing: 12) {
                Button {
                    input = InputRequest(title: "新建文件夹", label: "服务器上的完整路径",
                                         initial: path) { destination in
                        perform { _ = try await api.json("/api/files/create-directory",
                                                          body: ["path": destination]) }
                    }
                } label: {
                    Label("新建", systemImage: "folder.badge.plus")
                }
                .disabled(busy || path.isEmpty)

                Button {
                    showUploadPicker = true
                } label: {
                    Label("上传", systemImage: "square.and.arrow.up")
                }
                .disabled(busy || path.isEmpty)

                if !selection.isEmpty {
                    Text("已选 \(selection.count)").font(.system(size: 12))
                    ForEach(["复制", "移动", "删除"], id: \.self) { name in
                        Button(name) {
                            runOperation(name, targets: selectedFiles)
                        }
                        .disabled(busy)
                    }
                    Button("取消") { selection = [] }
                }
                Spacer()
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    // MARK: - 列表

    private var list: some View {
        List {
            if let files, files.isEmpty {
                Text("此目录为空").foregroundColor(.secondary)
            }
            ForEach((files ?? []).indices, id: \.self) { index in
                row((files ?? [])[index])
            }
        }
        .listStyle(.plain)
    }

    private var selectedFiles: [JSONDict] {
        (files ?? []).filter { selection.contains($0.str("path")) }
    }

    @ViewBuilder
    private func row(_ file: JSONDict) -> some View {
        let target = file.str("path")
        let isDirectory = file.bool("isDirectory")
        HStack(spacing: 10) {
            if !selection.isEmpty {
                Button {
                    if selection.contains(target) { selection.remove(target) } else { selection.insert(target) }
                } label: {
                    Image(systemName: selection.contains(target) ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.borderless)
            } else {
                Image(systemName: fileIcon(name: file.str("name"), isDirectory: isDirectory))
                    .foregroundColor(isDirectory ? .accentColor : .secondary)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(file.str("name")).font(.system(size: 14, weight: .medium))
                Text(subtitle(file, isDirectory: isDirectory))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { open(file) }
        .contextMenu {
            menu(file, isDirectory: isDirectory)
        }
    }

    private func subtitle(_ file: JSONDict, isDirectory: Bool) -> String {
        let modified = file.keys.contains("totalBytes") ? "" : formatFileModifiedTime(file.str("modified"))
        let size: String
        if isDirectory {
            size = file.keys.contains("totalBytes")
                ? "可用 \(bytesLabel(file.dbl("freeBytes"))) / \(bytesLabel(file.dbl("totalBytes")))"
                : "文件夹"
        } else {
            size = bytesLabel(file.dbl("size"))
        }
        return modified.isEmpty ? size : size + " · " + modified
    }

    @ViewBuilder
    private func menu(_ file: JSONDict, isDirectory: Bool) -> some View {
        let name = file.str("name")
        let ext = name.components(separatedBy: ".").last?.lowercased() ?? ""

        if name.lowercased() == ".git" {
            Button("Git 状态") { git(file, action: "status") }
            Button("Git 提交并推送") { git(file, action: "commit-push") }
            Button("Git 推送") { git(file, action: "push") }
            Button("Git 拉取") { git(file, action: "pull") }
        }
        if !isDirectory, ["yml", "yaml"].contains(ext) {
            Button("Compose 管理") { onCompose(file.str("path")) }
        }
        Button("复制路径") { UIPasteboard.general.string = "\"\(file.str("path"))\""; onError("路径已复制") }
        Button("重命名") {
            input = InputRequest(title: "重命名", label: "服务器上的完整目标路径",
                                 initial: file.str("path")) { destination in
                perform { _ = try await api.json("/api/files/rename",
                                                 body: ["oldPath": file.str("path"), "newPath": destination]) }
            }
        }
        Button("复制") { runOperation("复制", targets: [file]) }
        Button("移动") { runOperation("移动", targets: [file]) }
        Button("压缩") {
            input = InputRequest(title: "压缩", label: "目标 zip 路径",
                                 initial: file.str("path") + ".zip") { destination in
                perform { _ = try await api.json("/api/files/compress",
                                                 body: ["items": [file.str("path")], "destZipPath": destination]) }
            }
        }
        if !isDirectory {
            Button("下载") { download(file) }
            Button("文本编辑") { edit(file, hex: false) }
            Button("十六进制") { edit(file, hex: true) }
        }
        if ["zip", "rar", "7z", "gz", "tar"].contains(ext) {
            Button("解压") {
                picker = PathPickerRequest(api: api, title: "解压到…", initial: path,
                                           directoryOnly: true) { destination in
                    perform { _ = try await api.json("/api/files/decompress",
                                                     body: ["archivePath": file.str("path"),
                                                            "destPath": destination]) }
                }
            }
        }
        if file.keys.contains("totalBytes") {
            Button("修改磁盘名称") {
                input = InputRequest(title: "修改磁盘名称", label: "磁盘名称",
                                     initial: name) { label in
                    perform { _ = try await api.json("/api/files/set-drive-label",
                                                     body: ["path": file.str("path"), "label": label]) }
                }
            }
        }
        Divider()
        Button("删除", role: .destructive) { runOperation("删除", targets: [file]) }
        if selection.isEmpty {
            Button("多选") { selection = [file.str("path")] }
        }
    }

    // MARK: - 打开 / 编辑 / 预览

    private func open(_ file: JSONDict) {
        let target = file.str("path")
        if !selection.isEmpty {
            if selection.contains(target) { selection.remove(target) } else { selection.insert(target) }
            return
        }
        if file.bool("isDirectory") {
            navigate(target)
            return
        }
        let name = file.str("name")
        if isComposeFile(name) {
            onCompose(target)
            return
        }
        let ext = name.components(separatedBy: ".").last?.lowercased() ?? ""
        if mediaExtensions.contains(ext) {
            media = MediaItem(file: file)
            return
        }
        edit(file, hex: false)
    }

    private func edit(_ file: JSONDict, hex: Bool) {
        let target = file.str("path")
        perform(silent: true) {
            if hex {
                let data = try await api.download("/api/files/read?binary=true&path=\(urlQuery(target))")
                guard data.count <= 2 * 1024 * 1024 else {
                    throw NSError(domain: "RemoteTool", code: 7,
                                  userInfo: [NSLocalizedDescriptionKey: "十六进制编辑最大支持 2 MB"])
                }
                document = DocumentRequest(title: "十六进制 · \(target)",
                                           text: data.map { String(format: "%02X", $0) }.joined(separator: " ")) { value in
                    saveBinary(target: target, hex: value)
                }
            } else {
                let result = try await api.json("/api/files/read?path=\(urlQuery(target))")
                document = DocumentRequest(title: target, text: result.str("data")) { value in
                    perform(silent: true) {
                        _ = try await api.json("/api/files/write", body: ["path": target, "content": value])
                        reloadToken += 1
                        onError("已保存")
                    }
                }
            }
        }
    }

    private func saveBinary(target: String, hex: String) {
        let clean = hex.components(separatedBy: .whitespacesAndNewlines).joined()
        guard clean.count % 2 == 0,
              clean.range(of: "^[0-9a-fA-F]*$", options: .regularExpression) != nil else {
            onError("请输入有效的十六进制字节")
            return
        }
        var data = Data()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            if let byte = UInt8(clean[index..<next], radix: 16) { data.append(byte) }
            index = next
        }
        perform(silent: true) {
            _ = try await api.upload("/api/files/write-binary", contentType: "application/octet-stream",
                                    body: data, query: "?path=\(urlQuery(target))")
            reloadToken += 1
            onError("已保存")
        }
    }

    // MARK: - 操作

    private func runOperation(_ name: String, targets: [JSONDict]) {
        guard !targets.isEmpty, !busy else { return }
        operationTargets = targets
        switch name {
        case "删除":
            confirm = ConfirmRequest(title: "文件操作",
                                     message: "删除 \(targets.count) 个项目？此操作无法撤销。",
                                     destructive: true) {
                perform {
                    _ = try await api.json("/api/files/delete-batch", body: ["items": itemsBody(targets)])
                    selection = []
                    reloadToken += 1
                }
            }
        case "复制", "移动":
            picker = PathPickerRequest(api: api, title: "\(name) 到…", initial: path,
                                       directoryOnly: true) { destination in
                perform {
                    let path = name == "复制" ? "/api/files/copy-batch" : "/api/files/move-batch"
                    _ = try await api.json(path, body: ["items": itemsBody(targets),
                                                        "destPath": destination,
                                                        "overwrite": false])
                    selection = []
                    reloadToken += 1
                }
            }
        default:
            break
        }
    }

    private func itemsBody(_ targets: [JSONDict]) -> [JSONDict] {
        targets.map { ["path": $0.str("path"), "isDirectory": $0.bool("isDirectory")] }
    }

    private func git(_ file: JSONDict, action: String) {
        gitJob = FileGitRequest(path: file.str("path"), action: action)
    }

    private func download(_ file: JSONDict) {
        let api = api
        let report = onError
        let name = file.str("name")
        perform {
            let data = try await api.download("/api/files/download?path=\(urlQuery(file.str("path")))")
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("RemoteToolDownloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(name.isEmpty ? "download.bin" : name)
            try data.write(to: target, options: .atomic)
            share = ShareItem(url: target)
            report("下载完成，可保存或分享")
        }
    }

    private func upload(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let api = api
        let report = onError
        let destination = path
        perform {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let name = url.lastPathComponent.isEmpty ? "upload.bin" : url.lastPathComponent
                let data = try Data(contentsOf: url)
                let boundary = "RemoteTool-\(UUID().uuidString)"
                var body = Data()
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n".data(using: .utf8)!)
                body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
                body.append(data)
                body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
                _ = try await api.upload("/api/files/upload",
                                        contentType: "multipart/form-data; boundary=\(boundary)",
                                        body: body,
                                        query: "?path=\(urlQuery(destination))")
            }
            reloadToken += 1
            report("上传完成")
        }
    }

    /// 统一的任务包装：busy 去重 + 错误上报。`silent` 用于「打开编辑器」这类不该弹提示的操作。
    private func perform(silent: Bool = false, _ action: @escaping () async throws -> Void) {
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
                if !silent { report(connectionFailureMessage(error)) }
            }
            busy = false
        }
    }

    private func navigate(_ next: String) {
        path = next
        inputPath = next
        selection = []
    }

    private func load() async {
        let api = api
        let requested = path
        do {
            let query = requested.isEmpty ? "" : "?path=\(urlQuery(requested))"
            let result = try await api.json("/api/files/list" + query)
            files = result.objects("data")
            loadedPath = requested
            if inputPath.isEmpty { inputPath = requested }
            errorText = nil
        } catch is CancellationError {
            return
        } catch {
            files = nil
            loadedPath = nil
            errorText = connectionFailureMessage(error)
        }
    }

    // MARK: - sheet 包装
}

struct MediaItem: Identifiable {
    let id = UUID()
    let file: JSONDict
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Git 操作请求（`POST /api/files/git` 返回 jobId，再轮询 `GET /api/files/git/{id}`）。
struct FileGitRequest: Identifiable {
    let id = UUID()
    let path: String
    let action: String
}

/// 对应 Android `FileGitDialog.kt`：状态查询自动执行；提交推送要求填写提交说明；
/// 失败时**不自动重试**（避免重复提交），而是提示先看仓库状态。
struct FileGitSheet: View {
    let api: NativeApi
    let request: FileGitRequest
    let onClose: () -> Void

    @State private var message = ""
    @State private var output: String? = nil
    @State private var errorText: String? = nil
    @State private var running = false
    @State private var started = false

    private var title: String {
        switch request.action {
        case "status": return "Git 状态"
        case "commit-push": return "Git 提交并推送"
        case "pull": return "Git 拉取"
        default: return "Git 推送"
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(parentPath(request.path))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)

                    if request.action == "commit-push", output == nil {
                        Text("将暂存仓库中的全部改动（包含新增、修改和删除），创建提交后推送当前分支。")
                            .font(.system(size: 12))
                        TextField("提交说明", text: $message)
                            .textFieldStyle(.roundedBorder)
                            .disabled(running)
                    }
                    if request.action == "pull" {
                        Text("拉取当前分支的上游，只允许快进；分支分叉时会提示失败。")
                            .font(.system(size: 12))
                    }
                    if running {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7)
                            Text("正在执行，请稍候…").font(.system(size: 12))
                        }
                    }
                    if let output, !output.isEmpty {
                        Text(output)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                }
                .padding(16)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onClose() }.disabled(running)
                }
                if request.action != "status" {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("执行") { execute() }
                            .disabled(running || (request.action == "commit-push" && message.trimmingCharacters(in: .whitespaces).isEmpty))
                    }
                }
            }
            .onAppear {
                if request.action == "status", !started { execute() }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func execute() {
        guard !running else { return }
        running = true
        started = true
        errorText = nil
        output = nil
        let api = api
        let request = request
        let note = message
        Task {
            do {
                let body: JSONDict = ["path": request.path, "action": request.action, "message": note]
                let result = try await api.json("/api/files/git", body: body)
                let jobId = result.str("jobId")
                guard !jobId.isEmpty else {
                    throw NSError(domain: "RemoteTool", code: 8,
                                  userInfo: [NSLocalizedDescriptionKey: "服务端没有返回任务号"])
                }
                while !Task.isCancelled {
                    let status = try await api.json("/api/files/git/\(urlQuery(jobId))")
                    if status.bool("done") {
                        let outcome = status.dict("result") ?? [:]
                        let text = outcome.str("output")
                        output = text.isEmpty ? (outcome.bool("success") ? "操作完成" : "") : text
                        if !outcome.bool("success") {
                            errorText = outcome.str("error", "Git 操作失败")
                        }
                        break
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch is CancellationError {
                running = false
                return
            } catch {
                errorText = connectionFailureMessage(error)
                    + "\n请先查看仓库状态，不要直接重复提交。"
            }
            running = false
        }
    }
}

// MARK: - 文件工具

let mediaExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "bmp",
    "mp4", "wmv", "mkv", "mov", "avi", "webm",
    "mp3", "flac", "wav", "m4v", "aac"
]

func isComposeFile(_ name: String) -> Bool {
    name.lowercased().range(of: "^(?:docker-)?compose(?:[.-].+)?\\.ya?ml$",
                            options: .regularExpression) != nil
}

func fileIcon(name: String, isDirectory: Bool) -> String {
    if isDirectory { return "folder" }
    switch name.components(separatedBy: ".").last?.lowercased() ?? "" {
    case "jpg", "jpeg", "png", "webp", "gif", "bmp": return "photo"
    case "mp4", "wmv", "mkv", "mov", "avi", "webm": return "film"
    case "mp3", "flac", "wav", "aac", "m4v": return "music.note"
    case "zip", "7z", "rar", "gz", "tar": return "doc.zipper"
    case "cs", "js", "kt", "java", "py", "sh", "ps1", "html", "css", "json", "xml", "yaml", "yml", "swift", "ts":
        return "chevron.left.forwardslash.chevron.right"
    default: return "doc.text"
    }
}

private let fileTimeFormatters: (iso: [ISO8601DateFormatter], local: DateFormatter, output: DateFormatter) = {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]

    let local = DateFormatter()
    local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    local.timeZone = .current

    let output = DateFormatter()
    output.dateFormat = "yyyy-MM-dd HH:mm"
    output.locale = Locale(identifier: "zh_CN")
    return ([withFraction, plain], local, output)
}()

/// 对应 Android `formatFileModifiedTime`：带偏移的串按 UTC 解析后转本地，无偏移的按本地解释。
func formatFileModifiedTime(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "null" { return "" }
    for parser in fileTimeFormatters.iso {
        if let date = parser.date(from: trimmed) {
            return fileTimeFormatters.output.string(from: date)
        }
    }
    if let date = fileTimeFormatters.local.date(from: trimmed) {
        return fileTimeFormatters.output.string(from: date)
    }
    // "2026-10-12T05:16:32.123" 这种没有时区但带毫秒的形态。
    if let date = fileTimeFormatters.iso[0].date(from: trimmed + "Z") {
        return fileTimeFormatters.output.string(from: date)
    }
    return ""
}

// MARK: - 系统文件选择器

/// 对应 Android 的 `ActivityResultContracts.OpenMultipleDocuments()`。
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        controller.allowsMultipleSelection = true
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

/// 对应 Android 的 `DownloadManager`：iOS 没有系统下载服务，
/// 落到临时文件后交给分享面板，用户可以「存储到文件」或直接分享给其它 App。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 媒体预览

/// 图片走带 Cookie 的 API 直出（服务端会压到最大 1920×1080 的 JPEG）；
/// 音视频先下到临时文件再交给 AVKit —— 附件播放用 AVPlayer 是正确的（与远控实时流是两套路径）。
struct MediaViewerSheet: View {
    let api: NativeApi
    let file: JSONDict
    let onClose: () -> Void
    let onDownload: () -> Void

    @State private var localURL: URL? = nil
    @State private var failed = false

    private var ext: String { file.str("name").components(separatedBy: ".").last?.lowercased() ?? "" }
    private var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "bmp"].contains(ext) }

    /// 服务端在文件列表里给了 `url` 就直接用，否则退回 `/api/files/stream`（支持 Range）。
    private var mediaPath: String {
        let advertised = file.str("url")
        if !advertised.isEmpty { return advertised }
        return "/api/files/stream?path=\(urlQuery(file.str("path")))"
    }

    var body: some View {
        NavigationView {
            Group {
                if isImage {
                    RemoteImage(path: "/api/files/preview-image?path=\(urlQuery(file.str("path")))", api: api)
                        .padding(8)
                } else if let localURL {
                    VideoPlayer(player: AVPlayer(url: localURL))
                } else if failed {
                    Text("无法加载该附件").foregroundColor(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .navigationTitle(file.str("name"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { onClose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下载") { onDownload() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task(id: file.str("path")) {
            guard !isImage else { return }
            failed = false
            do {
                let data = try await api.download(mediaPath)
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("RemoteToolMedia", isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory.appendingPathComponent(file.str("name"))
                try data.write(to: target, options: .atomic)
                localURL = target
            } catch {
                failed = true
            }
        }
    }
}
