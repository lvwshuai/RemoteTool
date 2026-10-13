import SwiftUI

/// 进程管理页。对应 Android `SystemScreens.kt` 的 `ProcessScreen`：
/// 搜索（名称 / PID / 描述）+ 按内存占用倒序 + 结束进程。
struct ProcessesScreen: View {
    let api: NativeApi
    let onError: (String) -> Void

    @State private var processes: [JSONDict]? = nil
    @State private var errorText: String? = nil
    @State private var query = ""
    @State private var reloadToken = 0
    @State private var killConfirm: ConfirmRequest? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索名称或 PID", text: $query)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                Button {
                    reloadToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))

            if processes == nil {
                LoadStateView(isLoading: errorText == nil,
                              error: errorText,
                              onRetry: { reloadToken += 1 }) {
                    EmptyView()
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(filtered.indices, id: \.self) { index in
                        let process = filtered[index]
                        processRow(process)
                    }
                }
                .listStyle(.plain)
            }
        }
        .task(id: reloadToken) { await load() }
        .confirmAlert($killConfirm)
    }

    private var filtered: [JSONDict] {
        let all = processes ?? []
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = needle.isEmpty ? all : all.filter {
            ($0.str("name") + "\($0.int("id"))" + $0.str("description"))
                .lowercased()
                .contains(needle)
        }
        return matched.sorted { $0.dbl("memoryMB") > $1.dbl("memoryMB") }
    }

    private func processRow(_ process: JSONDict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(process.str("name")).font(.system(size: 15, weight: .medium))
                Spacer()
                Button {
                    killConfirm = ConfirmRequest(
                        title: "结束进程",
                        message: "结束 \(process.str("name"))（PID \(process.int("id"))）？",
                        destructive: true) {
                            kill(process)
                        }
                } label: {
                    Image(systemName: "stop.circle").foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
            Text("PID \(process.int("id")) · \(Int(process.dbl("memoryMB"))) MB · CPU \(String(format: "%.1f", process.dbl("cpuPercent")))%")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if !process.str("windowTitle").isEmpty {
                Text(process.str("windowTitle"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        let api = api
        do {
            let result = try await api.json("/api/system/processes")
            processes = result.objects("data")
            errorText = nil
        } catch is CancellationError {
            return
        } catch {
            errorText = connectionFailureMessage(error)
        }
    }

    private func kill(_ process: JSONDict) {
        let api = api
        let report = onError
        let pid = process.int("id")
        Task {
            do {
                _ = try await api.json("/api/system/kill/\(pid)", body: [:])
                reloadToken += 1
            } catch {
                report(connectionFailureMessage(error))
            }
        }
    }
}
