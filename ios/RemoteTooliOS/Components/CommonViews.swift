import SwiftUI
import UIKit

/// 通用小组件。Android 侧大量使用 Compose 的 `Card` / `TextButton` / 简易折线，
/// 这里给出一套对应的 SwiftUI 版本，避免每个页面重复写样式的部分。
/// 注意：这是为了让页面代码保持「像 Compose 一样短」的辅助层，不承载业务逻辑。

struct SectionCard<Content: View>: View {
    let title: String?
    var subtitle: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value.isEmpty ? "暂无" : value)
                .font(.system(size: 13, weight: mono ? .regular : .regular,
                              design: mono ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 简易水平占用条（CPU / 内存 / 磁盘）。
struct UsageBar: View {
    let value: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint)
                    .frame(width: max(0, min(1, value / 100)) * proxy.size.width)
            }
        }
        .frame(height: 6)
    }
}

/// 折线图。用于性能历史曲线（对应 Android 原生绘制的曲线面板）。
struct LineChart: View {
    let series: [[Double]]
    var colors: [Color] = [.accentColor]
    var maxValue: Double?
    var fixedRange: ClosedRange<Double>?

    var body: some View {
        GeometryReader { proxy in
            let all = series.flatMap { $0 }
            let lower = fixedRange?.lowerBound ?? all.min() ?? 0
            let upper = fixedRange?.upperBound ?? maxValue ?? max(all.max() ?? 1, lower + 1)
            let span = max(upper - lower, 0.0001)

            ZStack {
                Path { path in
                    for step in 1..<4 {
                        let y = proxy.size.height * CGFloat(step) / 4
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }
                }
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)

                ForEach(Array(series.enumerated()), id: \.offset) { index, values in
                    Path { path in
                        guard values.count > 1 else { return }
                        for (offset, value) in values.enumerated() {
                            let x = proxy.size.width * CGFloat(offset) / CGFloat(values.count - 1)
                            let ratio = (value - lower) / span
                            let y = proxy.size.height * (1 - CGFloat(min(max(ratio, 0), 1)))
                            if offset == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(colors[min(index, colors.count - 1)], lineWidth: 1.5)
                }
            }
        }
    }
}

/// 远程图片（截图 / 文件预览）。必须走带 Cookie 的 API，不能用 `AsyncImage`。
struct RemoteImage: View {
    let path: String
    let api: NativeApi

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if failed {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                    Text("无法加载").font(.system(size: 12))
                }
                .foregroundColor(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: path) {
            image = nil
            failed = false
            do {
                let data = try await api.download(path)
                guard let loaded = UIImage(data: data) else { failed = true; return }
                image = loaded
            } catch {
                failed = true
            }
        }
    }
}

/// 页面通用的加载 / 错误 / 空态包装。
struct LoadStateView<Content: View>: View {
    let isLoading: Bool
    let error: String?
    let isEmpty: Bool
    let emptyText: String
    let onRetry: (() -> Void)?
    @ViewBuilder let content: Content

    init(isLoading: Bool,
         error: String?,
         isEmpty: Bool = false,
         emptyText: String = "暂无数据",
         onRetry: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.isLoading = isLoading
        self.error = error
        self.isEmpty = isEmpty
        self.emptyText = emptyText
        self.onRetry = onRetry
        self.content = content()
    }

    var body: some View {
        if isLoading, !hasContent {
            VStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        } else if let error, !hasContent {
            VStack(spacing: 12) {
                Spacer()
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if let onRetry {
                    Button("重试", action: onRetry)
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
        } else if isEmpty {
            VStack {
                Spacer()
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer()
            }
        } else {
            content
        }
    }

    private var hasContent: Bool { !isEmpty && error == nil }
}

extension View {
    /// 统一的一行式列表行样式。
    func remoteRowBackground() -> some View {
        listRowBackground(Color(.secondarySystemBackground))
    }
}
