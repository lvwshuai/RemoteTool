import Compression
import Foundation

/// gzip 请求体压缩。
///
/// 服务端 `Program.cs` 注册了 `AddRequestDecompression()`，对 `Content-Encoding: gzip` 的请求体解压；
/// 且明确标注「超过 1 KB 的 JSON 在服务端明确支持后采用 gzip，仅在压缩后更小时启用」。
/// Android 侧由 `JsonRequestCompression` 拦截器实现同样的策略，这里保持一致。
///
/// 实现说明：Apple 的 `COMPRESSION_ZLIB` 输出的是**裸 DEFLATE**（不含 zlib 头与 adler32），
/// 正好是 gzip 的载荷部分，所以这里手工拼 10 字节 gzip 头 + 裸 DEFLATE + 8 字节尾（CRC32 + ISIZE）。
enum Gzip {
    /// 仅当体积达标且压缩后确实更小时才返回结果，否则返回 nil（调用方发原文）。
    static func compressIfSmaller(_ data: Data) -> Data? {
        guard data.count >= 1024 else { return nil }
        guard let packed = gzip(data), packed.count < data.count else { return nil }
        return packed
    }

    static func gzip(_ data: Data) -> Data? {
        guard let deflated = rawDeflate(data) else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
        out.append(deflated)
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    private static func rawDeflate(_ data: Data) -> Data? {
        if data.isEmpty { return Data() }
        let capacity = max(128, data.count + data.count / 2 + 128)
        var destination = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(destination[0..<written])
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
