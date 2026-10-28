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

struct UsageInsight: Sendable {
    let todayConsumed: Double?
    let dailyAverage: Double?
    let netDailyAverage: Double?
    let observedDays: Int
    let isPercent: Bool
}

enum UsageAnalytics {
    static let historyRetentionDays = 14
    static let chartDays = 7
    static let sampleInterval: TimeInterval = 300
    /// Qoder 走 CLI 采集（单次约 5 秒），间隔比本地 IPC 的两家长，但不能长到领取后要等几分钟才刷新。
    static let qoderRefreshInterval: TimeInterval = 90
    static let maxSamplesPerProvider = 4500
    static let defaultLowThreshold = 20.0
    static let lowRecoveryGap = 5.0
    static let lowCooldown: TimeInterval = 12 * 3600
    /// 新提醒出现后菜单栏闪动的时长。
    static let attentionBlinkDuration: TimeInterval = 60
    static let attentionBlinkInterval: TimeInterval = 0.6
    static let rampCooldown: TimeInterval = 6 * 3600
    static let rateWindow: TimeInterval = 3600
    static let minimumRateSpan: TimeInterval = 240
    static let rampShortWindow: TimeInterval = 900
    static let rampBaselineStart: TimeInterval = 4500
    static let rampRatio = 2.5
    static let rampMinimumRate = 1.5
    static let minimumInsightSpan: TimeInterval = 6 * 3600
    /// 每小时百分点低于该值视为「无明显消耗」（约 0.5%/天）。
    static let minimumForecastRate = 0.02
    /// 达到这个时长的窗口按日均口径估算，而不是近 1 小时速率。
    static let minutesPerDay = 1440

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
        now: Date = Date(),
        lowThreshold: Double = defaultLowThreshold
    ) -> UsageForecast? {
        switch provider {
        case .qoder, .workbuddy:
            return creditForecast(
                provider: provider,
                input: input,
                samples: samples,
                now: now,
                lowThreshold: lowThreshold
            )
        case .codex:
            return codexForecast(
                input: input,
                samples: samples,
                now: now,
                lowThreshold: lowThreshold
            )
        }
    }

    static func insight(
        provider: UsageProvider,
        input: UsageInput,
        samples: [UsageSample],
        now: Date = Date()
    ) -> UsageInsight? {
        let nowTs = now.timeIntervalSince1970
        let windowStart = nowTs - TimeInterval(chartDays) * day
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now).timeIntervalSince1970

        var points: [(at: Double, value: Double, total: Double?, reset: Int?)] = []
        switch provider {
        case .qoder, .workbuddy:
            for sample in samples {
                guard Double(sample.at) >= windowStart, let remaining = sample.remaining else { continue }
                points.append((Double(sample.at), remaining, sample.total, nil))
            }
        case .codex:
            guard let primary = input.windows.first else { return nil }
            for sample in samples {
                guard Double(sample.at) >= windowStart,
                      let item = sample.windows?.first(where: { $0.minutes == primary.minutes }) else { continue }
                if let currentReset = primary.resetsAt,
                   let sampleReset = item.resetsAt,
                   currentReset != sampleReset {
                    continue
                }
                points.append((Double(sample.at), item.remainingPercent, nil, item.resetsAt))
            }
        }
        points.sort { $0.at < $1.at }
        guard points.count >= 2, let first = points.first, let last = points.last else { return nil }

        var totalConsumed: Double = 0
        var totalReclaimed: Double = 0
        var todayConsumed: Double = 0
        var hasTodayPair = false
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let span = current.at - previous.at
            guard span > 0 else { continue }
            if let previousTotal = previous.total,
               let currentTotal = current.total,
               abs(previousTotal - currentTotal) > 0.5 {
                continue
            }
            if provider == .codex,
               let previousReset = previous.reset,
               let currentReset = current.reset,
               previousReset != currentReset {
                continue
            }
            let consumed = previous.value - current.value
            let endsToday = current.at >= todayStart
            if endsToday { hasTodayPair = true }
            if consumed > 0 {
                totalConsumed += consumed
                guard endsToday else { continue }
                if previous.at < todayStart {
                    todayConsumed += consumed * min(1, (current.at - todayStart) / span)
                } else {
                    todayConsumed += consumed
                }
            } else if consumed < 0, provider != .codex {
                totalReclaimed -= consumed
            }
        }

        let observedDays = min(chartDays, max(1, Int(ceil((last.at - first.at) / day))))
        let hasSpan = last.at - first.at >= minimumInsightSpan
        let dailyAverage = hasSpan ? totalConsumed / Double(observedDays) : nil
        let netDailyAverage = hasSpan
            ? (totalConsumed - totalReclaimed) / Double(observedDays)
            : nil

        return UsageInsight(
            todayConsumed: hasTodayPair ? todayConsumed : nil,
            dailyAverage: dailyAverage,
            netDailyAverage: netDailyAverage,
            observedDays: observedDays,
            isPercent: provider == .codex
        )
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
        now: Date,
        lowThreshold: Double
    ) -> UsageForecast? {
        let nowTs = now.timeIntervalSince1970
        let chartStart = nowTs - TimeInterval(chartDays) * day
        let chartPoints = samples.compactMap { sample -> (at: Double, value: Double)? in
            guard Double(sample.at) >= chartStart,
                  let remaining = sample.remaining,
                  remaining.isFinite else { return nil }
            return (Double(sample.at), remaining)
        }
        guard !chartPoints.isEmpty,
              let current = currentPercent(provider: provider, input: input),
              let currentCredits = currentCredits(input: input),
              let insight = insight(provider: provider, input: input, samples: samples, now: now) else { return nil }

        let values = downsample(chartPoints.sorted { $0.at < $1.at }.map(\.value))
        guard let dailyAverage = insight.dailyAverage else {
            return UsageForecast(
                values: values,
                text: "样本积累中",
                help: "信用额预测需要至少 6 小时历史样本；当前可参考今日消耗。",
                warning: false,
                remainingPercent: current,
                ratePerHour: nil,
                windows: []
            )
        }

        if dailyAverage <= 0.5 {
            return UsageForecast(
                values: values,
                text: "近期无明显消耗",
                help: "按已观察 \(insight.observedDays) 天的日均消耗估算；当前消耗速度接近 0，暂无耗尽估算。",
                warning: false,
                remainingPercent: current,
                ratePerHour: 0,
                windows: []
            )
        }

        let netDaily = insight.netDailyAverage ?? dailyAverage
        let reclaimed = max(0, (dailyAverage - netDaily) * Double(insight.observedDays))
        let sampleNote = insight.observedDays < 3 ? "样本较少，建议多观察几天。" : ""
        if netDaily <= 0.5 {
            var help = "按已观察 \(insight.observedDays) 天统计：日均消耗约 \(creditText(dailyAverage)) Credits，领取/重置增加约 \(creditText(reclaimed)) Credits，净消耗已不大于 0，暂无耗尽估算。"
            help += sampleNote
            return UsageForecast(
                values: values,
                text: "按当前节奏不会耗尽",
                help: help,
                warning: current <= lowThreshold,
                remainingPercent: current,
                ratePerHour: 0,
                windows: []
            )
        }

        let hours = currentCredits / netDaily * 24
        let exhaustAt = now.addingTimeInterval(hours * 3600)
        let warning = current <= lowThreshold || hours <= 2
        var help = "按已观察 \(insight.observedDays) 天的净消耗约 \(creditText(netDaily)) Credits/天 估算"
        if reclaimed > 0.5 {
            help += "（已扣除领取/重置增加约 \(creditText(reclaimed)) Credits）"
        } else {
            help += "（未记录到领取/重置增加）"
        }
        help += "，预计 \(timeText(exhaustAt)) 降至 0，仅供参考。"
        help += sampleNote
        return UsageForecast(
            values: values,
            text: "预计 \(durationText(hours))后耗尽",
            help: help,
            warning: warning,
            remainingPercent: current,
            ratePerHour: netDaily / 24,
            windows: []
        )
    }

    private static func currentCredits(input: UsageInput) -> Double? {
        if let remaining = input.remaining, remaining.isFinite {
            return max(0, remaining)
        }
        guard let total = input.total,
              total > 0,
              let percent = input.remainingPercent,
              percent.isFinite else { return nil }
        return max(0, total * percent / 100)
    }

    private static func codexForecast(
        input: UsageInput,
        samples: [UsageSample],
        now: Date,
        lowThreshold: Double
    ) -> UsageForecast? {
        guard let primary = input.windows.first else { return nil }
        let nowTs = now.timeIntervalSince1970
        let chartStart = nowTs - TimeInterval(chartDays) * day
        let chartPoints = samples.compactMap { sample -> Double? in
            guard Double(sample.at) >= chartStart else { return nil }
            return sample.windows?.first(where: { $0.minutes == primary.minutes })?.remainingPercent
        }

        var projections: [WindowProjection] = []
        var basis: [Int: String] = [:]
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
            let hourly = rate(points.filter { $0.at >= nowTs - rateWindow })
            let netDaily = netDailyPercent(points.filter { $0.at >= chartStart })
            let dailyPerHour = (netDaily?.daily ?? 0) / 24
            if hourly != nil || netDaily != nil { sawRate = true }
            // 天级以上的窗口只认日均：把近 1 小时的一次扣减外推到整月会把剩余时间算得极短。
            let usesDailyBasis = window.minutes >= minutesPerDay && (netDaily?.daily ?? 0) > 0
            let ratePerHour = usesDailyBasis ? dailyPerHour : max(hourly ?? 0, dailyPerHour)
            if ratePerHour <= minimumForecastRate {
                sawZeroRate = true
                continue
            }
            guard window.remainingPercent > 0 else { continue }
            basis[window.minutes] = rateBasis(
                hourly: hourly,
                netDaily: netDaily,
                dailyPerHour: dailyPerHour,
                ratePerHour: ratePerHour,
                usesDailyBasis: usesDailyBasis
            )
            let hours = window.remainingPercent / ratePerHour
            projections.append(WindowProjection(
                minutes: window.minutes,
                remainingPercent: window.remainingPercent,
                ratePerHour: ratePerHour,
                exhaustAt: now.addingTimeInterval(hours * 3600),
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ))
        }

        let values = downsample(chartPoints)
        guard sawRate else { return nil }

        func basisText(_ minutes: Int, _ ratePerHour: Double) -> String {
            basis[minutes] ?? "按近期速度约 \(rateText(ratePerHour))%/小时"
        }

        if let risk = projections
            .filter({ $0.exhaustsBeforeReset })
            .min(by: { $0.exhaustAt < $1.exhaustAt }) {
            let hours = max(0, risk.exhaustAt.timeIntervalSince(now) / 3600)
            var help = "\(windowText(risk.minutes))窗口预计 \(timeText(risk.exhaustAt)) 耗尽"
            if let reset = risk.resetsAt {
                help += "，早于重置时间 \(timeText(reset))"
            }
            help += "；" + basisText(risk.minutes, risk.ratePerHour) + "。"
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
                let resetText = "按\(basisText(primary.minutes, primaryProjection.ratePerHour))，窗口剩余 \(rateText(remaining))% 可撑到 \(timeText(reset)) 的重置。"
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
                help: basisText(primary.minutes, primaryProjection.ratePerHour) + "，仅供参考。",
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
                help: basisText(projection.minutes, projection.ratePerHour) + "，仅供参考。",
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
                help: "近 7 天剩余比例趋势；近 1 小时速率与近 7 天净消耗都接近 0，暂无耗尽估算。",
                warning: false,
                remainingPercent: primary.remainingPercent,
                ratePerHour: 0,
                windows: []
            )
        }
        return nil
    }

    /// 近 7 天窗口内的净消耗（只累计剩余比例的下降，重置带来的上升不计入），折算成每天百分点。
    private static func netDailyPercent(
        _ points: [(at: Double, value: Double)]
    ) -> (daily: Double, days: Int)? {
        let sorted = points.sorted { $0.at < $1.at }
        guard sorted.count >= 2,
              let first = sorted.first,
              let last = sorted.last,
              last.at - first.at >= minimumInsightSpan else { return nil }
        var consumed: Double = 0
        for index in 1..<sorted.count {
            let delta = sorted[index - 1].value - sorted[index].value
            if delta > 0 { consumed += delta }
        }
        let days = min(chartDays, max(1, Int(ceil((last.at - first.at) / day))))
        return (consumed / Double(days), days)
    }

    private static func rateBasis(
        hourly: Double?,
        netDaily: (daily: Double, days: Int)?,
        dailyPerHour: Double,
        ratePerHour: Double,
        usesDailyBasis: Bool
    ) -> String {
        if usesDailyBasis, let netDaily {
            return "近 \(netDaily.days) 天净消耗 \(rateText(netDaily.daily))%/天"
        }
        let recent = hourly ?? 0
        if recent >= dailyPerHour, recent > 0 {
            if let netDaily, netDaily.daily > 0 {
                return "近 1 小时约消耗 \(rateText(recent))%/小时，近 \(netDaily.days) 天净消耗 \(rateText(netDaily.daily))%/天"
            }
            return "近 1 小时约消耗 \(rateText(recent))%/小时"
        }
        if let netDaily, netDaily.daily > 0 {
            return "近 \(netDaily.days) 天净消耗 \(rateText(netDaily.daily))%/天，折算约 \(rateText(dailyPerHour))%/小时"
        }
        return "按近期速度约 \(rateText(ratePerHour))%/小时"
    }

    private static func rateText(_ value: Double) -> String {
        value < 1 ? String(format: "%.2f", value) : String(format: "%.1f", value)
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
