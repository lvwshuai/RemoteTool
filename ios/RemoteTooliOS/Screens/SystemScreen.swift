import SwiftUI

/// 系统监控页。对应 Android `nativeui/SystemScreens.kt` 的 `SystemScreen`：
/// 每 3 秒拉一次 `/api/system/performance?seconds=N`，画 CPU / 内存 / 网络曲线，
/// 外加电源操作、进程页与终端页入口。
struct SystemScreen: View {
    let api: NativeApi
    let onProcesses: () -> Void
    let onTerminal: () -> Void
    let onError: (String) -> Void

    @State private var data: JSONDict? = nil
    @State private var errorText: String? = nil
    @State private var seconds = 60
    @State private var reloadToken = 0
    @State private var powerConfirm: ConfirmRequest? = nil

    private struct WindowOption: Identifiable {
        let id: Int
        let label: String
    }

    private struct PowerOption: Identifiable {
        let id: String
        let label: String
    }

    private let windows = [WindowOption(id: 60, label: "60 秒"),
                           WindowOption(id: 300, label: "5 分钟"),
                           WindowOption(id: 900, label: "15 分钟")]

    private let powers = [PowerOption(id: "lock", label: "锁定"),
                          PowerOption(id: "sleep", label: "睡眠"),
                          PowerOption(id: "hibernate", label: "休眠"),
                          PowerOption(id: "cancel-shutdown", label: "取消关机"),
                          PowerOption(id: "reboot", label: "重启"),
                          PowerOption(id: "shutdown", label: "关机")]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button(action: onProcesses) {
                        Label("进程", systemImage: "memorychip").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button(action: onTerminal) {
                        Label("终端", systemImage: "terminal").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                powerRow

                HStack(spacing: 8) {
                    ForEach(windows) { option in
                        Button {
                            seconds = option.id
                        } label: {
                            Text(option.label)
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(seconds == option.id ? Color.accentColor.opacity(0.2) : Color.clear,
                                            in: Capsule())
                                .overlay(Capsule().stroke(Color.secondary.opacity(0.35)))
                        }
                        .foregroundColor(seconds == option.id ? .accentColor : .secondary)
                        .buttonStyle(.plain)
                    }
                }

                if data == nil {
                    LoadStateView(isLoading: errorText == nil,
                                  error: errorText,
                                  onRetry: { reloadToken += 1 }) {
                        EmptyView()
                    }
                    .frame(height: 160)
                } else {
                    metrics
                }
            }
            .padding(16)
        }
        .task(id: "\(seconds)-\(reloadToken)") {
            await poll()
        }
        .confirmAlert($powerConfirm)
    }

    // MARK: - 电源操作

    private var powerRow: some View {
        // 与 Android 一致：多列网格，避免 6 个按钮在窄屏挤成一行。
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(powers) { option in
                let dangerous = ["shutdown", "reboot"].contains(option.id)
                Button {
                    powerConfirm = ConfirmRequest(title: option.label,
                                                  message: "对当前电脑执行「\(option.label)」？",
                                                  destructive: dangerous) {
                        runPower(label: option.label, path: option.id)
                    }
                } label: {
                    Text(option.label)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity)
                        .foregroundColor(dangerous ? .red : .accentColor)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func runPower(label: String, path: String) {
        let api = api
        let report = onError
        Task {
            do {
                _ = try await api.json("/api/system/\(path)", body: [:])
                report("\(label) 已发送")
            } catch {
                report(connectionFailureMessage(error))
            }
        }
    }

    // MARK: - 指标

    @ViewBuilder
    private var metrics: some View {
        if let data {
            let history = data.objects("history")
            let latest = data.dict("latest")
            let info = data.dict("info") ?? [:]

            if let errorText {
                Text("更新失败：\(errorText)")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }

            if let latest {
                MetricCard(title: "CPU",
                           value: String(format: "%.0f%%", latest.dbl("cpuPercent")),
                           subtitle: info.str("cpuName"),
                           values: history.map { $0.dbl("cpuPercent") },
                           maximum: 100,
                           color: .accentColor,
                           headerDetail: cpuTemperatureLabel(latest.objects("temperatures")))

                MetricCard(title: "内存",
                           value: String(format: "%.0f%%", latest.dbl("memoryPercent")),
                           subtitle: "\(bytesLabel(latest.dbl("usedMemoryMB") * 1024 * 1024)) / \(bytesLabel(latest.dbl("totalMemoryMB") * 1024 * 1024))",
                           values: history.map { $0.dbl("memoryPercent") },
                           maximum: 100,
                           color: .blue)

                let networks = latest.objects("networks")
                let rx = networks.reduce(0.0) { $0 + $1.dbl("receiveBytesPerSecond") }
                let tx = networks.reduce(0.0) { $0 + $1.dbl("sendBytesPerSecond") }
                MetricCard(title: "网络",
                           value: "↓ \(bytesLabel(rx))/s",
                           subtitle: "↑ \(bytesLabel(tx))/s",
                           values: history.map { sample in
                               sample.objects("networks").reduce(0.0) { $0 + $1.dbl("receiveBytesPerSecond") }
                           },
                           maximum: nil,
                           color: Color(red: 0xdc / 255, green: 0x8a / 255, blue: 0xa6 / 255),
                           second: history.map { sample in
                               sample.objects("networks").reduce(0.0) { $0 + $1.dbl("sendBytesPerSecond") }
                           })

                let temperatures = latest.objects("temperatures")
                let coreTemperatures = temperatures.filter {
                    $0.str("name").range(of: "^(?:[PE]-Core|CPU Core) #\\d+$",
                                         options: .regularExpression) != nil
                }
                let coreNames = Set(coreTemperatures.map { $0.str("name") })
                ExpandableCard(title: "硬件温度",
                               summary: "\(temperatures.count) 项传感器",
                               defaultExpanded: false) {
                    Text(latest.str("sensorStatus", "—"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    SensorGrid(rows: temperatures.filter { !coreNames.contains($0.str("name")) }, fans: false)
                    if !coreTemperatures.isEmpty {
                        ExpandableCard(title: "CPU 核心温度",
                                       summary: "\(coreTemperatures.count) 核",
                                       defaultExpanded: false) {
                            SensorGrid(rows: coreTemperatures, fans: false)
                        }
                    }
                }

                let fans = latest.objects("fans")
                ExpandableCard(title: "风扇与水泵",
                               summary: "\(fans.count) 项转速",
                               defaultExpanded: false) {
                    if fans.isEmpty {
                        Text("暂未获取风扇转速").font(.system(size: 12))
                    } else {
                        SensorGrid(rows: fans, fans: true)
                    }
                }

                coreCard(latest: latest, info: info, history: history)

                ExpandableCard(title: "更多设备信息", summary: "", defaultExpanded: false) {
                    SystemDetailsView(info: info)
                }
            }
        }
    }

    @ViewBuilder
    private func coreCard(latest: JSONDict, info: JSONDict, history: [JSONDict]) -> some View {
        let coreCount = latest.array("cpuCores").count
        let logical = info.int("cpuLogicalProcessors") != 0
            ? info.int("cpuLogicalProcessors")
            : info.int("processorCount")
        let knownCount = coreCount > 0 ? coreCount : logical
        ExpandableCard(title: "逻辑处理器",
                       summary: knownCount > 0 ? "\(knownCount) 核" : "等待处理器数据",
                       defaultExpanded: false) {
            if coreCount == 0 {
                Text("核心曲线暂未获取，稍后自动刷新").font(.system(size: 12))
            }
            ForEach(coreRows(coreCount), id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CPU \(index + 1)").font(.system(size: 10))
                            Sparkline(values: history.map { sample in
                                let cores = sample.array("cpuCores")
                                return index < cores.count ? asDouble(cores[index]) : 0
                            }, maximum: 100, color: .accentColor)
                                .frame(height: 55)
                        }
                    }
                    if row.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
    }

    private func coreRows(_ count: Int) -> [[Int]] {
        guard count > 0 else { return [] }
        return stride(from: 0, to: count, by: 2).map { Array($0..<min($0 + 2, count)) }
    }

    // MARK: - 轮询

    private func poll() async {
        let api = api
        let window = seconds
        while !Task.isCancelled {
            do {
                let result = try await api.json("/api/system/performance?seconds=\(window)")
                guard let payload = result.dict("data") else {
                    throw NSError(domain: "RemoteTool", code: 6,
                                  userInfo: [NSLocalizedDescriptionKey: "服务没有返回性能数据"])
                }
                data = payload
                errorText = nil
            } catch is CancellationError {
                return
            } catch {
                errorText = connectionFailureMessage(error)
            }
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
        }
    }
}

/// 把 JSON 里任意数字形态（NSNumber / 字符串）安全地取成 Double。
/// Android 的 `optDouble(index, 0.0)` 对数组元素也这么宽容，这里保持一致。
func asDouble(_ value: Any) -> Double {
    if let number = value as? NSNumber { return number.doubleValue }
    if let text = value as? String, let parsed = Double(text) { return parsed }
    return 0
}

// MARK: - 曲线与卡片

/// 与 Android `Sparkline` 对齐：5 条横向网格 + 7 条纵向网格 + 填充折线 + 可选第二条线。
struct Sparkline: View {
    let values: [Double]
    let maximum: Double?
    let color: Color
    var second: [Double] = []

    var body: some View {
        GeometryReader { proxy in
            let all = values + second
            let high = maximum ?? max(1, all.max() ?? 1) * 1.15
            ZStack {
                Path { path in
                    for step in 0..<5 {
                        let y = proxy.size.height * CGFloat(step) / 4
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }
                    for step in 0..<7 {
                        let x = proxy.size.width * CGFloat(step) / 6
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    }
                }
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)

                if !values.isEmpty {
                    Sparkline.area(values, size: proxy.size, high: high)
                        .fill(color.opacity(0.13))
                    Sparkline.line(values, size: proxy.size, high: high)
                        .stroke(color, lineWidth: 2.5)
                }
                if !second.isEmpty {
                    Sparkline.line(second, size: proxy.size, high: high)
                        .stroke(Color(red: 0x80 / 255, green: 0xa9 / 255, blue: 0xef / 255), lineWidth: 2)
                }
            }
        }
    }

    private static func point(_ index: Int, _ count: Int, _ value: Double,
                              _ size: CGSize, _ high: Double) -> CGPoint {
        let x = count < 2 ? 0 : size.width * CGFloat(index) / CGFloat(count - 1)
        let clamped = min(max(value, 0), high)
        let y = size.height * (1 - CGFloat(clamped / max(high, 0.0001)))
        return CGPoint(x: x, y: y)
    }

    private static func line(_ data: [Double], size: CGSize, high: Double) -> Path {
        Path { path in
            for index in data.indices {
                let p = point(index, data.count, data[index], size, high)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
    }

    private static func area(_ data: [Double], size: CGSize, high: Double) -> Path {
        Path { path in
            for index in data.indices {
                let p = point(index, data.count, data[index], size, high)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
    }
}

/// 可折叠卡片，对应 Android 的 `ExpandableSystemCard`。
struct ExpandableCard<Content: View>: View {
    let title: String
    var summary: String = ""
    var value: String?
    var valueColor: Color = .accentColor
    var headerDetail: String?
    @ViewBuilder let content: Content

    @State private var expanded: Bool

    init(title: String,
         summary: String = "",
         defaultExpanded: Bool = false,
         value: String? = nil,
         valueColor: Color = .accentColor,
         headerDetail: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.value = value
        self.valueColor = valueColor
        self.headerDetail = headerDetail
        self.content = content()
        _expanded = State(initialValue: defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 15, weight: .medium))
                        if !summary.isEmpty {
                            Text(summary).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if value != nil || headerDetail != nil {
                        VStack(alignment: .trailing, spacing: 2) {
                            if let value {
                                Text(value)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(valueColor)
                            }
                            if let headerDetail {
                                Text(headerDetail).font(.system(size: 11)).foregroundColor(.secondary)
                            }
                        }
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if expanded { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 对应 Android `MetricCard`：标题 + 大数字 + 副标题 + 曲线。
struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let values: [Double]
    let maximum: Double?
    let color: Color
    var second: [Double] = []
    var headerDetail: String?

    var body: some View {
        ExpandableCard(title: title,
                       summary: subtitle,
                       defaultExpanded: true,
                       value: value,
                       valueColor: color,
                       headerDetail: headerDetail) {
            Sparkline(values: values, maximum: maximum, color: color, second: second)
                .frame(height: 105)
        }
    }
}

// MARK: - 传感器

func sensorLabel(_ name: String) -> String {
    switch name {
    case "CPU Package": return "CPU 封装"
    case "Core Max": return "CPU 核心最高"
    case "Core Average": return "CPU 核心平均"
    case "CPU Socket": return "CPU 脚座"
    case "VRM MOS": return "MOS / 供电"
    case "PCH": return "PCH 芯片组"
    case "System": return "主板系统"
    case "CPU Fan": return "CPU 风扇"
    case "Pump Fan": return "水泵"
    case "GPU Core": return "显卡核心"
    case "GPU Hot Spot": return "显卡热点"
    case "Composite Temperature": return "综合温度"
    case "Temperature": return "温度"
    default:
        return name
            .replacingOccurrences(of: "System Fan #", with: "系统风扇 #")
            .replacingOccurrences(of: "GPU Fan ", with: "显卡风扇 ")
            .replacingOccurrences(of: "P-Core #", with: "性能核 #")
            .replacingOccurrences(of: "E-Core #", with: "能效核 #")
    }
}

struct SensorGrid: View {
    let rows: [JSONDict]
    let fans: Bool

    private var pairs: [[Int]] {
        stride(from: 0, to: rows.count, by: 2).map { Array($0..<min($0 + 2, rows.count)) }
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(pairs, id: \.self) { pair in
                HStack(spacing: 10) {
                    ForEach(pair, id: \.self) { index in
                        tile(rows[index])
                    }
                    if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
    }

    private func tile(_ sensor: JSONDict) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(sensorLabel(sensor.str("name")))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Text(fans
                 ? "\(Int(sensor.dbl("rpm"))) RPM"
                 : String(format: "%.0f °C", sensor.dbl("celsius")))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.accentColor)
            if !sensor.str("hardware").isEmpty {
                Text(sensor.str("hardware"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 对应 Android `cpuTemperatureLabel`：优先「核心最高」，否则取各核最大值，其次「核心平均」；
/// 封装温度按 Intel / AMD 两种命名兜底。
func cpuTemperatureLabel(_ temperatures: [JSONDict]) -> String {
    let valid = temperatures.filter { $0.dbl("celsius").isFinite }
    func named(_ name: String) -> Double? {
        valid.filter { $0.str("name") == name }.map { $0.dbl("celsius") }.max()
    }
    let coreMax = named("Core Max")
    let perCoreMax = valid
        .filter { $0.str("name").range(of: "^(?:[PE]-Core|CPU Core) #\\d+$",
                                      options: .regularExpression) != nil }
        .map { $0.dbl("celsius") }
        .max()
    let core = coreMax ?? perCoreMax ?? named("Core Average")
    let pack = named("CPU Package") ?? named("CPU (Tctl/Tdie)") ?? named("CPU Die (average)")
    if core == nil && pack == nil { return "温度暂无" }
    func reading(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f", value)
    }
    return "\(reading(core)) / \(reading(pack)) °C"
}
