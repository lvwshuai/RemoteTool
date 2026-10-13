import SwiftUI

/// 通用弹层。
///
/// Android 侧对这些交互用的是 `AlertDialog` / `ModalBottomSheet` / `DropdownMenu`
/// 三种组合。SwiftUI 里同一套语义可以更集中地表达，所以这里做成
/// 「一个 Identifiable 请求 + 一个 ViewModifier」的形式，页面只负责状态流转。

// MARK: - 破坏性操作确认

struct ConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var destructive = false
    let action: () -> Void

    init(title: String, message: String, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.destructive = destructive
        self.action = action
    }
}

private struct ConfirmAlertModifier: ViewModifier {
    @Binding var request: ConfirmRequest?

    func body(content: Content) -> some View {
        content.alert(request?.title ?? "",
                      isPresented: Binding(get: { request != nil },
                                           set: { if !$0 { request = nil } }),
                      presenting: request) { item in
            Button("确认", role: item.destructive ? .destructive : nil) {
                let run = item.action
                request = nil
                run()
            }
            Button("取消", role: .cancel) { request = nil }
        } message: { item in
            Text(item.message)
        }
    }
}

extension View {
    func confirmAlert(_ request: Binding<ConfirmRequest?>) -> some View {
        modifier(ConfirmAlertModifier(request: request))
    }
}

// MARK: - 单行 / 多行输入

struct InputRequest: Identifiable {
    let id = UUID()
    let title: String
    let label: String
    let initial: String
    var multiline = false
    let submit: (String) -> Void

    init(title: String, label: String, initial: String, multiline: Bool = false,
         submit: @escaping (String) -> Void) {
        self.title = title
        self.label = label
        self.initial = initial
        self.multiline = multiline
        self.submit = submit
    }
}

private struct InputSheet: View {
    let request: InputRequest
    let onClose: () -> Void

    @State private var value: String

    init(request: InputRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _value = State(initialValue: request.initial)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField(request.label, text: $value)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .lineLimit(request.multiline ? 6...12 : 1...1)
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onClose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let submitted = value
                        onClose()
                        request.submit(submitted)
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct InputSheetModifier: ViewModifier {
    @Binding var request: InputRequest?

    func body(content: Content) -> some View {
        content.sheet(item: $request) { item in
            InputSheet(request: item) { request = nil }
        }
    }
}

extension View {
    func inputSheet(_ request: Binding<InputRequest?>) -> some View {
        modifier(InputSheetModifier(request: request))
    }
}

// MARK: - 文本 / 十六进制编辑

struct DocumentRequest: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    var editable = true
    var monospaced = true
    var onSave: ((String) -> Void)?

    init(title: String, text: String, editable: Bool = true, monospaced: Bool = true,
         onSave: ((String) -> Void)? = nil) {
        self.title = title
        self.text = text
        self.editable = editable
        self.monospaced = monospaced
        self.onSave = onSave
    }
}

struct TextDocumentSheet: View {
    let request: DocumentRequest
    let onClose: () -> Void

    @State private var value: String

    init(request: DocumentRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _value = State(initialValue: request.text)
    }

    var body: some View {
        NavigationView {
            Group {
                if request.editable {
                    TextEditor(text: $value)
                        .font(.system(size: 12, design: request.monospaced ? .monospaced : .default))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                } else {
                    ScrollView {
                        Text(value.isEmpty ? "（空）" : value)
                            .font(.system(size: 12, design: request.monospaced ? .monospaced : .default))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(request.onSave == nil ? "关闭" : "取消") { onClose() }
                }
                if let save = request.onSave {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            let submitted = value
                            onClose()
                            save(submitted)
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct DocumentSheetModifier: ViewModifier {
    @Binding var request: DocumentRequest?

    func body(content: Content) -> some View {
        content.sheet(item: $request) { item in
            TextDocumentSheet(request: item) { request = nil }
        }
    }
}

extension View {
    func documentSheet(_ request: Binding<DocumentRequest?>) -> some View {
        modifier(DocumentSheetModifier(request: request))
    }
}

// MARK: - 服务器路径选择器

struct PathPickerRequest: Identifiable {
    let id = UUID()
    let api: NativeApi
    let title: String
    let initial: String
    let directoryOnly: Bool
    let select: (String) -> Void

    init(api: NativeApi, title: String, initial: String, directoryOnly: Bool,
         select: @escaping (String) -> Void) {
        self.api = api
        self.title = title
        self.initial = initial
        self.directoryOnly = directoryOnly
        self.select = select
    }
}

/// 与 Android `PathPicker.kt` 对应的服务器路径浏览器。
/// 目录树来自 `/api/files/list`，只做「选一个路径并把结果交给调用方」这一件事。
struct PathPickerSheet: View {
    let request: PathPickerRequest
    let onClose: () -> Void

    @State private var path: String
    @State private var entries: [PathEntry] = []
    @State private var loading = false
    @State private var errorText: String?

    private struct PathEntry: Identifiable {
        let id: String
        let name: String
        let target: String
        let isDirectory: Bool
    }

    init(request: PathPickerRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _path = State(initialValue: request.initial)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        path = parentPath(path)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .disabled(path.isEmpty)
                    TextField("路径", text: $path)
                        .font(.system(size: 12, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onSubmit { load() }
                    Button("前往") { load() }
                }
                .padding(12)

                if loading {
                    ProgressView().padding()
                }
                if let errorText {
                    Text(errorText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                }
                List {
                    ForEach(entries) { entry in
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                .foregroundColor(entry.isDirectory ? .accentColor : .secondary)
                            Text(entry.name).font(.system(size: 13))
                            Spacer()
                            if entry.isDirectory {
                                Button("进入") {
                                    path = entry.target
                                    load()
                                }
                                .font(.system(size: 12))
                            } else if !request.directoryOnly {
                                Button("选择") {
                                    let selected = entry.target
                                    onClose()
                                    request.select(selected)
                                }
                                .font(.system(size: 12))
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onClose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("选此目录") {
                        let selected = path
                        onClose()
                        request.select(selected)
                    }
                }
            }
            .onAppear { load() }
        }
        .navigationViewStyle(.stack)
    }

    private func load() {
        loading = true
        errorText = nil
        let api = request.api
        let target = path
        Task {
            do {
                let query = target.isEmpty ? "" : "?path=\(urlQuery(target))"
                let data = try await api.json("/api/files/list" + query)
                entries = data.objects("data").map {
                    PathEntry(id: $0.str("path"),
                              name: $0.str("name", "未命名"),
                              target: $0.str("path"),
                              isDirectory: $0.bool("isDirectory"))
                }
                errorText = nil
            } catch {
                entries = []
                errorText = connectionFailureMessage(error)
            }
            loading = false
        }
    }
}

private struct PathPickerModifier: ViewModifier {
    @Binding var request: PathPickerRequest?

    func body(content: Content) -> some View {
        content.sheet(item: $request) { item in
            PathPickerSheet(request: item) { request = nil }
        }
    }
}

extension View {
    func pathPickerSheet(_ request: Binding<PathPickerRequest?>) -> some View {
        modifier(PathPickerModifier(request: request))
    }
}

// MARK: - 路径工具

/// 与 Android `FilesScreen.parentPath` 逐字对齐：保留结尾分隔符，方便直接作为目录使用。
func parentPath(_ path: String) -> String {
    let chars = Array(path)
    var end = chars.count
    while end > 0, chars[end - 1] == "/" || chars[end - 1] == "\\" { end -= 1 }
    var index = -1
    var cursor = end - 1
    while cursor >= 0 {
        if chars[cursor] == "/" || chars[cursor] == "\\" { index = cursor; break }
        cursor -= 1
    }
    if index < 0 { return "" }
    return String(chars[0...index])
}
