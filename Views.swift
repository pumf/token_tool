import SwiftUI
import AppKit

enum Theme {
    static let qoder = Color(red: 0.20, green: 0.49, blue: 0.98)
    static let workbuddy = Color(red: 0.10, green: 0.68, blue: 0.42)
    static let codex = Color(red: 0.55, green: 0.36, blue: 0.95)
    static let warning = Color.orange
    static let danger = Color(nsColor: .systemRed)
    static let claim = Color(nsColor: .systemOrange)
}

enum Token {
    static let radiusCard: CGFloat = 12
    static let radiusControl: CGFloat = 8

    static let spaceTight: CGFloat = 6
    static let spaceRow: CGFloat = 8
    static let spaceCard: CGFloat = 12
    static let spaceSection: CGFloat = 12

    static let panelWidth: CGFloat = 382

    static let value = Font.system(size: 22, weight: .semibold)
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 11, weight: .medium)
    static let label = Font.system(size: 11, weight: .medium)
    static let meta = Font.system(size: 10)
    static let caption = Font.system(size: 10)

    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let cardStroke = Color(nsColor: .separatorColor)
    static let insetFill = Color.primary.opacity(0.04)
    static let hairline: CGFloat = 0.5
    static let detailMinHeight: CGFloat = 72
}

enum Format {
    static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    static func credits(_ value: Double?, digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "--" }
        decimal.maximumFractionDigits = digits
        decimal.minimumFractionDigits = 0
        return decimal.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    static func compact(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        if abs(value) >= 1000 {
            return String(format: "%.1fk", value / 1000)
        }
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    /// 今日消耗这类小数值：不足 10% 时保留一位小数，否则取整，避免 0.4% 被显示成 0%。
    static func percentDetailed(_ value: Double?) -> String {
        guard let value, value > 0, value < 10 else { return percent(value) }
        return String(format: "%.1f%%", value)
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "从未" }
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86400)) 天前"
    }

    static func window(_ minutes: Int?) -> String {
        window(minutes ?? 0)
    }

    static func window(_ minutes: Int) -> String {
        if minutes <= 0 { return "额度" }
        if minutes == 43200 { return "月度" }
        if minutes % 43200 == 0 { return "\(minutes / 43200) 月" }
        if minutes % 10080 == 0 { return "\(minutes / 10080) 周" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    static func reset(_ epoch: Int?) -> String {
        guard let epoch, epoch > 0 else { return "--" }
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
        formatter.dateFormat = sameYear ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func plan(_ plan: String?) -> String? {
        guard let plan, !plan.isEmpty, plan != "unknown" else { return nil }
        if plan == plan.lowercased() {
            return plan.capitalized
        }
        return plan
    }
}

struct UsageBar: View {
    let label: String
    let detail: String
    let fraction: Double
    let tint: Color

    private var normalized: Double {
        min(max(fraction.isFinite ? fraction : 0, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Token.spaceTight - 2) {
            HStack(spacing: 8) {
                Text(label)
                    .font(Token.label)
                Spacer(minLength: 8)
                Text(detail)
                    .font(Token.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.13))
                    Capsule().fill(tint).frame(width: max(3, geometry.size.width * normalized))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.25), value: normalized)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let tint: Color
    var days: Int = UsageAnalytics.chartDays

    var body: some View {
        GeometryReader { geometry in
            let points = self.points(in: geometry.size)
            ZStack(alignment: .topLeading) {
                baseline(in: geometry.size)
                if points.count >= 2, let last = points.last {
                    areaPath(points: points, height: geometry.size.height)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.18), tint.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    linePath(points: points)
                        .stroke(
                            tint,
                            style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
                        )
                    todayMarker(in: geometry.size)
                    Circle()
                        .fill(tint)
                        .frame(width: 3, height: 3)
                        .position(last)
                } else {
                    Capsule()
                        .fill(tint.opacity(0.12))
                        .frame(height: 2)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .accessibilityLabel("近 \(days) 天剩余趋势，虚线为今日起点")
    }

    private func baseline(in size: CGSize) -> Path {
        var path = Path()
        guard size.width > 0, size.height > 0 else { return path }
        path.move(to: CGPoint(x: 0, y: size.height - Token.hairline))
        path.addLine(to: CGPoint(x: size.width, y: size.height - Token.hairline))
        return path
    }

    private func todayMarker(in size: CGSize) -> some View {
        Path { path in
            let x = size.width * todayFraction
            path.move(to: CGPoint(x: x, y: 1))
            path.addLine(to: CGPoint(x: x, y: size.height - 1))
        }
        .stroke(
            Color(nsColor: .secondaryLabelColor).opacity(0.6),
            style: StrokeStyle(lineWidth: Token.hairline, dash: [1.5, 1.5])
        )
    }

    private var todayFraction: CGFloat {
        let now = Date()
        let span = TimeInterval(max(1, days)) * 86400
        let chartStart = now.addingTimeInterval(-span)
        let startOfToday = Calendar.current.startOfDay(for: now)
        let raw = startOfToday.timeIntervalSince(chartStart) / max(span, 1)
        return min(max(CGFloat(raw), 0), 1)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2, size.width > 0, size.height > 0 else { return [] }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 0
        let padding = max(1.0, (maximum - minimum) * 0.08)
        let low = max(0, minimum - padding)
        let high = maximum + padding
        let span = max(high - low, padding)
        return values.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let normalized = (value - low) / span
            let y = size.height - CGFloat(normalized) * max(1, size.height - 3) - 1.5
            return CGPoint(x: x, y: min(max(y, 1), size.height - 1))
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func areaPath(points: [CGPoint], height: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: height))
        path.addLine(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.addLine(to: CGPoint(x: last.x, y: height))
        path.closeSubpath()
        return path
    }
}

struct ProviderLink {
    let title: String
    let icon: String
    let help: String
    let action: (() -> Void)?
}

struct ProviderCard<Detail: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let plan: String?
    let value: String
    let valueCaption: String
    let secondaryValue: String?
    let status: String?
    let footer: String
    let links: [ProviderLink]
    let compact: Bool
    let detail: Detail

    init(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        plan: String? = nil,
        value: String,
        valueCaption: String,
        secondaryValue: String? = nil,
        status: String? = nil,
        footer: String,
        links: [ProviderLink] = [],
        compact: Bool = false,
        @ViewBuilder detail: () -> Detail
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
        self.plan = plan
        self.value = value
        self.valueCaption = valueCaption
        self.secondaryValue = secondaryValue
        self.status = status
        self.footer = footer
        self.links = links
        self.compact = compact
        self.detail = detail()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? Token.spaceTight + 2 : Token.spaceRow) {
            HStack(spacing: Token.spaceRow) {
                RoundedRectangle(cornerRadius: Token.radiusControl, style: .continuous)
                    .fill(color.opacity(0.14))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(color)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Token.title)
                    if !compact {
                        Text(subtitle)
                            .font(Token.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Token.spaceRow)
                if let plan {
                    Text(plan)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Token.insetFill))
                        .foregroundStyle(.secondary)
                } else {
                    Color.clear.frame(width: 24, height: 1)
                }
            }
            .frame(height: 28)

            HStack(alignment: .firstTextBaseline, spacing: Token.spaceTight) {
                Text(value)
                    .font(Token.value)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let secondaryValue {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Image(systemName: "arrow.down.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text("今日 \(secondaryValue)")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help("今日为今天 0 点至今、昨天为昨天整天的消耗，按本机历史采样估算；领取或重置带来的增加不计入消耗")
                }
                Spacer(minLength: Token.spaceTight)
                Text(valueCaption)
                    .font(Token.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
            .frame(minHeight: 27)

            VStack(alignment: .leading, spacing: Token.spaceTight) {
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: compact || status != nil ? 0 : Token.detailMinHeight, alignment: .top)

            if let status {
                HStack(alignment: .top, spacing: Token.spaceTight - 2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(status)
                        .font(Token.meta)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, Token.spaceTight)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Token.radiusControl, style: .continuous)
                        .fill(Theme.warning.opacity(0.10))
                )
                .help(status)
            }

            if compact {
                if !links.isEmpty {
                    linksRow
                }
            } else {
                Divider()
                    .overlay(Color(nsColor: .separatorColor).opacity(0.5))
                HStack(spacing: Token.spaceRow) {
                    Text(footer)
                        .font(Token.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: Token.spaceTight)
                    linksRow
                }
                .frame(height: 20)
            }
        }
        .padding(compact ? Token.spaceTight + 4 : Token.spaceCard)
        .background(
            RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                .fill(Token.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                .stroke(Token.cardStroke.opacity(0.6), lineWidth: Token.hairline)
        )
    }

    private var linksRow: some View {
        HStack(spacing: Token.spaceRow) {
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                Button {
                    link.action?()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: link.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(link.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: Token.radiusControl, style: .continuous)
                            .fill(Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .disabled(link.action == nil)
                .help(link.help)
            }
        }
        .frame(height: 20)
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case classic
    case compact
    case bars

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "数字"
        case .compact: return "紧凑"
        case .bars: return "条形"
        }
    }

    var sample: String {
        switch self {
        case .classic: return "Q 1,870   W 1,208   C 58%"
        case .compact: return "Q1.9k W1.2k C58%"
        case .bars: return "条形 + 72% 40% 58%"
        }
    }
}

/// 菜单栏上单个平台的展示数据：三种样式共用同一份，隐藏开关也在这里生效。
struct MenuBarMetric {
    let letter: String
    let value: String
    let compact: String
    let percent: String
    /// 今日消耗，与 value 同口径（积分平台是积分数，百分比平台是百分点）；样本不足时为 nil。
    let today: String?
    let todayCompact: String?
    let fraction: Double?
    let tint: Color
}

/// 菜单栏文案的组合规则，单独抽出来便于回归测试。
enum MenuBarText {
    /// 按字符数估算宽度，测试和没有字体环境时用；应用侧传入按菜单栏字体实测的宽度。
    static func estimatedWidth(_ text: String) -> CGFloat { CGFloat(text.count) }

    /// 每个平台占位到「剩余」与「今日」两拍里较宽的一拍，多出来的空格按左右半分（字母钉在组左端，
    /// 数值在组内居中）：`Q 2,649` 换成 `Q ↓139  ` 时后面的平台不左右跳，整行宽度也不呼吸
    /// （菜单栏项靠右对齐，行宽一变整串文字就平移）。字符版按整数个空格取整，两拍仍可能差
    /// 半个空格；应用侧用 `compose(_:style:showsToday:font:)` 做逐像素等宽。
    static func compose(
        _ metrics: [MenuBarMetric],
        style: MenuBarStyle,
        showsToday: Bool,
        widthOf: (String) -> CGFloat = estimatedWidth
    ) -> String {
        guard !metrics.isEmpty else { return "AI" }
        let baseline = metrics.map { segment(for: $0, style: style, showsToday: false) }
        let rolled = metrics.map { segment(for: $0, style: style, showsToday: true) }
        let current = showsToday ? rolled : baseline
        let slots = zip(baseline, rolled).map { max(widthOf($0.lead + $0.value), widthOf($1.lead + $1.value)) }
        let separator = style == .classic ? "   " : " "
        let separatorWidth = widthOf(separator)
        let spaceWidth = max(widthOf(" "), 0.0001)
        var line = ""
        var cursor: CGFloat = 0
        var ideal: CGFloat = 0
        for (index, part) in current.enumerated() {
            if index > 0 {
                line += separator
                cursor += separatorWidth
                ideal += separatorWidth
            }
            ideal += slots[index]
            let text = part.lead + part.value
            let fill = max(0, Int(((ideal - cursor - widthOf(text)) / spaceWidth).rounded()))
            let head = fill / 2
            let tail = String(repeating: " ", count: fill - head)
            let padded = part.lead + String(repeating: " ", count: head) + part.value + tail
            line += padded
            cursor += widthOf(padded)
        }
        return line
    }

    /// 应用侧的逐像素等宽版：每个平台精确占 `slots[index]` 的实测宽度，空格只能整颗补，
    /// 不足一颗的零头用 kern 加在最后一颗空格上（不足一颗时给负 kern 收缩），两拍总宽逐像素一致。
    static func compose(
        _ metrics: [MenuBarMetric],
        style: MenuBarStyle,
        showsToday: Bool,
        font: NSFont
    ) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func measure(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: attributes).size().width
        }
        guard !metrics.isEmpty else { return NSAttributedString(string: "AI", attributes: attributes) }
        let baseline = metrics.map { segment(for: $0, style: style, showsToday: false) }
        let rolled = metrics.map { segment(for: $0, style: style, showsToday: true) }
        let current = showsToday ? rolled : baseline
        let slots = zip(baseline, rolled).map { max(measure($0.lead + $0.value), measure($1.lead + $1.value)) }
        let separator = style == .classic ? "   " : " "
        let space = max(measure(" "), 0.0001)
        let line = NSMutableAttributedString()
        for (index, part) in current.enumerated() {
            if index > 0 {
                line.append(NSAttributedString(string: separator, attributes: attributes))
            }
            line.append(NSAttributedString(string: part.lead, attributes: attributes))
            let pad = slots[index] - measure(part.lead + part.value)
            if pad >= space {
                let count = Int((pad / space).rounded(.down))
                let head = count / 2
                let tail = count - head
                if head > 0 {
                    line.append(NSAttributedString(string: String(repeating: " ", count: head), attributes: attributes))
                }
                line.append(NSAttributedString(string: part.value, attributes: attributes))
                if tail > 1 {
                    line.append(NSAttributedString(string: String(repeating: " ", count: tail - 1), attributes: attributes))
                }
                // 零头补在最后一颗空格上：kern 加在字形之后，整组的实测宽度正好等于槽宽。
                let remainder = pad - CGFloat(count) * space
                if remainder > 0.05 {
                    line.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: NSNumber(value: Double(remainder))]))
                } else {
                    line.append(NSAttributedString(string: " ", attributes: attributes))
                }
            } else {
                line.append(NSAttributedString(string: part.value, attributes: attributes))
                // 零头不足一颗空格：一颗空格加负 kern，步进正好等于零头。
                if pad > 0.05 {
                    line.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: NSNumber(value: Double(pad - space))]))
                }
            }
        }
        return line
    }

    /// 滚动到「今日」时给一个下降标识；拿不到今日数据的平台继续显示剩余，两种含义靠箭头条区分。
    /// lead 与 value 分开返回，补位空格才插得进两者中间。
    private static func segment(
        for metric: MenuBarMetric,
        style: MenuBarStyle,
        showsToday: Bool
    ) -> (lead: String, value: String) {
        switch style {
        case .classic:
            return (lead: "\(metric.letter) ", value: showsToday ? metric.rolledValue : metric.value)
        case .compact:
            return (lead: metric.letter, value: showsToday ? metric.rolledCompact : metric.compact)
        case .bars:
            return (lead: "", value: metric.percent)
        }
    }
}

extension MenuBarMetric {
    var rolledValue: String { today.map { "↓\($0)" } ?? value }
    var rolledCompact: String { todayCompact.map { "↓\($0)" } ?? compact }
}

/// 条形样式左侧的小图：每个平台一列竖条，按品牌色从底部填充剩余比例。
/// 显式给 1x/2x 两种位图，避免菜单栏在 Retina 上放大糊掉。
enum MenuBarGlyph {
    static let size = NSSize(width: 15, height: 12)

    static func bars(_ metrics: [MenuBarMetric], dimmed: Bool) -> NSImage {
        let image = NSImage(size: size)
        for scale in [CGFloat(2), 1] {
            guard let rep = bitmap(metrics, dimmed: dimmed, scale: scale) else { continue }
            image.addRepresentation(rep)
        }
        return image
    }

    private static func bitmap(_ metrics: [MenuBarMetric], dimmed: Bool, scale: CGFloat) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        rep.size = size
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        draw(metrics, dimmed: dimmed)
        context.flushGraphics()
        NSGraphicsContext.current = previous
        return rep
    }

    private static func draw(_ metrics: [MenuBarMetric], dimmed: Bool) {
        let count = metrics.count
        guard count > 0 else { return }
        let rect = NSRect(origin: .zero, size: size)
        let gap: CGFloat = 2.25
        let columnWidth = (rect.width - gap * CGFloat(count - 1)) / CGFloat(count)
        let radius = min(columnWidth / 2, 1.4)
        let trackColor = NSColor.labelColor.withAlphaComponent(dimmed ? 0.10 : 0.20)
        for (index, metric) in metrics.enumerated() {
            let x = CGFloat(index) * (columnWidth + gap)
            trackColor.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: 0, width: columnWidth, height: rect.height),
                xRadius: radius,
                yRadius: radius
            ).fill()
            guard let fraction = metric.fraction, fraction > 0 else { continue }
            NSColor(metric.tint)
                .withAlphaComponent(dimmed ? 0.25 : 1)
                .setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: 0, width: columnWidth, height: max(2.5, rect.height * fraction)),
                xRadius: radius,
                yRadius: radius
            ).fill()
        }
    }
}

struct MenuContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updates: UpdateChecker
    @State private var settingsExpanded: Bool

    init(store: UsageStore, updates: UpdateChecker, settingsExpanded: Bool = false) {
        self.store = store
        self.updates = updates
        self._settingsExpanded = State(initialValue: settingsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Token.spaceSection) {
            header
            attentionStrip
            updateBanner
            providerCards
            weeklySummary
            quickBar
            if settingsExpanded {
                settingsPanel
            }
            Divider()
            aboutRow
            footer
        }
        .padding(Token.spaceSection + 2)
        .frame(width: Token.panelWidth)
        .onAppear {
            store.refreshNotificationStatus()
            updates.checkIfNeeded()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 用量")
                    .font(.system(size: 16, weight: .bold))
                Text(Providers.ordered.map(\.displayName).joined(separator: " · "))
                    .font(Token.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    store.refreshAll()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button {
                settingsExpanded.toggle()
            } label: {
                Image(systemName: settingsExpanded ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(settingsExpanded ? "收起设置" : "展开菜单栏显示、提醒与智能预警设置")
            .accessibilityLabel("设置")
        }
    }

    private var quickBar: some View {
        HStack(spacing: Token.spaceTight) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))
            ForEach(Array(store.refreshSummaries.enumerated()), id: \.offset) { index, summary in
                if index > 0 {
                    Text("·").foregroundStyle(.quaternary)
                }
                Text("\(summary.label) \(Format.time(summary.at))")
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: Token.spaceTight)
            settingChip(
                "预警 \(store.lowBalanceThreshold)%",
                isOn: $store.alertLowBalance,
                iconOn: "exclamationmark.triangle.fill",
                iconOff: "exclamationmark.triangle",
                help: "任一平台剩余低于 \(store.lowBalanceThreshold)% 时提醒"
            )
            settingChip(
                "简单",
                isOn: $store.simpleMode,
                iconOn: "rectangle.compress.vertical",
                iconOff: "rectangle.expand.vertical",
                help: "简单模式：三个平台只显示主要用量与今日消耗，隐藏预测与更新时间"
            )
            Button {
                settingsExpanded.toggle()
            } label: {
                HStack(spacing: 3) {
                    Text("设置")
                        .lineLimit(1)
                        .fixedSize()
                        .font(.system(size: 10, weight: .medium))
                    Image(systemName: settingsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(settingsExpanded ? "收起设置" : "展开更多设置")
        }
        .font(Token.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Token.spaceTight + 2)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Token.radiusControl, style: .continuous)
                .fill(Token.insetFill)
        )
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: Token.spaceRow) {
            interfaceSettings
            menuBarSettings
            reminderSettings
            alertSettings
            if store.notificationsDenied {
                HStack(spacing: 4) {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("系统通知未授权，提醒与预警不会弹出")
                    Spacer(minLength: 4)
                    Button("去开启") {
                        Apps.openURL("x-apple.systempreferences:com.apple.preference.notifications")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.warning)
                }
                .font(Token.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(Token.spaceTight + 2)
        .background(
            RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                .fill(Token.insetFill)
        )
        .transition(.opacity)
    }

    @ViewBuilder
    private var attentionStrip: some View {
        if store.isAttentionMuted {
            HStack(spacing: 4) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 10, weight: .semibold))
                Text(store.mutedDescription)
                    .font(Token.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("取消静音") {
                    store.unmuteAttention()
                }
                .buttonStyle(.plain)
                .font(Token.caption)
                .foregroundStyle(Theme.claim)
            }
            .padding(.horizontal, Token.spaceTight + 2)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Token.radiusControl, style: .continuous)
                    .fill(Token.insetFill)
            )
        } else if !store.attentionItems.isEmpty {
            VStack(alignment: .leading, spacing: Token.spaceTight) {
                ForEach(store.attentionItems) { item in
                    attentionRow(item)
                }
                HStack(spacing: 6) {
                    Text("\(store.attentionItems.count) 项需要留意")
                        .font(Token.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("静音 30 分钟") {
                        store.muteAttention()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(attentionTint.opacity(0.9))
                    .help("30 分钟内不再高亮菜单栏、也不再显示这条提示")
                }
            }
            .padding(Token.spaceRow)
            .background(
                RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                    .fill(attentionTint.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                    .stroke(attentionTint.opacity(0.32), lineWidth: Token.hairline)
            )
        }
    }

    private var attentionTint: Color {
        store.attentionKind == .warning ? Theme.danger : Theme.claim
    }

    private func attentionRow(_ item: AttentionItem) -> some View {
        HStack(alignment: .top, spacing: Token.spaceTight) {
            Image(systemName: item.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.kind == .warning ? Theme.danger : Theme.claim)
                .frame(width: 14, alignment: .top)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Token.title)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.detail)
                    .font(Token.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Token.spaceTight)
            VStack(alignment: .trailing, spacing: 3) {
                Button(item.actionTitle) {
                    store.openClient(item.provider)
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                if item.canDismiss {
                    Button("今天不再提醒") {
                        store.dismissClaimToday(item.provider)
                    }
                    .buttonStyle(.plain)
                    .font(Token.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var updateBanner: some View {
        if let release = updates.pendingRelease {
            HStack(spacing: Token.spaceRow) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.qoder)
                VStack(alignment: .leading, spacing: 1) {
                    Text("新版本 \(release.version) 可用")
                        .font(.system(size: 11, weight: .semibold))
                    Text(updateSubtitle)
                        .font(Token.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }
                Spacer(minLength: Token.spaceTight)
                Button(updates.primaryActionTitle) {
                    updates.performPrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 10, weight: .medium))
                .disabled(!updates.canPerformPrimaryAction)
            }
            .padding(Token.spaceRow)
            .background(
                RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                    .fill(Theme.qoder.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                    .stroke(Theme.qoder.opacity(0.20), lineWidth: Token.hairline)
            )
            .help(releaseHelp(release))
        } else if updates.showsResult {
            resultBanner
        }
    }

    private var resultBanner: some View {
        let failure = updates.lastError
        return HStack(spacing: Token.spaceRow) {
            Image(systemName: failure == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(failure == nil ? Theme.workbuddy : Theme.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text(failure == nil ? "已是最新版本 v\(updates.currentVersion)" : "检查更新失败")
                    .font(.system(size: 11, weight: .semibold))
                Text(
                    failure == nil
                        ? "上次检查 \(Format.time(updates.lastCheckAt)) · 每 24 小时自动检查一次"
                        : failure!
                )
                .font(Token.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: Token.spaceTight)
            Button("知道了") {
                updates.dismissResult()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 10, weight: .medium))
        }
        .padding(Token.spaceRow)
        .background(
            RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                .fill((failure == nil ? Theme.workbuddy : Theme.warning).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                .stroke((failure == nil ? Theme.workbuddy : Theme.warning).opacity(0.20), lineWidth: Token.hairline)
        )
    }

    private var updateSubtitle: String {
        switch updates.state {
        case .downloading:
            return "正在下载安装包…"
        case .ready(_, _, let verified):
            return verified
                ? "SHA-256 已校验 · 拖入「应用程序」完成升级"
                : "未找到校验值，SHA-256 未校验 · 拖入「应用程序」完成升级"
        default:
            return "当前 v\(updates.currentVersion)，可下载对应芯片安装包"
        }
    }

    private func releaseHelp(_ release: UpdateRelease) -> String {
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return "当前 v\(updates.currentVersion)" }
        return String(notes.prefix(500))
    }

    /// 三家共用一套卡片外壳，内容按额度口径与额度布局分派，新增供应商不需要再加卡片。
    @ViewBuilder
    private var providerCards: some View {
        ForEach(Providers.ordered, id: \.id) { descriptor in
            providerCard(descriptor.id)
        }
    }

    /// 本周汇总：各平台本周消耗与上周对比，细条是本周消耗占当前总额度的比例（平台分布）。
    /// 简单模式与完全没有本周数据时不占面板高度。
    @ViewBuilder
    private var weeklySummary: some View {
        if !store.simpleMode {
            let rows = Providers.ordered.compactMap { descriptor -> (ProviderDescriptor, WeeklyUsage)? in
                guard let weekly = store.weekly(for: descriptor.id), weekly.thisWeek != nil else { return nil }
                return (descriptor, weekly)
            }
            if let first = rows.first {
                VStack(alignment: .leading, spacing: Token.spaceRow) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("本周汇总")
                            .font(Token.title)
                        Spacer()
                        Text(weekRangeText(first.1))
                            .font(Token.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows, id: \.0.id) { descriptor, weekly in
                        weeklyRow(descriptor, weekly)
                    }
                }
                .padding(Token.spaceRow + 2)
                .background(
                    RoundedRectangle(cornerRadius: Token.radiusCard, style: .continuous)
                        .fill(Token.insetFill)
                )
                .help("只统计剩余量的下降，领取/重置带来的增加不计入；细条为本周消耗占当前总额度的比例。上周完全没有采样时不显示对比。")
            }
        }
    }

    private func weekRangeText(_ weekly: WeeklyUsage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        let lastDay = weekly.weekEnd.addingTimeInterval(-86400)
        return "\(formatter.string(from: weekly.weekStart))–\(formatter.string(from: lastDay))"
    }

    private func weeklyRow(_ descriptor: ProviderDescriptor, _ weekly: WeeklyUsage) -> some View {
        let total = store.result(for: descriptor.id)?.total
        let fraction: Double = {
            guard let value = weekly.thisWeek else { return 0 }
            if weekly.isPercent { return min(1, value / 100) }
            guard let total, total > 0 else { return 0 }
            return min(1, value / total)
        }()
        return HStack(spacing: 8) {
            Circle()
                .fill(descriptor.color)
                .frame(width: 6, height: 6)
            Text(descriptor.displayName)
                .font(Token.label)
                .frame(width: 70, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(descriptor.color.opacity(0.15))
                    Capsule()
                        .fill(descriptor.color.opacity(0.75))
                        .frame(width: max(2, proxy.size.width * fraction))
                }
            }
            .frame(height: 3)
            VStack(alignment: .trailing, spacing: 1) {
                Text(weeklyValueText(weekly.thisWeek, isPercent: weekly.isPercent))
                    .font(Token.body)
                Text(weekly.lastWeek.map { "上周 \(weeklyValueText($0, isPercent: weekly.isPercent))" } ?? "上周 —")
                    .font(Token.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 96, alignment: .trailing)
        }
    }

    private func weeklyValueText(_ value: Double?, isPercent: Bool) -> String {
        guard let value else { return "--" }
        return isPercent ? Format.percentDetailed(value) : "\(Format.credits(value)) 额度"
    }

    private func providerCard(_ provider: UsageProvider) -> some View {
        let descriptor = provider.descriptor
        return ProviderCard(
            title: descriptor.displayName,
            subtitle: descriptor.subtitle,
            icon: descriptor.icon,
            color: descriptor.color,
            plan: Format.plan(store.result(for: provider)?.plan),
            value: cardValue(provider),
            valueCaption: cardCaption(provider),
            secondaryValue: store.simpleMode ? cardTodayValue(provider) : nil,
            status: store.error(for: provider),
            footer: cardFooter(provider),
            links: cardLinks(provider),
            compact: store.simpleMode
        ) {
            providerContent(provider)
        }
    }

    private func cardValue(_ provider: UsageProvider) -> String {
        guard let result = store.result(for: provider), result.ok == true else { return "--" }
        switch provider.quotaKind {
        case .credits:
            return Format.credits(result.remaining)
        case .percentWindow:
            guard let window = result.primaryWindow else { return "--" }
            return Format.percent(window.remainingPercent)
        }
    }

    private func cardCaption(_ provider: UsageProvider) -> String {
        guard let result = store.result(for: provider), result.ok == true else { return "等待采集" }
        switch provider.quotaKind {
        case .credits:
            guard let total = result.total, total > 0 else { return "等待采集" }
            return "剩余 / 共 \(Format.credits(total)) \(provider.descriptor.creditUnit)"
        case .percentWindow:
            guard let window = result.primaryWindow else { return "等待采集" }
            return "\(Format.window(window.windowMinutes))窗口剩余"
        }
    }

    /// 简单模式更关心「今天用了多少」，今日消耗并进剩余量那一行；口径与常规模式的洞察行一致。
    /// 单看今日判断不了多不多，所以带上昨天全天做参照；昨天没采满时只显示今日。
    /// 参照是「昨天一整天」而不是「昨天同一时刻」：用量按工作时段成片出现，同时段对比会在
    /// 早上给出「今日 85 · 昨天 4」这种看着像坏数的数字。
    private func cardTodayValue(_ provider: UsageProvider) -> String? {
        guard let insight = store.insight(for: provider), let today = insight.todayConsumed else { return nil }
        let current = consumptionText(today, percent: insight.isPercent)
        guard let yesterday = insight.yesterdayConsumed else { return current }
        return "\(current) · 昨天 \(consumptionText(yesterday, percent: insight.isPercent))"
    }

    private func consumptionText(_ value: Double, percent: Bool) -> String {
        percent ? Format.percentDetailed(value) : Format.credits(value)
    }

    private func cardFooter(_ provider: UsageProvider) -> String {
        let result = store.result(for: provider)
        if store.error(for: provider) != nil, result != nil {
            return "上次成功 \(Format.time(result?.updatedDate))"
        }
        return "更新于 \(Format.time(result?.updatedDate ?? store.lastCollectedAt(for: provider)))"
    }

    private func cardLinks(_ provider: UsageProvider) -> [ProviderLink] {
        let descriptor = provider.descriptor
        var links = [
            ProviderLink(
                title: "打开",
                icon: "arrow.up.forward.app",
                help: descriptor.clientHelp
            ) {
                Apps.open(bundleID: descriptor.clientBundleID, fallback: descriptor.clientAppPath)
            },
            ProviderLink(
                title: "官网",
                icon: "globe",
                help: descriptor.websiteHelp
            ) {
                Apps.openURL(descriptor.websiteURL)
            },
        ]
        if descriptor.setup == .qoderCLI {
            links.append(contentsOf: qoderSetupLinks())
        }
        return links
    }

    /// Qoder 走 CLI 采集，未安装/未登录时把安装与授权动作放进卡片链接里。
    @ViewBuilder
    private func providerContent(_ provider: UsageProvider) -> some View {
        switch provider.quotaKind {
        case .credits:
            creditsContent(provider)
        case .percentWindow:
            windowContent(provider)
        }
    }

    @ViewBuilder
    private func creditsContent(_ provider: UsageProvider) -> some View {
        let descriptor = provider.descriptor
        if store.simpleMode {
            simpleCreditsBar(provider)
        } else if let result = store.result(for: provider) {
            switch descriptor.creditLayout ?? .resourcePackage {
            case .planBreakdown:
                let addonTotal = result.addonTotal ?? 0
                let addonUsed = result.addonUsed ?? 0
                let planTotal = result.planTotal ?? 0
                let planUsed = result.planUsed ?? 0
                if addonTotal > 0 {
                    UsageBar(
                        label: "附加额度",
                        detail: "已用 \(Format.credits(addonUsed)) / \(Format.credits(addonTotal))",
                        fraction: addonUsed / addonTotal,
                        tint: descriptor.color
                    )
                }
                if planTotal > 0 {
                    UsageBar(
                        label: "套餐额度",
                        detail: "已用 \(Format.credits(planUsed)) / \(Format.credits(planTotal))",
                        fraction: planUsed / planTotal,
                        tint: descriptor.color
                    )
                }
                if addonTotal == 0 && planTotal == 0 {
                    Text("当前套餐未包含额度")
                        .font(Token.meta)
                        .foregroundStyle(.secondary)
                }
                if let expires = result.planExpiresAt, expires != "N/A", !expires.isEmpty {
                    Text("套餐到期 \(expires)")
                        .font(Token.caption)
                        .foregroundStyle(.secondary)
                }
                if let org = result.orgResourcePackage, org != "N/A", !org.isEmpty {
                    Text("组织资源包 \(org)")
                        .font(Token.caption)
                        .foregroundStyle(.secondary)
                }
                insightRow(provider)
                forecastRow(provider, tint: descriptor.color)
            case .resourcePackage:
                if let total = result.total, total > 0 {
                    UsageBar(
                        label: "额度",
                        detail: "已用 \(Format.credits(result.used)) / \(Format.credits(total))",
                        fraction: (result.usedPercent ?? 0) / 100,
                        tint: descriptor.color
                    )
                    if let packages = result.packages, packages > 0 {
                        Text("\(packages) 个资源包")
                            .font(Token.caption)
                            .foregroundStyle(.secondary)
                    }
                    insightRow(provider)
                    forecastRow(provider, tint: descriptor.color)
                } else {
                    Text("暂无可用的额度资源包")
                        .font(Token.meta)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            emptyContent
        }
    }

    /// 简单模式只保留最能代表当前余额的一条进度条。
    @ViewBuilder
    private func simpleCreditsBar(_ provider: UsageProvider) -> some View {
        let descriptor = provider.descriptor
        if let result = store.result(for: provider) {
            switch descriptor.creditLayout ?? .resourcePackage {
            case .planBreakdown:
                let planTotal = result.planTotal ?? 0
                let planUsed = result.planUsed ?? 0
                let addonTotal = result.addonTotal ?? 0
                let addonUsed = result.addonUsed ?? 0
                if planTotal > 0 {
                    UsageBar(
                        label: "套餐额度",
                        detail: "已用 \(Format.credits(planUsed)) / \(Format.credits(planTotal))",
                        fraction: planUsed / planTotal,
                        tint: descriptor.color
                    )
                } else if addonTotal > 0 {
                    UsageBar(
                        label: "附加额度",
                        detail: "已用 \(Format.credits(addonUsed)) / \(Format.credits(addonTotal))",
                        fraction: addonUsed / addonTotal,
                        tint: descriptor.color
                    )
                } else {
                    Text("当前套餐未包含额度")
                        .font(Token.meta)
                        .foregroundStyle(.secondary)
                }
            case .resourcePackage:
                if let total = result.total, total > 0 {
                    UsageBar(
                        label: "额度",
                        detail: "已用 \(Format.credits(result.used)) / \(Format.credits(total))",
                        fraction: (result.usedPercent ?? 0) / 100,
                        tint: descriptor.color
                    )
                } else {
                    Text("暂无可用的额度资源包")
                        .font(Token.meta)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            emptyContent
        }
    }

    @ViewBuilder
    private func windowContent(_ provider: UsageProvider) -> some View {
        let descriptor = provider.descriptor
        if store.simpleMode {
            simpleWindowBar(provider)
        } else if let result = store.result(for: provider) {
            if let windows = result.windows, !windows.isEmpty {
                ForEach(windows) { window in
                    UsageBar(
                        label: "\(Format.window(window.windowMinutes))窗口",
                        detail: "已用 \(Format.percent(window.usedPercent)) · 剩余 \(Format.percent(window.remainingPercent))",
                        fraction: (window.usedPercent ?? 0) / 100,
                        tint: descriptor.color
                    )
                }
                if let reset = windows.first?.resetsAt {
                    Text("重置于 \(Format.reset(reset))")
                        .font(Token.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("当前账号没有限额窗口")
                    .font(Token.meta)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("额外额度")
                Spacer()
                if let credits = result.credits, credits.hasCredits == true {
                    Text(credits.unlimited == true ? "无限" : "余额 \(Format.credits(credits.balance, digits: 2))")
                } else {
                    Text("无")
                }
            }
            .font(Token.caption)
            .foregroundStyle(.secondary)
            if let resetCredits = result.resetCredits, resetCredits > 0 {
                HStack(spacing: 8) {
                    Text("重置积分")
                    Spacer()
                    Text("\(resetCredits) 个")
                }
                .font(Token.caption)
                .foregroundStyle(.secondary)
            }
            insightRow(provider)
            forecastRow(provider, tint: descriptor.color)
        } else {
            emptyContent
        }
    }

    @ViewBuilder
    private func simpleWindowBar(_ provider: UsageProvider) -> some View {
        if let result = store.result(for: provider) {
            if let window = result.primaryWindow {
                UsageBar(
                    label: "\(Format.window(window.windowMinutes))窗口",
                    detail: "已用 \(Format.percent(window.usedPercent)) · 剩余 \(Format.percent(window.remainingPercent))",
                    fraction: (window.usedPercent ?? 0) / 100,
                    tint: provider.descriptor.color
                )
            } else {
                Text("当前账号没有限额窗口")
                    .font(Token.meta)
                    .foregroundStyle(.secondary)
            }
        } else {
            emptyContent
        }
    }

    private func qoderSetupLinks() -> [ProviderLink] {
        var links: [ProviderLink] = []
        switch store.qoderSetup {
        case .installing:
            links.append(ProviderLink(
                title: "安装中",
                icon: "arrow.down.circle",
                help: "正在下载并执行官方安装脚本，约需 1-2 分钟"
            ) {})
        case .preparing:
            links.append(ProviderLink(
                title: "准备授权",
                icon: "link",
                help: "正在获取登录授权链接"
            ) {})
        case .waitingAuth(let url):
            links.append(ProviderLink(
                title: "等待授权",
                icon: "link",
                help: "在浏览器完成登录后会自动刷新；点击可重新打开授权页"
            ) {
                NSWorkspace.shared.open(url)
            })
            links.append(ProviderLink(
                title: "取消",
                icon: "xmark",
                help: "取消本次登录"
            ) {
                store.cancelQoderSetup()
            })
        case .failed(let message):
            links.append(ProviderLink(
                title: "重试登录",
                icon: "arrow.clockwise",
                help: message
            ) {
                store.loginQoderCLI()
            })
            links.append(ProviderLink(
                title: "终端处理",
                icon: "terminal",
                help: "授权页无法完成时，在终端手动执行登录：" + message
            ) {
                Apps.openTerminal("~/.local/bin/qoderclicn login")
            })
        case .idle:
            if let error = store.error(for: .qoder) {
                if error.contains("未登录") {
                    links.append(ProviderLink(
                        title: "登录",
                        icon: "person.crop.circle.badge.questionmark",
                        help: "在浏览器完成 Qoder CLI 登录"
                    ) {
                        store.loginQoderCLI()
                    })
                } else if error.contains("未安装") {
                    links.append(ProviderLink(
                        title: "安装 CLI",
                        icon: "arrow.down.circle",
                        help: "下载并安装官方 Qoder CLI，完成后自动登录"
                    ) {
                        store.installQoderCLI()
                    })
                }
            }
        }
        return links
    }

    @ViewBuilder
    private func forecastRow(_ provider: UsageProvider, tint: Color) -> some View {
        if let forecast = store.forecast(for: provider) {
            HStack(spacing: 7) {
                Sparkline(values: forecast.values, tint: tint)
                    .frame(width: 62, height: 18)
                Text(forecast.text)
                    .font(.system(size: 10, weight: forecast.warning ? .semibold : .regular))
                    .foregroundStyle(forecast.warning ? Theme.warning : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .help(forecast.help)
        }
    }

    @ViewBuilder
    private func insightRow(_ provider: UsageProvider) -> some View {
        if let insight = store.insight(for: provider) {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 10, weight: .semibold))
                Text(insightText(insight))
                    .font(Token.meta)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .help("按本机历史采样估算，领取或重置带来的增加不计入消耗；日均需至少 6 小时样本，已观察 \(insight.observedDays) 天。")
        }
    }

    private func insightText(_ insight: UsageInsight) -> String {
        let today = insight.todayConsumed.map {
            "今日消耗 \(insightValue($0, percent: insight.isPercent))"
        } ?? "今日消耗 --"
        let average = insight.dailyAverage.map {
            "近7日日均 \(insightValue($0, percent: insight.isPercent))/天"
        } ?? "近7日日均 --"
        return "\(today) · \(average)"
    }

    private func insightValue(_ value: Double, percent: Bool) -> String {
        if percent {
            return Format.percentDetailed(value)
        }
        return "\(Format.credits(value)) 额度"
    }

    private var emptyContent: some View {
        Text("暂无数据")
            .font(Token.meta)
            .foregroundStyle(.secondary)
    }

    private func settingRow<Chips: View>(
        _ label: String,
        @ViewBuilder chips: () -> Chips
    ) -> some View {
        HStack(spacing: Token.spaceTight) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            chips()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var interfaceSettings: some View {
        settingRow("界面") {
            settingChip(
                "简单模式",
                isOn: $store.simpleMode,
                iconOn: "rectangle.compress.vertical",
                iconOff: "rectangle.expand.vertical",
                help: "三个平台只显示主要用量与今日消耗，隐藏预测与更新时间"
            )
        }
    }

    @ViewBuilder
    private var menuBarSettings: some View {
        settingRow("样式") {
            ForEach(MenuBarStyle.allCases) { style in
                styleChip(style)
            }
        }
        settingRow("菜单栏") {
            ForEach(Providers.ordered, id: \.id) { descriptor in
                settingChip(
                    descriptor.displayName,
                    isOn: store.menuBarBinding(for: descriptor.id),
                    iconOn: "eye.fill",
                    iconOff: "eye.slash",
                    help: "在菜单栏显示 \(descriptor.displayName)"
                )
            }
        }
        settingRow("注意力") {
            settingChip(
                "高亮",
                isOn: $store.menuBarHighlight,
                iconOn: "paintbrush.pointed.fill",
                iconOff: "paintbrush.pointed",
                help: "有告警时菜单栏文字变红并加 ⚠，待领取时变橙色"
            )
            settingChip(
                "闪动",
                isOn: $store.menuBarBlink,
                iconOn: "lightbulb.fill",
                iconOff: "lightbulb",
                help: "新提醒出现后菜单栏闪动 60 秒，打开面板即停止"
            )
        }
    }

    private var reminderSettings: some View {
        settingRow("提醒") {
            ForEach(Providers.ordered, id: \.id) { descriptor in
                settingChip(
                    descriptor.displayName,
                    isOn: store.reminderBinding(for: descriptor.id),
                    iconOn: "bell.fill",
                    iconOff: "bell.slash",
                    help: reminderHelp(descriptor)
                )
            }
        }
    }

    /// 提醒开关的说明文字直接由注册表里的提醒形态拼出来，避免两处文案各写一份。
    private func reminderHelp(_ descriptor: ProviderDescriptor) -> String {
        switch descriptor.claimReminder {
        case .daily(let hour, let grant, _):
            return "每天 \(String(format: "%02d", hour)):00 提醒领取 \(descriptor.displayName) \(grant)"
        case .windowReset:
            return "\(descriptor.displayName) 额度重置时提醒"
        }
    }

    private var alertSettings: some View {
        VStack(alignment: .leading, spacing: Token.spaceTight - 1) {
            settingRow("智能预警") {
                settingChip(
                    "低额度",
                    isOn: $store.alertLowBalance,
                    iconOn: "exclamationmark.triangle.fill",
                    iconOff: "exclamationmark.triangle",
                    help: "剩余低于 \(store.lowBalanceThreshold)% 时提醒"
                )
                settingChip(
                    "重置前耗尽",
                    isOn: $store.alertExhaustion,
                    iconOn: "clock.fill",
                    iconOff: "clock",
                    help: "Codex 预计在额度重置前耗尽时提醒"
                )
                settingChip(
                    "消耗加速",
                    isOn: $store.alertAcceleration,
                    iconOn: "bolt.fill",
                    iconOff: "bolt",
                    help: "近 15 分钟消耗速度明显高于此前 1 小时时提醒"
                )
            }
            if store.alertLowBalance {
                settingRow("低额度阈值") {
                    ForEach([10, 20, 30], id: \.self) { value in
                        thresholdChip(value)
                    }
                }
            }
            settingRow("月度预算") {
                TextField("0", value: $store.monthlyBudget, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                    .font(.system(size: 10))
                    .monospacedDigit()
                Text("额度")
                    .font(Token.caption)
                    .foregroundStyle(.secondary)
                Text("0 关闭")
                    .font(Token.caption)
                    .foregroundStyle(.tertiary)
            }
            .help("额度制平台本月消耗超过该值时提醒，每家独立计数；填 0 关闭。")
        }
    }

    private func thresholdChip(_ value: Int) -> some View {
        let selected = store.lowBalanceThreshold == value
        return Button("\(value)%") {
            store.lowBalanceThreshold = value
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: selected ? .semibold : .regular))
        .monospacedDigit()
        .foregroundStyle(selected ? Theme.warning : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(selected ? Theme.warning.opacity(0.14) : Token.insetFill)
        )
        .overlay(
            Capsule().stroke(
                selected ? Theme.warning.opacity(0.28) : Token.cardStroke.opacity(0.5),
                lineWidth: Token.hairline
            )
        )
        .help("低于 \(value)% 时提醒，恢复至 \(value + Int(UsageAnalytics.lowRecoveryGap))% 以上后重新布防")
    }

    private func styleChip(_ style: MenuBarStyle) -> some View {
        let selected = store.menuBarStyle == style
        return Button {
            store.menuBarStyle = style
        } label: {
            Text(style.title)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .fixedSize()
                .foregroundStyle(selected ? Theme.qoder : Color.secondary)
                .background(
                    Capsule().fill(selected ? Theme.qoder.opacity(0.14) : Token.insetFill)
                )
                .overlay(
                    Capsule().stroke(
                        selected ? Theme.qoder.opacity(0.28) : Token.cardStroke.opacity(0.5),
                        lineWidth: Token.hairline
                    )
                )
        }
        .buttonStyle(.plain)
        .help("菜单栏显示 \(style.sample)")
    }

    private func settingChip(
        _ title: String,
        isOn: Binding<Bool>,
        iconOn: String,
        iconOff: String,
        help: String
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn.wrappedValue ? iconOn : iconOff)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .fixedSize()
            .foregroundStyle(isOn.wrappedValue ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: Token.radiusControl, style: .continuous)
                    .fill(isOn.wrappedValue ? Color.primary.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Token.radiusControl, style: .continuous)
                    .stroke(
                        Token.cardStroke.opacity(isOn.wrappedValue ? 0.8 : 0.4),
                        lineWidth: Token.hairline
                    )
            )
        }
        .buttonStyle(.plain)
        .help("\(help)（\(isOn.wrappedValue ? "已开启" : "已关闭")）")
    }

    private var aboutRow: some View {
        HStack(spacing: 5) {
            Text("v\(updates.currentVersion)")
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.quaternary)
            Button("GitHub") {
                Apps.openURL("https://github.com/pumf/token_tool")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("打开项目源码")
            Text("·")
                .foregroundStyle(.quaternary)
            Button("MIT") {
                if let license = Bundle.main.url(forResource: "LICENSE", withExtension: "txt") {
                    NSWorkspace.shared.open(license)
                } else {
                    Apps.openURL("https://opensource.org/license/mit")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("查看随应用附带的 MIT 许可证")
            if let lastCheckAt = updates.lastCheckAt {
                Text("·")
                    .foregroundStyle(.quaternary)
                Text("检查于 \(Format.ago(lastCheckAt))")
                    .foregroundStyle(.tertiary)
                    .help("GitHub Releases 检查节奏为每 24 小时一次，也可点击右侧按钮立即检查")
            }
            Spacer(minLength: 4)
            updateControl
        }
        .font(Token.meta)
    }

    @ViewBuilder
    private var updateControl: some View {
        switch updates.state {
        case .checking:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("检查中")
            }
            .foregroundStyle(.secondary)
        case .downloading:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("下载中")
            }
            .foregroundStyle(.secondary)
        case .ready:
            Text("安装包已就绪")
                .foregroundStyle(.secondary)
        case .upToDate:
            Button("已是最新 · \(Format.time(updates.lastCheckAt))") {
                updates.checkFromUser()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("上次检查 \(Format.ago(updates.lastCheckAt))；每 24 小时自动检查一次，点击立即重新检查")
        case .failed(let message):
            Button("重试检查") {
                updates.checkFromUser()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.warning)
            .help(message)
        case .idle, .available:
            Button("检查更新") {
                updates.checkFromUser()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("从 GitHub Releases 检查新版本（当前 v\(updates.currentVersion)）")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle(
                isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                )
            ) {
                Text("开机启动")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Spacer()
            Menu {
                Button("近 7 天") { store.exportHistory(days: 7) }
                Button("近 14 天") { store.exportHistory(days: 14) }
                Button("近 30 天") { store.exportHistory(days: 30) }
                Button("近 90 天") { store.exportHistory(days: 90) }
            } label: {
                Text("导出")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("按范围导出用量历史为 CSV")
            Button("诊断") {
                Apps.revealDiagnostics()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .help("在 Finder 中显示本地诊断日志（已脱敏，不含凭据与账号信息）")
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}

struct MenuPanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updates: UpdateChecker
    let maxHeight: CGFloat
    var onHeightChange: ((CGFloat) -> Void)? = nil

    /// 内容自然高度（未裁剪）；为 0 表示还没量过，先按 maxHeight 撑开。
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: contentHeight > maxHeight + 0.5) {
            MenuContent(store: store, updates: updates)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: PanelContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .frame(width: Token.panelWidth, height: panelHeight)
        .background(.regularMaterial)
        .onPreferenceChange(PanelContentHeightKey.self) { height in
            let rounded = ceil(height)
            guard rounded > 0, abs(rounded - contentHeight) > 0.5 else { return }
            contentHeight = rounded
            onHeightChange?(rounded)
        }
    }

    private var panelHeight: CGFloat {
        guard contentHeight > 0 else { return maxHeight }
        return min(contentHeight, maxHeight)
    }
}

private struct PanelContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum Apps {
    static func open(bundleID: String, fallback: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: fallback),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    static func confirm(title: String, info: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    static func revealDiagnostics() {
        let log = Diagnostics.logURL
        let manager = FileManager.default
        try? manager.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            NSWorkspace.shared.open(log.deletingLastPathComponent())
        }
    }

    static func openTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\" to do script \"\(escaped)\"\ntell application \"Terminal\" to activate"
        NSAppleScript(source: source)?.executeAndReturnError(nil)
    }
}
