import Foundation
import os.log

/// 本地诊断日志：把采集失败、持久化异常、告警触发这些「用户看不见但出问题时必须回溯」的事件
/// 落到 `Application Support/TokenTool/logs/diagnostics.log`。
/// 隐私边界：只写类别与截断后的原因，写盘前统一脱敏，绝不记录凭据、token、授权链接参数或账号标识。
enum Diagnostics {
    private static let directoryURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TokenTool/logs", isDirectory: true)
    private static let fileURL = directoryURL.appendingPathComponent("diagnostics.log")
    private static let queue = DispatchQueue(label: "com.local.tokentool.diagnostics", qos: .utility)
    private static let maximumBytes = 256 * 1024
    private static let osLog = Logger(subsystem: "com.local.tokentool", category: "diagnostics")

    /// 一条事件：`category` 是固定短词（collector/history/alert/update），`detail` 是自由文本。
    static func record(_ category: String, _ detail: String) {
        let line = "\(timestamp()) \(category) \(sanitize(detail))\n"
        osLog.log("\(detail, privacy: .public)")
        queue.async {
            append(line)
        }
    }

    static var logURL: URL { fileURL }

    private static func append(_ line: String) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directoryURL.path) {
            try? manager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            guard manager.createFile(atPath: fileURL.path, contents: nil),
                  let created = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? created.close() }
            write(created, line)
            return
        }
        defer { try? handle.close() }
        let startOffset = handle.seekToEndOfFile()
        write(handle, line)
        if startOffset + UInt64(line.utf8.count) > UInt64(maximumBytes) {
            rotate()
        }
    }

    private static func write(_ handle: FileHandle, _ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    /// 超限就从中间往后的第一条完整行开始保留，等价于丢掉最旧的一半。
    private static func rotate() {
        guard let data = try? Data(contentsOf: fileURL), data.count > maximumBytes / 2,
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let kept = Array(lines.suffix(max(lines.count / 2, 1)))
        let trimmed = (kept.joined(separator: "\n") + "\n").data(using: .utf8)
        try? trimmed?.write(to: fileURL, options: .atomic)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    private static let sensitivePatterns = [
        "(?i)(token|secret|password|passwd|api[_-]?key|authorization|code)[=: ]+\\S+",
        "[A-Za-z0-9+/=_-]{24,}",
        "\\?\\S+",
    ]

    private static func sanitize(_ value: String) -> String {
        var result = value
        for pattern in sensitivePatterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "<redacted>",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return String(result.prefix(220)).replacingOccurrences(of: "\n", with: " ")
    }
}
