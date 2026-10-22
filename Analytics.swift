import Foundation

enum UsageProvider: String, Sendable, CaseIterable {
    case qoder
    case workbuddy
    case codex

    var displayName: String {
        switch self {
        case .qoder: return "Qoder"
        case .workbuddy: return "WorkBuddy"
        case .codex: return "Codex"
        }
    }
}

struct UsageWindow: Sendable {
    let minutes: Int
    let remainingPercent: Double
    let usedPercent: Double
    let resetsAt: Int?
}

struct UsageInput: Sendable {
    let remaining: Double?
    let total: Double?
    let remainingPercent: Double?
    let windows: [UsageWindow]
}

struct WindowUsageSample: Codable, Sendable {
    let minutes: Int
    let remainingPercent: Double
    let usedPercent: Double
    let resetsAt: Int?
}

struct UsageSample: Codable, Sendable {
    let at: Int
    let remaining: Double?
    let total: Double?
    let remainingPercent: Double?
    let windows: [WindowUsageSample]?
}

struct WindowProjection: Sendable {
    let minutes: Int
    let remainingPercent: Double
    let ratePerHour: Double
    let exhaustAt: Date
    let resetsAt: Date?

    var exhaustsBeforeReset: Bool {
        guard let resetsAt else { return false }
        return exhaustAt < resetsAt.addingTimeInterval(-60)
    }
}

struct UsageForecast: Sendable {
    let values: [Double]
    let text: String
    let help: String
    let warning: Bool
    let remainingPercent: Double?
    let ratePerHour: Double?
    let windows: [WindowProjection]
}

enum UsageAnalytics {
    static let historyRetentionDays = 14
    static let chartDays = 7
    static let sampleInterval: TimeInterval = 300
    static let maxSamplesPerProvider = 4500
    static let lowThreshold = 20.0
    static let lowRecovery = 25.0
    static let lowCooldown: TimeInterval = 12 * 3600
    static let rampCooldown: TimeInterval = 6 * 3600
    static let rateWindow: TimeInterval = 3600
    static let minimumRateSpan: TimeInterval = 240
    static let rampShortWindow: TimeInterval = 900
    static let rampBaselineStart: TimeInterval = 4500
    static let rampRatio = 2.5
    static let rampMinimumRate = 1.5

    private static let jumpThreshold = 0.75
    private static let day: TimeInterval = 86400

    static func currentPercent(provider: UsageProvider, input: UsageInput) -> Double? {
        switch provider {
        case .qoder, .workbuddy:
            if let percent = input.remainingPercent, percent.isFinite {
                return clamp(percent)
            }
            guard let remaining = input.remaining,
                  let total = input.total,
                  total > 0,
                  remaining.isFinite else { return nil }
            return clamp(remaining * 100 / total)
        case .codex:
            return lowestWindow(of: input)?.remainingPercent
        }
    }

    static func lowestWindow(of input: UsageInput) -> UsageWindow? {
        input.windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    static func sample(
        provider: UsageProvider,
        input: UsageInput,
        at date: Date = Date()
    ) -> UsageSample? {
        let windows = input.windows.map {
            WindowUsageSample(
                minutes: $0.minutes,
                remainingPercent: $0.remainingPercent,
                usedPercent: $0.usedPercent,
                resetsAt: $0.resetsAt
            )
        }
        let percent: Double?
        if provider == .codex {
            percent = input.windows.first?.remainingPercent
        } else {
            percent = currentPercent(provider: provider, input: input)
        }
        guard percent != nil || !windows.isEmpty else { return nil }
        return UsageSample(
            at: Int(date.timeIntervalSince1970),
            remaining: provider == .codex ? nil : input.remaining,
            total: provider == .codex ? nil : input.total,
            remainingPercent: percent,
            windows: windows.isEmpty ? nil : windows
        )
    }

    static func prune(_ samples: [UsageSample], now: Date = Date()) -> [UsageSample] {
        let cutoff = now.timeIntervalSince1970 - TimeInterval(historyRetentionDays) * day
        var result = samples
            .filter { Double($0.at) >= cutoff }
            .sorted { $0.at < $1.at }
        if result.count > maxSamplesPerProvider {
            result = Array(result.suffix(maxSamplesPerProvider))
        }
        return result
    }

    static func forecast(
        provider: UsageProvider,
        input: UsageInput,
        samples: [UsageSample],
        now: Date = Date()
    ) -> UsageForecast? {
        switch provider {
        case .qoder, .workbuddy:
            return creditForecast(provider: provider, input: input, samples: samples, now: now)
        case .codex:
            return codexForecast(input: input, samples: samples, now: now)
        }
    }

    static func rampRates(
        provider: UsageProvider,
        input: UsageInput,
        samples: [UsageSample],
        now: Date = Date()
    ) -> (short: Double?, baseline: Double?) {
        let points = rateSeries(provider: provider, input: input, samples: samples)
        let nowTs = now.timeIntervalSince1970
        let short = rate(
            points.filter { $0.at >= nowTs - rampShortWindow && $0.at <= nowTs },
            minimumSpan: 480
        )
        let baseline = rate(
            points.filter { $0.at >= nowTs - rampBaselineStart && $0.at < nowTs - rampShortWindow },
            minimumSpan: 1200
        )
        return (short, baseline)
    }

    static func durationText(_ hours: Double) -> String {
        guard hours.isFinite, hours > 0 else { return "不到 1 分钟" }
        if hours * 60 < 1 { return "不到 1 分钟" }
        if hours < 1 {
            return "\(max(1, Int((hours * 60).rounded()))) 分钟"
        }
        if hours < 24 {
            let digits = hours < 10 ? 1 : 0
            return String(format: "%.\(digits)f 小时", hours)
        }
        let days = hours / 24
        if days < 10 {
            return String(format: "%.1f 天", days)
        }
        return "\(Int(days.rounded())) 天"
    }

    static func windowText(_ minutes: Int) -> String {
        if minutes <= 0 { return "额度" }
        if minutes == 43200 { return "月度" }
        if minutes % 43200 == 0 { return "\(minutes / 43200) 月" }
        if minutes % 10080 == 0 { return "周" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    private static func creditForecast(
        provider: UsageProvider,
        input: UsageInput,
        samples: [UsageSample],
        now: Date
    ) -> UsageForecast? {
        let nowTs = now.timeIntervalSince1970
        let chartStart = nowTs - TimeInterval(chartDays) * day
        let points = samples.compactMap { sample -> (at: Double, value: Double)? in
            guard Double(sample.at) >= chartStart, let percent = sample.remainingPercent else { return nil }
            return (Double(sample.at), percent)
        }
        guard !points.isEmpty,
              let current = currentPercent(provider: provider, input: input) else { return nil }

        let recent = points.filter { $0.at >= nowTs - rateWindow }
        guard let rate = rate(recent) else { return nil }

        let values = downsample(points.map(\.value))
        if rate <= 0.05 {
            return UsageForecast(
                values: values,
                text: "近期无明显消耗",
                help: "近 7 天剩余比例趋势；当前消耗速度接近 0，暂无耗尽估算。",
                warning: false,
                remainingPercent: current,
                ratePerHour: 0,
                windows: []
            )
        }

        let hours = current / rate
        let exhaustAt = now.addingTimeInterval(hours * 3600)
        let warning = current <= lowThreshold || hours <= 2
        var help = "按近期速度估算，每小时约消耗 \(percentText(rate))"
        if let total = input.total, total > 0 {
            help += "（约 \(creditText(total * rate / 100)) Credits）"
        }
        help += "，预计 \(timeText(exhaustAt)) 降至 0，仅供参考。"
        return UsageForecast(
            values: values,
            text: "预计 \(durationText(hours))后耗尽",
            help: help,
            warning: warning,
            remainingPercent: current,
            ratePerHour: rate,
            windows: []
        )
    }

    private static func codexForecast(
        input: UsageInput,
        samples: [UsageSample],
        now: Date
    ) -> UsageForecast? {
        guard let primary = input.windows.first else { return nil }
        let nowTs = now.timeIntervalSince1970
        let chartStart = nowTs - TimeInterval(chartDays) * day
        let chartPoints = samples.compactMap { sample -> Double? in
            guard Double(sample.at) >= chartStart else { return nil }
            return sample.windows?.first(where: { $0.minutes == primary.minutes })?.remainingPercent
        }

        var projections: [WindowProjection] = []
        var sawRate = false
        var sawZeroRate = false
        for window in input.windows {
            var points: [(at: Double, value: Double)] = []
            for sample in samples {
                guard let item = sample.windows?.first(where: { $0.minutes == window.minutes }) else { continue }
                if let currentReset = window.resetsAt,
                   let sampleReset = item.resetsAt,
                   currentReset != sampleReset { continue }
                points.append((Double(sample.at), item.remainingPercent))
            }
            points = points.filter { $0.at >= nowTs - rateWindow }
            guard let rate = rate(points) else { continue }
            sawRate = true
            if rate <= 0.05 {
                sawZeroRate = true
                continue
            }
            guard window.remainingPercent > 0 else { continue }
            let hours = window.remainingPercent / rate
            projections.append(WindowProjection(
                minutes: window.minutes,
                remainingPercent: window.remainingPercent,
                ratePerHour: rate,
                exhaustAt: now.addingTimeInterval(hours * 3600),
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ))
        }

        let values = downsample(chartPoints)
        guard sawRate else { return nil }

        if let risk = projections
            .filter({ $0.exhaustsBeforeReset })
            .min(by: { $0.exhaustAt < $1.exhaustAt }) {
            let hours = max(0, risk.exhaustAt.timeIntervalSince(now) / 3600)
            var help = "按近期速度，\(windowText(risk.minutes))窗口预计 \(timeText(risk.exhaustAt)) 耗尽"
            if let reset = risk.resetsAt {
                help += "，早于重置时间 \(timeText(reset))"
            }
            help += "；当前每小时约消耗 \(percentText(risk.ratePerHour))。"
            return UsageForecast(
                values: values,
                text: "\(windowText(risk.minutes))窗口预计 \(durationText(hours))后耗尽",
                help: help,
                warning: true,
                remainingPercent: risk.remainingPercent,
                ratePerHour: risk.ratePerHour,
                windows: projections
            )
        }

        if let primaryProjection = projections.first(where: { $0.minutes == primary.minutes }) {
            let hours = max(0, primaryProjection.exhaustAt.timeIntervalSince(now) / 3600)
            if let reset = primaryProjection.resetsAt {
                let remaining = primaryProjection.remainingPercent
                let resetText = "按近期速度，预计 \(timeText(primaryProjection.exhaustAt)) 耗尽，重置时间 \(timeText(reset))，当前每小时约消耗 \(percentText(primaryProjection.ratePerHour))。"
                return UsageForecast(
                    values: values,
                    text: "可撑到重置（\(windowText(primary.minutes))）",
                    help: resetText,
                    warning: remaining <= lowThreshold,
                    remainingPercent: remaining,
                    ratePerHour: primaryProjection.ratePerHour,
                    windows: projections
                )
            }
            return UsageForecast(
                values: values,
                text: "预计 \(durationText(hours))后耗尽",
                help: "按近期速度，每小时约消耗 \(percentText(primaryProjection.ratePerHour))，仅供参考。",
                warning: primaryProjection.remainingPercent <= lowThreshold,
                remainingPercent: primaryProjection.remainingPercent,
                ratePerHour: primaryProjection.ratePerHour,
                windows: projections
            )
        }

        if let projection = projections.min(by: { $0.exhaustAt < $1.exhaustAt }) {
            let hours = max(0, projection.exhaustAt.timeIntervalSince(now) / 3600)
            return UsageForecast(
                values: values,
                text: "\(windowText(projection.minutes))窗口预计 \(durationText(hours))后耗尽",
                help: "按近期速度，每小时约消耗 \(percentText(projection.ratePerHour))，仅供参考。",
                warning: projection.remainingPercent <= lowThreshold,
                remainingPercent: projection.remainingPercent,
                ratePerHour: projection.ratePerHour,
                windows: projections
            )
        }

        if sawZeroRate {
            return UsageForecast(
                values: values,
                text: "近期无明显消耗",
                help: "近 7 天剩余比例趋势；当前消耗速度接近 0，暂无耗尽估算。",
                warning: false,
                remainingPercent: primary.remainingPercent,
                ratePerHour: 0,
                windows: []
            )
        }
        return nil
    }

    private static func rateSeries(
        provider: UsageProvider,
        input: UsageInput,
        samples: [UsageSample]
    ) -> [(at: Double, value: Double)] {
        switch provider {
        case .qoder, .workbuddy:
            return samples.compactMap { sample in
                guard let percent = sample.remainingPercent else { return nil }
                return (Double(sample.at), percent)
            }
        case .codex:
            guard let primary = input.windows.first else { return [] }
            var points: [(at: Double, value: Double)] = []
            for sample in samples {
                guard let item = sample.windows?.first(where: { $0.minutes == primary.minutes }) else { continue }
                if let currentReset = primary.resetsAt,
                   let sampleReset = item.resetsAt,
                   currentReset != sampleReset { continue }
                points.append((Double(sample.at), item.remainingPercent))
            }
            return points
        }
    }

    private static func rate(
        _ points: [(at: Double, value: Double)],
        minimumSpan: TimeInterval = minimumRateSpan
    ) -> Double? {
        let sorted = points.sorted { $0.at < $1.at }
        guard sorted.count >= 2,
              let first = sorted.first,
              let last = sorted.last,
              last.at - first.at >= minimumSpan else { return nil }

        var start = 0
        for index in 1..<sorted.count where sorted[index].value - sorted[index - 1].value > jumpThreshold {
            start = index
        }
        let slice = Array(sorted[start...])
        guard slice.count >= 2,
              let sliceFirst = slice.first,
              let sliceLast = slice.last,
              sliceLast.at - sliceFirst.at >= minimumSpan else { return nil }

        let base = sliceFirst.at
        let xs = slice.map { ($0.at - base) / 3600 }
        let ys = slice.map(\.value)
        let count = Double(xs.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXX = xs.map { $0 * $0 }.reduce(0, +)
        let sumXY = zip(xs, ys).map { $0 * $1 }.reduce(0, +)
        let denominator = count * sumXX - sumX * sumX
        guard abs(denominator) > 1e-9 else { return nil }
        let slope = (count * sumXY - sumX * sumY) / denominator
        return max(0, -slope)
    }

    private static func downsample(_ values: [Double], limit: Int = 64) -> [Double] {
        guard values.count > limit, limit > 1 else { return values }
        let step = Double(values.count - 1) / Double(limit - 1)
        return (0..<limit).map { index in
            values[Int((Double(index) * step).rounded())]
        }
    }

    private static func percentText(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private static func creditText(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
