import SwiftUI

/// 已登录后的主界面。对应 Android `NativeApp.kt` 的 `Scaffold`：
/// 顶部标题栏（设备名 · 当前通道延时）+ 底部五个标签（系统 / 远程 / Codex / Hermes / 更多）
/// + 二级页面路由（进程 / 终端 / 文件 / Docker / Compose / Hangfire）。
struct HomeScreen: View {
    let session: Session
    let onOpenRemote: () -> Void

    @EnvironmentObject private var model: NativeModel

    @State private var route: HomeRoute = .system
    @State private var detail: DetailRoute?

    init(session: Session, onOpenRemote: @escaping () -> Void) {
        self.session = session
        self.onOpenRemote = onOpenRemote
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if detail == nil {
                Divider()
                bottomBar
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onChange(of: session.api.base) { _ in detail = nil }
    }

    // MARK: - 顶部

    private var titleText: String {
        if let detail { return detail.title }
        return route.title
    }

    private var latencyText: String {
        let ms = session.channels.first { $0.url == session.api.base }?.ms
        return session.device.name + " · " + (ms.map { "\($0) ms" } ?? "当前通道")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if detail != nil || model.browsingDevices {
                Button {
                    if model.browsingDevices { model.returnToDevice() } else { detail = nil }
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText).font(.system(size: 19, weight: .semibold))
                Text(latencyText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                model.openChannels(session.device)
            } label: {
                Image(systemName: "arrow.triangle.branch")
            }
            Button {
                model.showDevices()
            } label: {
                Image(systemName: "rectangle.2.swap")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    // MARK: - 内容路由

    @ViewBuilder
    private var content: some View {
        let api = session.api
        let report: (String) -> Void = { model.report($0) }

        if let detail {
            switch detail {
            case .processes:
                ProcessesScreen(api: api, onError: report)
            case .terminal:
                TerminalScreen(api: api, onError: report)
            case .files:
                FilesScreen(api: api, onError: report) { path in
                    self.detail = .compose(path)
                }
            case .docker:
                DockerScreen(api: api, onError: report)
            case .compose(let path):
                ComposeScreen(api: api, onError: report, initialPath: path)
            case .jobs:
                JobsScreen(api: api, onError: report)
            }
        } else {
            switch route {
            case .system:
                SystemScreen(api: api,
                             onProcesses: { self.detail = .processes },
                             onTerminal: { self.detail = .terminal },
                             onError: report)
            case .remote:
                remoteEntry
            case .codex:
                AgentScreen(api: api, deviceId: session.device.id, agent: "codex", onError: report)
            case .hermes:
                AgentScreen(api: api, deviceId: session.device.id, agent: "hermes", onError: report)
            case .more:
                moreList(api: api)
            }
        }
    }

    private var remoteEntry: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "display")
                    .font(.system(size: 44))
                    .foregroundColor(.accentColor)
                Text("远程桌面").font(.system(size: 26, weight: .semibold))
                Text("H.264 硬件解码 · 全屏控制\n直接触控与触控板 · 手机输入法\n双指缩放，放大后拖动画面")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Button(action: onOpenRemote) {
                    Text("连接远程桌面").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Text("点击连接后才启动视频和键鼠通道。Linux 主机不提供远程桌面，会返回 503。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func moreList(api: NativeApi) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                ToolRow(title: "文件管理", subtitle: "浏览 · 传输 · 图片与视频预览",
                        systemImage: "folder") { detail = .files }
                ToolRow(title: "Docker", subtitle: "容器 · Compose · 镜像管理",
                        systemImage: "square.stack.3d.up") { detail = .docker }
                ToolRow(title: "命令终端", subtitle: "Shell · PowerShell · CMD",
                        systemImage: "terminal") { detail = .terminal }
                ToolRow(title: "Hangfire", subtitle: "任务、队列与执行历史",
                        systemImage: "clock.arrow.circlepath") { detail = .jobs }
                ToolRow(title: "进程管理", subtitle: "查看资源占用与结束进程",
                        systemImage: "memorychip") { detail = .processes }
                ToolRow(title: "连接通道",
                        subtitle: "当前：\(api.base)\n检测所有地址并手动选择",
                        systemImage: "arrow.triangle.branch") {
                    model.openChannels(session.device)
                }
                ToolRow(title: "切换设备", subtitle: "返回设备列表，配置互不影响",
                        systemImage: "rectangle.2.swap") {
                    model.showDevices()
                }
            }
            .padding(16)
        }
    }

    // MARK: - 底部标签

    private var bottomBar: some View {
        HStack(spacing: 4) {
            ForEach(HomeRoute.allCases) { item in
                let selected = route == item
                Button {
                    route = item
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18))
                        Text(item == .system && !selected ? session.device.name : item.title)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 16))
                    .foregroundColor(selected ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemBackground))
    }
}

// MARK: - 路由

enum HomeRoute: String, CaseIterable, Identifiable {
    case system, remote, codex, hermes, more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "系统"
        case .remote: return "远程"
        case .codex: return "Codex"
        case .hermes: return "Hermes"
        case .more: return "更多"
        }
    }

    var icon: String {
        switch self {
        case .system: return "speedometer"
        case .remote: return "display"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .hermes: return "cpu"
        case .more: return "ellipsis.circle"
        }
    }
}

enum DetailRoute: Hashable {
    case processes
    case terminal
    case files
    case docker
    case compose(String)
    case jobs

    var title: String {
        switch self {
        case .processes: return "进程"
        case .terminal: return "终端"
        case .files: return "文件"
        case .docker: return "Docker"
        case .compose: return "Compose 管理"
        case .jobs: return "Hangfire"
        }
    }

    /// `compose(path)` 带值，比较时按「同类」处理，避免切换路径被当成不同页面。
    static func == (lhs: DetailRoute, rhs: DetailRoute) -> Bool {
        switch (lhs, rhs) {
        case (.processes, .processes), (.terminal, .terminal), (.files, .files),
             (.docker, .docker), (.jobs, .jobs), (.compose, .compose):
            return true
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
    }
}

/// 「更多」页与系统页共用的一行式入口。
struct ToolRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
