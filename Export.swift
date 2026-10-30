import AppKit
import Foundation
import UniformTypeIdentifiers

enum UsageExport {
    /// 按注册表顺序导出各家历史；未注册的供应商不参与，导出列结构保持不变。
    static func csv(_ samples: [UsageProvider: [UsageSample]]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current

        var rows = [
            "provider,timestamp,remaining,total,remaining_percent,window_minutes,window_remaining_percent,window_used_percent,resets_at"
        ]

        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "" }
            return String(format: "%.2f", value)
        }

        func time(_ epoch: Int?) -> String {
            guard let epoch else { return "" }
            return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
        }

        func append(_ provider: UsageProvider, _ history: [UsageSample]) {
            for sample in history {
                let timestamp = time(sample.at)
                if let windows = sample.windows, !windows.isEmpty {
                    for window in windows {
                        rows.append([
                            provider.rawValue,
                            timestamp,
                            "",
                            "",
                            number(sample.remainingPercent),
                            String(window.minutes),
                            number(window.remainingPercent),
                            number(window.usedPercent),
                            time(window.resetsAt),
                        ].joined(separator: ","))
                    }
                } else {
                    rows.append([
                        provider.rawValue,
                        timestamp,
                        number(sample.remaining),
                        number(sample.total),
                        number(sample.remainingPercent),
                        "",
                        "",
                        "",
                        "",
                    ].joined(separator: ","))
                }
            }
        }

        for descriptor in Providers.ordered {
            append(descriptor.id, samples[descriptor.id] ?? [])
        }
        return rows.joined(separator: "\n") + "\n"
    }

    @MainActor
    static func save(_ samples: [UsageProvider: [UsageSample]]) {
        let panel = NSSavePanel()
        panel.title = "导出用量历史"
        panel.nameFieldStringValue = "TokenTool-usage-\(dateStamp()).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content = csv(samples)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert()
            alert.messageText = "导出失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }
}
