import Foundation

/// 远程画质档位。与 Android `RemoteActivity.QUALITY_NAMES` / `QUALITY_QUERY` 逐字对齐：
/// 服务端 `StreamController` 对 `resolution` / `bitrate` / `maxrate` / `fps` / `crf` / `colors`
/// 都做了白名单校验，超出范围会被静默改回默认值，所以这里的取值必须落在白名单内。
enum RemoteQuality {
    static let names = ["原画", "高清", "均衡", "省流", "低速网络"]

    static let details = [
        "原画 · 原始分辨率 / 20 Mbps / 60 fps",
        "高清 · 1080p / 10 Mbps / 60 fps",
        "均衡 · 720p / 4 Mbps / 30 fps",
        "省流 · 480p / 1 Mbps / 24 fps",
        "低速网络 · 360p / 500 Kbps / 10 fps · 减少颜色"
    ]

    /// 追加到 `/api/stream?format=h264&` 之后的查询串。
    static let queries = [
        "resolution=original&bitrate=20M&maxrate=20M&fps=60&crf=16",
        "resolution=1920x1080&bitrate=8M&maxrate=10M&fps=60&crf=18",
        "resolution=1280x720&bitrate=3M&maxrate=4M&fps=30&crf=23",
        "resolution=854x480&bitrate=1M&maxrate=1M&fps=24&crf=28",
        "resolution=640x360&bitrate=250k&maxrate=500k&fps=10&crf=34&colors=rgb565"
    ]

    static func clamp(_ index: Int) -> Int { min(max(index, 0), names.count - 1) }

    static func query(_ index: Int) -> String { queries[clamp(index)] }
    static func name(_ index: Int) -> String { names[clamp(index)] }
    static func detail(_ index: Int) -> String { details[clamp(index)] }

    private static let storageKey = "remote.quality"

    static func load() -> Int {
        let stored = UserDefaults.standard.object(forKey: storageKey) as? Int
        return clamp(stored ?? 1)
    }

    static func save(_ index: Int) {
        UserDefaults.standard.set(clamp(index), forKey: storageKey)
    }
}
