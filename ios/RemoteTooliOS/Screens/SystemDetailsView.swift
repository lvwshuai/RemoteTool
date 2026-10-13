import SwiftUI

/// 设备与系统详情。对应 Android `nativeui/SystemDetails.kt`：
/// 显卡 / 磁盘 / 网卡三组明细卡片 + 「设备与系统」字段表。
struct SystemDetailsView: View {
    let info: JSONDict

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let gpus = info.objects("gpus")
            let drives = info.objects("drives")
            let adapters = info.objects("networkAdapters")

            if gpus.isEmpty {
                DeviceCard(title: "显卡", systemImage: "cpu") {
                    Text("显卡信息暂未获取，稍后自动刷新").font(.system(size: 12))
                }
            }
            ForEach(gpus.indices, id: \.self) { index in
                let gpu = gpus[index]
                DeviceCard(title: gpu.str("name", "显卡"), systemImage: "cpu") {
                    let usage = gpu.dbl("usagePercent", -1)
                    let total = gpu.dbl("memoryMB")
                    let used = gpu.dbl("memoryUsedMB", -1)
                    if usage >= 0 {
                        DetailBar(label: "GPU 占用", value: String(format: "%.0f%%", usage), fraction: usage / 100)
                    }
                    if total > 0 && used >= 0 {
                        DetailBar(label: "显存",
                                  value: "\(bytesLabel(used * 1024 * 1024)) / \(bytesLabel(total * 1024 * 1024))",
                                  fraction: used / total)
                    }
                    DetailFields(fields: [
                        ("驱动版本", gpu.str("driverVersion").isEmpty ? "未提供" : gpu.str("driverVersion")),
                        ("GPU 温度", gpu.dbl("temperature", -1) >= 0
                            ? String(format: "%.0f °C", gpu.dbl("temperature")) : "未提供")
                    ])
                }
            }

            ForEach(drives.indices, id: \.self) { index in
                let drive = drives[index]
                DeviceCard(title: drive.str("name", "磁盘") + " · " + drive.str("driveFormat"),
                           systemImage: "internaldrive") {
                    let total = drive.dbl("totalGB")
                    let used = drive.dbl("usedGB")
                    let free = drive.dbl("freeGB")
                    if total > 0 {
                        DetailBar(label: "已用空间",
                                  value: String(format: "%.1f / %.1f GB", used, total),
                                  fraction: used / total)
                    }
                    DetailFields(fields: [
                        ("可用空间", String(format: "%.1f GB", free)),
                        ("总容量", String(format: "%.1f GB", total))
                    ])
                }
            }

            ForEach(adapters.indices, id: \.self) { index in
                let network = adapters[index]
                DeviceCard(title: network.str("name", "网络适配器"), systemImage: "wifi.router") {
                    let speed = network.dbl("speedMbps")
                    DetailFields(fields: [
                        ("连接速率", speed >= 1000
                            ? String(format: "%.1f Gbps", speed / 1000)
                            : String(format: "%.0f Mbps", speed)),
                        ("MAC 地址", network.str("macAddress").isEmpty ? "未提供" : network.str("macAddress"))
                    ])
                }
            }

            Text("设备与系统").font(.system(size: 13, weight: .medium))
                .padding(.top, 4)

            let labels: [(String, String)] = [
                ("machineName", "计算机"),
                ("osVersion", "操作系统"),
                ("platform", "平台"),
                ("userName", "当前用户"),
                ("upTime", "运行时间"),
                ("cpuName", "处理器"),
                ("cpuCores", "物理核心"),
                ("cpuLogicalProcessors", "逻辑处理器"),
                ("cpuMaxClockSpeedMHz", "基准频率"),
                ("processorCount", "处理器数量"),
                ("is64Bit", "系统架构"),
                ("totalMemoryMB", "内存总量"),
                ("availableMemoryMB", "可用内存"),
                ("systemDirectory", "系统目录"),
                ("version", "服务版本"),
                ("informationalVersion", "构建版本")
            ]

            DetailFields(fields: labels.compactMap { key, label in
                guard let raw = info[key], !(raw is NSNull) else { return nil }
                let rendered: String
                switch key {
                case "is64Bit":
                    rendered = info.bool(key) ? "64 位" : "32 位"
                case "cpuMaxClockSpeedMHz":
                    rendered = info.dbl(key) > 0 ? String(format: "%.2f GHz", info.dbl(key) / 1000) : "未提供"
                case "totalMemoryMB", "availableMemoryMB":
                    rendered = bytesLabel(info.dbl(key) * 1024 * 1024)
                default:
                    rendered = info.str(key)
                }
                if rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                return (label, rendered)
            })
        }
    }
}

private struct DeviceCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct DetailBar: View {
    let label: String
    let value: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 12))
                Spacer()
                Text(value).font(.system(size: 11)).foregroundColor(.secondary)
            }
            UsageBar(value: min(max(fraction, 0), 1) * 100)
        }
    }
}

private struct DetailFields: View {
    let fields: [(String, String)]

    var body: some View {
        let pairs = stride(from: 0, to: fields.count, by: 2).map { Array($0..<min($0 + 2, fields.count)) }
        VStack(spacing: 6) {
            ForEach(pairs, id: \.self) { pair in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(pair, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(fields[index].0)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(fields[index].1)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if pair.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
    }
}
