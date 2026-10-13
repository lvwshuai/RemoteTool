import Foundation

/// 与 Android 侧 `org.json.JSONObject` / `JSONArray` 对应的轻量封装。
/// 之所以不直接用 Codable：服务端返回的字段会随版本增删，逐字段可选访问比强类型解码更耐版本变化，
/// 也更贴近 Android 端 `optString/optInt` 的行为。
typealias JSONDict = [String: Any]

enum JSONCoding {
    static func parse(_ data: Data) -> Any? {
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func parse(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return parse(data)
    }

    static func data(_ value: Any, pretty: Bool = false) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: pretty ? [.prettyPrinted, .sortedKeys] : [])
    }

    static func string(_ value: Any) -> String? {
        guard let data = data(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 构造 JSON 对象；`nil` 值会被丢弃，避免把 null 写进请求体。
func jsonObject(_ pairs: (String, Any?)...) -> JSONDict {
    var result: JSONDict = [:]
    for (key, value) in pairs {
        if let value { result[key] = value }
    }
    return result
}

extension Dictionary where Key == String, Value == Any {
    func str(_ key: String, _ fallback: String = "") -> String {
        if let value = self[key] as? String { return value }
        if let value = self[key] as? NSNumber { return value.stringValue }
        return fallback
    }

    func optStr(_ key: String) -> String? {
        let value = str(key, "")
        return value.isEmpty ? nil : value
    }

    func int(_ key: String, _ fallback: Int = 0) -> Int {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? NSNumber { return value.intValue }
        if let value = self[key] as? String, let parsed = Int(value) { return parsed }
        if let value = self[key] as? Double { return Int(value) }
        return fallback
    }

    func dbl(_ key: String, _ fallback: Double = 0) -> Double {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? NSNumber { return value.doubleValue }
        if let value = self[key] as? String, let parsed = Double(value) { return parsed }
        return fallback
    }

    func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? NSNumber { return value.boolValue }
        if let value = self[key] as? String {
            if value == "true" || value == "1" { return true }
            if value == "false" || value == "0" { return false }
        }
        return fallback
    }

    func dict(_ key: String) -> JSONDict? { self[key] as? JSONDict }

    func array(_ key: String) -> [Any] { (self[key] as? [Any]) ?? [] }

    func objects(_ key: String) -> [JSONDict] { array(key).compactMap { $0 as? JSONDict } }
}

extension Array where Element == Any {
    func objects() -> [JSONDict] { compactMap { $0 as? JSONDict } }
    func strings() -> [String] { compactMap { $0 as? String } }
}

/// URL 查询串转义。等价 Android 的 `URLEncoder.encode(value, "UTF-8")`。
func urlQuery(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

/// 字节数格式化，与 Android `bytes()` 输出保持一致。
func bytesLabel(_ value: Double) -> String {
    var n = value
    var index = 0
    let units = ["B", "KB", "MB", "GB", "TB"]
    while n >= 1024, index < 4 {
        n /= 1024
        index += 1
    }
    return index == 0 ? "\(Int(n)) B" : String(format: "%.1f %@", n, units[index])
}

private let remoteTimeParser: [ISO8601DateFormatter] = {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return [withFraction, plain]
}()

private let remoteTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.locale = Locale(identifier: "zh_CN")
    return formatter
}()

/// 服务端返回的时间字符串可能带时区也可能不带（`LocalDateTime`），
/// 与 Android `displayTime` 一样：无时区时按 UTC 解释。
func displayTime(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "null" { return "暂无" }
    for parser in remoteTimeParser {
        if let date = parser.date(from: trimmed) { return remoteTimeFormatter.string(from: date) }
    }
    if let date = remoteTimeFormatter.date(from: trimmed) { return remoteTimeFormatter.string(from: date) }
    // 没有时区信息的 "2026-10-12T05:16:32.123" 形式，按 UTC 解释。
    let normalized = trimmed.contains(".") ? trimmed : trimmed + ".0"
    if let date = remoteTimeParser[0].date(from: normalized) { return remoteTimeFormatter.string(from: date) }
    return value
}

/// 把服务器返回的相对时间（Hangfire 的 "1 minute ago" 之类）原样保留。
func shortDuration(_ seconds: Double) -> String {
    if seconds < 60 { return String(format: "%.0f 秒", seconds) }
    if seconds < 3600 { return String(format: "%.1f 分", seconds / 60) }
    if seconds < 86400 { return String(format: "%.1f 时", seconds / 3600) }
    return String(format: "%.1f 天", seconds / 86400)
}
