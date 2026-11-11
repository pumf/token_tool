import SwiftUI
import AppKit
import Combine
@preconcurrency import UserNotifications

@MainActor
final class UsageStore: ObservableObject {
    /// 一家供应商的运行态。名称、口径、采集节奏、客户端等静态属性都在 Providers 注册表里，
    /// 这里只按供应商索引保存会随采集变化的数据。
    struct ProviderState {
        var result: ProviderResult?
        var error: String?
        var history: [UsageSample] = []
        var lastCollectedAt: Date?
        var isRefreshing = false
    }

    @Published private var states: [UsageProvider: ProviderState] = [:]
    /// 菜单栏显示与领取提醒的开关；落盘键名由注册表登记，保持与旧版本一致。
    @Published private var menuBarVisibility: [UsageProvider: Bool] = [:]
    @Published private var reminderVisibility: [UsageProvider: Bool] = [:]
    /// 菜单栏当前显示的是剩余量还是今日消耗，由应用侧的滚动定时器翻转。
    /// 有意不做 @Published：滚动只影响菜单栏标题，由定时器自己重绘，避免每 5 秒触发一次面板测量。
    private(set) var menuBarShowsToday = false
    @Published private(set) var launchAtLogin = LaunchAtLogin.isEnabled
    @Published var alertLowBalance: Bool {
        didSet {
            UserDefaults.standard.set(alertLowBalance, forKey: "alert.low")
            prepareNotificationAuthorization()
            recomputeAttention(now: Date())
        }
    }
    @Published var alertExhaustion: Bool {
        didSet {
            UserDefaults.standard.set(alertExhaustion, forKey: "alert.exhaustion")
            prepareNotificationAuthorization()
            recomputeAttention(now: Date())
        }
    }
    @Published var alertAcceleration: Bool {
        didSet {
            UserDefaults.standard.set(alertAcceleration, forKey: "alert.acceleration")
            prepareNotificationAuthorization()
        }
    }
    @Published var lowBalanceThreshold: Int {
        didSet {
            UserDefaults.standard.set(lowBalanceThreshold, forKey: "alert.low.threshold")
            resetLowAlertState()
            recomputeAttention(now: Date())
        }
    }
    /// 额度制平台的月度预算（额度），本月消耗超过它时告警；0 表示关闭。
    @Published var monthlyBudget: Int {
        didSet {
            // 不能再无条件写回 monthlyBudget：didSet 里改自己是无限递归，会把栈跑爆直接崩溃。
            let clamped = max(0, monthlyBudget)
            if clamped != monthlyBudget {
                monthlyBudget = clamped
            }
            UserDefaults.standard.set(clamped, forKey: "alert.budget.monthly")
            recomputeAttention(now: Date())
        }
    }
    @Published var menuBarHighlight: Bool {
        didSet { UserDefaults.standard.set(menuBarHighlight, forKey: "attention.menuBar.highlight") }
    }
    @Published var menuBarBlink: Bool {
        didSet { UserDefaults.standard.set(menuBarBlink, forKey: "attention.menuBar.blink") }
    }
    /// 面板密度：常规 / 简单 / 极简。旧版本只有 ui.simpleMode 布尔，首次启动时迁移。
    @Published var density: PanelDensity {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "ui.density") }
    }
    /// 简单与极简都属于「收起来」，卡片外壳的紧凑排法沿用这个判断。
    var simpleMode: Bool { density != .full }
    var minimalMode: Bool { density == .minimal }
    /// 卡片顺序，用户拖动后写入 ui.card.order；注册表顺序是兜底默认值。
    @Published var cardOrder: [UsageProvider] {
        didSet { UserDefaults.standard.set(cardOrder.map(\.rawValue), forKey: "ui.card.order") }
    }
    /// 面板、本周汇总、菜单栏文字都走同一套顺序，新接入的一家永远排在末尾。
    var panelProviders: [ProviderDescriptor] { cardOrder.map { $0.descriptor } }
    @Published var menuBarStyle: MenuBarStyle {
        didSet { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBar.style") }
    }
    /// 全局快捷键 ⌥⇧T 展开/收起面板。
    @Published var hotKeyEnabled: Bool {
        didSet { UserDefaults.standard.set(hotKeyEnabled, forKey: "hotkey.enabled") }
    }
    @Published private(set) var attentionItems: [AttentionItem] = []
    @Published private(set) var attentionSince: Date?
    @Published private(set) var mutedUntil: Date?
    @Published private(set) var notificationsDenied = false

    private lazy var notificationCenter = UNUserNotificationCenter.current()

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenTool/cache.json")
    }

    private static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenTool/history.json")
    }

    /// 每次写入前轮换出来的上一份历史，主文件损坏时用它回退。
    private static var historyBackupURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenTool/history.json.bak")
    }

    private var refreshTimers: [Timer] = []

    private static func storedFlag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private static func storedLowThreshold() -> Int {
        let value = UserDefaults.standard.integer(forKey: "alert.low.threshold")
        return [10, 20, 30].contains(value) ? value : 20
    }

    private static func storedDensity() -> PanelDensity {
        PanelDensity.stored(
            raw: UserDefaults.standard.string(forKey: "ui.density"),
            legacySimple: UserDefaults.standard.object(forKey: "ui.simpleMode") as? Bool
        )
    }

    private static func storedCardOrder() -> [UsageProvider] {
        Providers.order(stored: UserDefaults.standard.stringArray(forKey: "ui.card.order") ?? [])
    }

    /// 注册表里的刷新节奏分组，间隔小的排在前面。
    private static let groups = Providers.groups

    init(refreshOnStart: Bool = true) {
        alertLowBalance = Self.storedFlag("alert.low")
        alertExhaustion = Self.storedFlag("alert.exhaustion")
        alertAcceleration = Self.storedFlag("alert.acceleration")
        lowBalanceThreshold = Self.storedLowThreshold()
        monthlyBudget = max(0, UserDefaults.standard.integer(forKey: "alert.budget.monthly"))
        menuBarHighlight = Self.storedFlag("attention.menuBar.highlight")
        menuBarBlink = Self.storedFlag("attention.menuBar.blink")
        density = Self.storedDensity()
        cardOrder = Self.storedCardOrder()
        menuBarStyle = MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: "menuBar.style") ?? "") ?? .classic
        hotKeyEnabled = Self.storedFlag("hotkey.enabled")
        let muteEpoch = UserDefaults.standard.double(forKey: "attention.mute.until")
        mutedUntil = muteEpoch > 0 ? Date(timeIntervalSince1970: muteEpoch) : nil
        for descriptor in Providers.all {
            states[descriptor.id] = ProviderState()
            menuBarVisibility[descriptor.id] = UserDefaults.standard.object(forKey: descriptor.menuBarDefaultsKey) as? Bool ?? descriptor.defaultInMenuBar
            reminderVisibility[descriptor.id] = Self.storedFlag(descriptor.reminderDefaultsKey)
        }
        loadCache()
        loadHistory()
        seedHistoryFromCache()
        recomputeAttention(now: Date())
        guard refreshOnStart else { return }
        refreshReminders()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.prepareNotificationAuthorization()
        }
        // 采集器都是子进程，启动时按分组错峰开跑，避免几家的 python3 同时抢 CPU。
        for (index, group) in Self.groups.enumerated() {
            let delay = Double(index) * 1.2
            if delay == 0 {
                refresh(group.providers)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.refresh(group.providers)
                }
            }
        }
        scheduleTimers()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    // MARK: 按供应商索引的运行态

    func result(for provider: UsageProvider) -> ProviderResult? { states[provider]?.result }
    func error(for provider: UsageProvider) -> String? { states[provider]?.error }
    func history(for provider: UsageProvider) -> [UsageSample] { states[provider]?.history ?? [] }
    func lastCollectedAt(for provider: UsageProvider) -> Date? { states[provider]?.lastCollectedAt }
    func isRefreshing(_ provider: UsageProvider) -> Bool { states[provider]?.isRefreshing ?? false }
    func isShownInMenuBar(_ provider: UsageProvider) -> Bool { menuBarVisibility[provider] ?? true }
    func isReminderEnabled(_ provider: UsageProvider) -> Bool { reminderVisibility[provider] ?? true }

    func menuBarBinding(for provider: UsageProvider) -> Binding<Bool> {
        Binding(
            get: { self.isShownInMenuBar(provider) },
            set: { value in
                self.menuBarVisibility[provider] = value
                UserDefaults.standard.set(value, forKey: provider.descriptor.menuBarDefaultsKey)
            }
        )
    }

    func reminderBinding(for provider: UsageProvider) -> Binding<Bool> {
        Binding(
            get: { self.isReminderEnabled(provider) },
            set: { value in
                self.reminderVisibility[provider] = value
                UserDefaults.standard.set(value, forKey: provider.descriptor.reminderDefaultsKey)
                self.reminderSettingChanged()
            }
        )
    }

    /// 拖到另一张卡片上：拖动的那张落到目标当前的槽位，其余依次补位。
    func moveCard(_ dragged: UsageProvider, onto target: UsageProvider) {
        cardOrder = Providers.moved(cardOrder, dragged, onto: target)
    }

    /// 右键菜单的兜底通道：菜单栏面板里拖动不一定稳，上移/下移/置顶总能用。
    func shiftCard(_ provider: UsageProvider, by offset: Int) {
        cardOrder = Providers.shifted(cardOrder, provider, by: offset)
    }

    func resetCardOrder() {
        cardOrder = Providers.all.map(\.id)
    }

    /// 页脚的采集时间戳：节奏最快的一组沿用的是「刷新」这个叫法，其余按组内供应商名。
    var refreshSummaries: [(label: String, at: Date?)] {
        Self.groups.enumerated().map { index, group in
            let label = index == 0
                ? "刷新"
                : group.providers.map(\.displayName).joined(separator: "/")
            let at = group.providers.compactMap { states[$0]?.lastCollectedAt }.max()
            return (label, at)
        }
    }

    var isRefreshing: Bool { Providers.all.contains { self.isRefreshing($0.id) } }
    var lowThreshold: Double { Double(lowBalanceThreshold) }
    var lowRecovery: Double { lowThreshold + UsageAnalytics.lowRecoveryGap }

    var attentionKind: AttentionKind { attentionItems.map(\.kind).max() ?? .none }
    var isAttentionMuted: Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > Date()
    }
    var mutedDescription: String {
        guard let mutedUntil else { return "" }
        return "静音中，\(Format.time(mutedUntil)) 自动恢复提醒"
    }

    private(set) var attentionIdentity: String = ""

    /// 菜单栏是否需要闪动：新出现的提醒在 60 秒内、且用户还没打开过面板。
    func attentionBlinkActive(now: Date) -> Bool {
        guard menuBarHighlight, menuBarBlink, !isAttentionMuted, attentionKind != .none else {
            return false
        }
        guard let since = attentionSince, acknowledgedAt < since else { return false }
        return now.timeIntervalSince(since) <= UsageAnalytics.attentionBlinkDuration
    }

    func markAttentionSeen() {
        acknowledgedAt = Date()
    }

    private var acknowledgedAt = Date.distantPast

    func muteAttention(minutes: Int = 30) {
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        mutedUntil = until
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: "attention.mute.until")
        recomputeAttention(now: Date())
    }

    func unmuteAttention() {
        mutedUntil = nil
        UserDefaults.standard.removeObject(forKey: "attention.mute.until")
        recomputeAttention(now: Date())
    }

    func dismissClaimToday(_ provider: UsageProvider) {
        UserDefaults.standard.set(
            Self.dayKey(Date()),
            forKey: "attention.claim.dismiss.\(provider.rawValue)"
        )
        recomputeAttention(now: Date())
    }

    func openClient(_ provider: UsageProvider) {
        let descriptor = provider.descriptor
        Apps.open(bundleID: descriptor.clientBundleID, fallback: descriptor.clientAppPath)
    }

    private static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func monthKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private func recomputeAttention(now: Date) {
        if let mutedUntil, mutedUntil <= now {
            self.mutedUntil = nil
            UserDefaults.standard.removeObject(forKey: "attention.mute.until")
        }
        var items: [AttentionItem] = []
        if mutedUntil == nil {
            for provider in UsageProvider.allCases {
                guard let result = availableResult(for: provider) else { continue }
                let input = usageInput(result)
                if let item = warningItem(provider: provider, input: input) {
                    items.append(item)
                } else if let item = claimItem(provider: provider, input: input, now: now) {
                    items.append(item)
                }
            }
        }
        let ordered = items.filter { $0.kind == .warning } + items.filter { $0.kind == .claim }
        applyAttention(ordered)
    }

    private func applyAttention(_ items: [AttentionItem]) {
        attentionItems = items
        let identity = items.map { "\($0.id):\($0.kind.rawValue)" }.joined(separator: ",")
        guard identity != attentionIdentity else { return }
        attentionIdentity = identity
        attentionSince = identity.isEmpty ? nil : Date()
    }

    private func warningItem(provider: UsageProvider, input: UsageInput) -> AttentionItem? {
        let percent = UsageAnalytics.currentPercent(provider: provider, input: input)
        if alertLowBalance, let percent, percent <= lowThreshold {
            return AttentionItem(
                id: "low.\(provider.rawValue)",
                provider: provider,
                kind: .warning,
                icon: "exclamationmark.triangle.fill",
                title: "\(provider.displayName) 剩余 \(Int(percent.rounded()))%",
                detail: "已低于 \(Int(lowThreshold))% 阈值，请留意消耗或等待额度重置。",
                actionTitle: "打开 \(provider.descriptor.clientName)",
                canDismiss: false
            )
        }
        if alertExhaustion,
           let forecast = forecast(for: provider),
           forecast.warning,
           forecast.text.hasSuffix("后耗尽") {
            let detail: String
            if provider.isPercent,
               let risk = forecast.windows.filter({ $0.exhaustsBeforeReset })
                   .min(by: { $0.exhaustAt < $1.exhaustAt }),
               let reset = risk.resetsAt {
                detail = "预计 \(Format.reset(Int(risk.exhaustAt.timeIntervalSince1970))) 耗尽，早于重置时间 \(Format.reset(Int(reset.timeIntervalSince1970)))。"
            } else {
                detail = "按近期净消耗速度估算，剩余额度撑不到下一次领取或重置。"
            }
            return AttentionItem(
                id: "exhaust.\(provider.rawValue)",
                provider: provider,
                kind: .warning,
                icon: "hourglass",
                title: "\(provider.displayName) \(forecast.text)",
                detail: detail,
                actionTitle: "打开 \(provider.descriptor.clientName)",
                canDismiss: false
            )
        }
        return budgetWarningItem(provider: provider, input: input)
    }

    /// 月度预算超支：额度制平台本月消耗超过设定值时常驻提示，随月初消耗清零自动消失。
    private func budgetWarningItem(provider: UsageProvider, input: UsageInput) -> AttentionItem? {
        guard monthlyBudget > 0, !provider.isPercent,
              let consumed = UsageAnalytics.monthConsumed(
                  provider: provider, input: input, samples: history(for: provider)
              ),
              consumed > Double(monthlyBudget) else { return nil }
        return AttentionItem(
            id: "budget.\(provider.rawValue)",
            provider: provider,
            kind: .warning,
            icon: "chart.line.uptrend.xyaxis",
            title: "\(provider.displayName) 本月消耗超预算",
            detail: "本月已消耗 \(Format.credits(consumed)) 额度，超出 \(Format.credits(Double(monthlyBudget))) 额度预算。",
            actionTitle: "打开 \(provider.descriptor.clientName)",
            canDismiss: false
        )
    }

    private func claimItem(provider: UsageProvider, input: UsageInput, now: Date) -> AttentionItem? {
        guard isReminderEnabled(provider) else { return nil }
        switch provider.descriptor.claimReminder {
        case let .daily(hour, grant, _):
            return dailyClaimItem(
                provider: provider,
                claimHour: hour,
                grant: grant,
                input: input,
                now: now
            )
        case .windowReset:
            return windowResetClaimItem(provider: provider, input: input, now: now)
        }
    }

    /// 窗口制没有「领取」动作，改在最近一个限额窗口即将重置时提醒。
    private func windowResetClaimItem(provider: UsageProvider, input: UsageInput, now: Date) -> AttentionItem? {
        let nowTs = now.timeIntervalSince1970
        let upcoming = input.windows.compactMap { item -> (UsageWindow, Int)? in
            guard let reset = item.resetsAt,
                  Double(reset) - nowTs > 0,
                  Double(reset) - nowTs <= 20 * 60 else {
                return nil
            }
            return (item, reset)
        }
        guard let (window, reset) = upcoming.min(by: { $0.1 < $1.1 }) else { return nil }
        let key = "attention.claim.dismiss.\(provider.rawValue)"
        if UserDefaults.standard.string(forKey: key) == Self.dayKey(now) { return nil }
        return AttentionItem(
            id: "claim.\(provider.rawValue)",
            provider: provider,
            kind: .claim,
            icon: "clock.arrow.circlepath",
            title: "\(provider.displayName) \(UsageAnalytics.windowText(window.minutes))窗口即将重置",
            detail: "\(Format.reset(reset)) 刷新额度，重置后可继续使用。",
            actionTitle: "打开 \(provider.descriptor.clientName)",
            canDismiss: true
        )
    }

    private func dailyClaimItem(
        provider: UsageProvider,
        claimHour: Int,
        grant: String,
        input: UsageInput,
        now: Date
    ) -> AttentionItem? {
        guard input.remaining != nil, let total = input.total, total > 0 else { return nil }
        guard let claimAt = Calendar.current.date(
            bySettingHour: claimHour, minute: 0, second: 0, of: now
        ), now >= claimAt else { return nil }
        let key = "attention.claim.dismiss.\(provider.rawValue)"
        if UserDefaults.standard.string(forKey: key) == Self.dayKey(now) { return nil }
        guard !receivedClaimToday(provider: provider, input: input, now: now) else { return nil }
        return AttentionItem(
            id: "claim.\(provider.rawValue)",
            provider: provider,
            kind: .claim,
            icon: "gift.fill",
            title: "\(provider.displayName) 今日 \(grant)待领取",
            detail: "领取成功后此提示会自动消失；今天不需要可先忽略。",
            actionTitle: "打开 \(provider.descriptor.clientName)",
            canDismiss: true
        )
    }

    /// 今天是否已经领到过量：领取会把剩余与总量同时抬高，消耗只让剩余下降，
    /// 资源包过期则让总量下降，因此「任一相邻样本出现增加」就是已领取的可靠信号。
    /// 判定从当天 00:00 起算而不是从领取时点起算，提前或延后领取都不会误报。
    /// 历史是 5 分钟一个采样点，所以还要把最新一次采集值当作相邻点再比一次。
    private func receivedClaimToday(
        provider: UsageProvider,
        input: UsageInput,
        now: Date
    ) -> Bool {
        let dayStart = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        let samples = history(for: provider).sorted { $0.at < $1.at }
        guard var baseline = samples.last(where: { $0.at < dayStart }) ?? samples.first else { return false }
        for sample in samples where sample.at >= dayStart {
            if Self.grew(from: baseline, to: sample) { return true }
            baseline = sample
        }
        return Self.grew(
            from: baseline,
            to: UsageSample(
                at: 0,
                remaining: input.remaining,
                total: input.total,
                remainingPercent: nil,
                windows: nil
            )
        )
    }

    private static func grew(from previous: UsageSample, to current: UsageSample) -> Bool {
        if let value = previous.remaining, let next = current.remaining, next > value + 0.5 { return true }
        if let value = previous.total, let next = current.total, next > value + 0.5 { return true }
        return false
    }

    /// 一次采集的目标：名称、超时预算与退避基准全部来自注册表。
    /// Codex 需要等本机 app-server 应答，WorkBuddy 走本机 socket，分开给预算，
    /// 一家挂死不会把另一家已经采好的数据一起超时掉。
    private struct CollectionTarget: Sendable {
        let provider: UsageProvider

        var name: String { provider.descriptor.collectorKey }
        var title: String { provider.displayName }
        var timeout: TimeInterval { provider.descriptor.collectorTimeout }
        var baseInterval: TimeInterval { provider.descriptor.refreshInterval }
    }

    /// 环境类失败（超时、python3 缺失、输出不可解析）按指数退避，避免每个周期反复重开子进程。
    private var collectorFailures: [UsageProvider: Int] = [:]
    private var collectorRetryAt: [UsageProvider: Date] = [:]

    private func canCollect(_ provider: UsageProvider) -> Bool {
        guard let at = collectorRetryAt[provider] else { return true }
        return Date() >= at
    }

    private func registerFailure(_ target: CollectionTarget, message: String) {
        let failures = (collectorFailures[target.provider] ?? 0) + 1
        collectorFailures[target.provider] = failures
        let interval = min(target.baseInterval * pow(2, Double(min(failures - 1, 4))), 900)
        collectorRetryAt[target.provider] = Date().addingTimeInterval(interval)
        Diagnostics.record(
            "collector",
            "\(target.name) 连续 \(failures) 次采集失败，\(Int(interval)) 秒后重试：\(message)"
        )
    }

    private func resetFailures(_ target: CollectionTarget) {
        guard collectorFailures[target.provider] != nil else { return }
        Diagnostics.record("collector", "\(target.name) 采集恢复")
        collectorFailures[target.provider] = nil
        collectorRetryAt[target.provider] = nil
    }

    private func setError(_ message: String?, for provider: UsageProvider) {
        states[provider]?.error = message
    }

    private func consume(_ run: CollectorRunner.RunResult, from target: CollectionTarget) {
        guard let output = run.output else {
            let message = run.error ?? "采集器运行失败"
            registerFailure(target, message: message)
            setError(message, for: target.provider)
            return
        }
        resetFailures(target)
        if let fatal = output.providerErrors["all"] {
            setError(fatal, for: target.provider)
            Diagnostics.record("collector", "\(target.name)：\(fatal)")
            return
        }
        guard let result = output.providers?[target.name] else {
            let message = output.providerErrors[target.name] ?? "采集器未返回 \(target.title) 数据"
            setError(message, for: target.provider)
            Diagnostics.record("collector", "\(target.name)：\(message)")
            return
        }
        apply(result, to: target.provider)
    }

    /// 手动刷新与唤醒都强制采集一次，忽略退避窗口。
    func refreshAll() {
        for group in Self.groups {
            refresh(group.providers, force: true)
        }
    }

    /// 一批采集目标：跳过在途与仍在退避窗口里的供应商。
    private func targets(_ providers: [UsageProvider], force: Bool) -> [CollectionTarget] {
        providers
            .filter { !self.isRefreshing($0) && (force || self.canCollect($0)) }
            .map { CollectionTarget(provider: $0) }
    }

    func refresh(_ providers: [UsageProvider], force: Bool = false) {
        let batch = targets(providers, force: force)
        guard !batch.isEmpty else { return }
        for target in batch { states[target.provider]?.isRefreshing = true }
        Task.detached(priority: .utility) { [weak self] in
            guard let store = self else { return }
            // 组内并行采集、谁先采完谁先回主线程更新：慢的一家（最多等满自己的超时）
            // 不会压着已经采好的一家让面板等到最后才刷新。
            await withTaskGroup(of: (CollectorRunner.RunResult, CollectionTarget).self) { group in
                for target in batch {
                    group.addTask {
                        (CollectorRunner.run(provider: target.name, timeout: target.timeout), target)
                    }
                }
                for await (run, target) in group {
                    await MainActor.run { store.consume(run, from: target) }
                }
            }
            await MainActor.run {
                let finished = Date()
                for target in batch {
                    store.states[target.provider]?.isRefreshing = false
                    store.states[target.provider]?.lastCollectedAt = finished
                }
                store.saveCache()
                store.recomputeAttention(now: finished)
            }
        }
    }

    enum QoderSetupPhase: Equatable {
        case idle
        case installing
        case preparing
        case waitingAuth(URL)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .installing, .preparing, .waitingAuth:
                return true
            default:
                return false
            }
        }
    }

    @Published private(set) var qoderSetup: QoderSetupPhase = .idle
    private var loginPoll: Task<Void, Never>?

    func installQoderCLI() {
        guard !qoderSetup.isBusy else { return }
        guard Apps.confirm(
            title: "安装 Qoder CLI",
            info: "将从 Qoder 官方地址下载并执行安装脚本，完成后自动在浏览器发起登录授权。"
        ) else { return }
        qoderSetup = .installing
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CollectorRunner.action("qoder-install", timeout: 320)
            guard let self else { return }
            await MainActor.run {
                if let error = result.error {
                    self.qoderSetup = .failed(error)
                    self.setError(error, for: .qoder)
                    return
                }
                self.qoderSetup = .idle
                self.loginQoderCLI()
            }
        }
    }

    func loginQoderCLI() {
        guard !qoderSetup.isBusy else { return }
        qoderSetup = .preparing
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CollectorRunner.action("qoder-login", timeout: 45)
            guard let self else { return }
            await MainActor.run {
                if let error = result.error {
                    self.qoderSetup = .failed(error)
                    return
                }
                guard let string = result.action?.url, let url = URL(string: string) else {
                    self.qoderSetup = .failed("未获取到授权链接，请稍后重试")
                    return
                }
                NSWorkspace.shared.open(url)
                self.qoderSetup = .waitingAuth(url)
                self.pollQoderLogin()
            }
        }
    }

    func cancelQoderSetup() {
        loginPoll?.cancel()
        loginPoll = nil
        qoderSetup = .idle
    }

    private func pollQoderLogin() {
        loginPoll?.cancel()
        loginPoll = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.qoderSetup.isBusy else { return }
                let result = await Task.detached(priority: .utility) {
                    CollectorRunner.action("qoder-login-status", timeout: 20)
                }.value
                guard self.qoderSetup.isBusy, !Task.isCancelled else { return }
                switch result.action?.status {
                case "done":
                    self.qoderSetup = .idle
                    self.setError(nil, for: .qoder)
                    self.refresh([.qoder])
                    return
                case "failed":
                    self.qoderSetup = .failed(result.action?.message ?? "登录未完成")
                    return
                default:
                    continue
                }
            }
            self?.qoderSetup = .failed("登录等待超时，请重新发起")
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.setEnabled(enabled)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func refreshNotificationStatus() {
        let center = notificationCenter
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let denied = settings.authorizationStatus == .denied
                let recovered = self.notificationsDenied && !denied
                self.notificationsDenied = denied
                if recovered {
                    self.refreshReminders()
                }
            }
        }
    }

    private func reminderSettingChanged() {
        refreshReminders()
        prepareNotificationAuthorization()
        recomputeAttention(now: Date())
    }

    private func prepareNotificationAuthorization() {
        guard Providers.all.contains(where: { self.isReminderEnabled($0.id) })
                || alertLowBalance || alertExhaustion || alertAcceleration else { return }
        let center = notificationCenter
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.notificationsDenied = !granted
                        if granted {
                            self.refreshReminders()
                        }
                    }
                }
            case .denied:
                Task { @MainActor [weak self] in
                    self?.notificationsDenied = true
                }
            default:
                break
            }
        }
    }

    /// 到点通知的标识沿用注册表里登记的提醒键名，与旧版本写死的三个 id 一致。
    private func refreshReminders() {
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: Providers.all.map(\.reminderDefaultsKey)
        )
        for descriptor in Providers.all where isReminderEnabled(descriptor.id) {
            switch descriptor.claimReminder {
            case let .daily(hour, grant, body):
                addDailyReminder(
                    id: descriptor.reminderDefaultsKey,
                    title: "\(descriptor.displayName) 今日 \(grant)可领取",
                    body: body,
                    hour: hour,
                    minute: 0,
                    category: NotificationCategory.forProvider(descriptor.id)
                )
            case .windowReset:
                scheduleWindowResetReminder(for: descriptor.id)
            }
        }
    }

    private func addDailyReminder(
        id: String,
        title: String,
        body: String,
        hour: Int,
        minute: Int,
        category: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        notificationCenter.add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger),
            withCompletionHandler: nil
        )
    }

    /// 窗口制没有每日领取，改成在最长窗口的重置点之后立刻通知一次。
    private func scheduleWindowResetReminder(for provider: UsageProvider) {
        let id = provider.descriptor.reminderDefaultsKey
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [id])
        guard isReminderEnabled(provider),
              let windows = result(for: provider)?.windows,
              let window = windows.max(by: { ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) }),
              let minutes = window.windowMinutes,
              let reset = window.resetsAt else { return }
        let now = Int(Date().timeIntervalSince1970)
        guard reset > now else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) \(Format.window(minutes))额度已重置"
        content.body = "额度窗口已刷新，可以继续使用。"
        content.sound = .default
        content.categoryIdentifier = NotificationCategory.forProvider(provider)
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(reset - now) + 30,
            repeats: false
        )
        notificationCenter.add(
            UNNotificationRequest(identifier: id, content: content, trigger: trigger),
            withCompletionHandler: nil
        )
    }

    private func apply(_ result: ProviderResult, to provider: UsageProvider) {
        guard result.ok == true else {
            let message = result.error
                ?? (result.ok == nil ? "采集结果缺少状态字段，请升级应用" : "未知错误")
            // 只在状态变化时记一行，否则「未登录」这类稳定状态会被每个周期刷满日志。
            if error(for: provider) != message {
                Diagnostics.record("collector", "\(provider.displayName) 数据不可用：\(message)")
            }
            setError(message, for: provider)
            return
        }
        if error(for: provider) != nil {
            Diagnostics.record("collector", "\(provider.displayName) 数据恢复")
        }
        states[provider]?.result = result
        states[provider]?.error = nil
        if case .windowReset = provider.descriptor.claimReminder {
            scheduleWindowResetReminder(for: provider)
        }
        recordHistory(provider: provider, result: result)
        evaluateAlerts(provider: provider, result: result)
    }

    func forecast(for provider: UsageProvider) -> UsageForecast? {
        guard let result = result(for: provider), result.ok == true else { return nil }
        return UsageAnalytics.forecast(
            provider: provider,
            input: usageInput(result),
            samples: history(for: provider),
            lowThreshold: lowThreshold
        )
    }

    func insight(for provider: UsageProvider) -> UsageInsight? {
        guard let result = result(for: provider), result.ok == true else { return nil }
        return UsageAnalytics.insight(
            provider: provider,
            input: usageInput(result),
            samples: history(for: provider)
        )
    }

    func weekly(for provider: UsageProvider) -> WeeklyUsage? {
        guard let result = result(for: provider), result.ok == true else { return nil }
        return UsageAnalytics.weekly(
            provider: provider,
            input: usageInput(result),
            samples: history(for: provider)
        )
    }

    /// 采集成功且可用的供应商。
    func availableResult(for provider: UsageProvider) -> ProviderResult? {
        guard let result = result(for: provider), result.ok == true else { return nil }
        return result
    }

    private func usageInput(_ result: ProviderResult) -> UsageInput {
        UsageInput(
            remaining: result.remaining,
            total: result.total,
            remainingPercent: result.remainingPercent,
            windows: (result.windows ?? []).compactMap { window in
                guard let minutes = window.windowMinutes,
                      let remaining = window.remainingPercent else { return nil }
                return UsageWindow(
                    minutes: minutes,
                    remainingPercent: remaining,
                    usedPercent: window.usedPercent ?? (100 - remaining),
                    resetsAt: window.resetsAt
                )
            }
        )
    }

    private func setHistory(_ samples: [UsageSample], for provider: UsageProvider) {
        states[provider]?.history = samples
    }

    private func loadHistory() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: Self.historyURL.path) else { return }
        if let file = Self.decodeHistory(at: Self.historyURL) {
            applyHistory(file)
            return
        }
        // 主文件读不出：先确认备份能不能救，再把坏文件改名留证。
        let fallback = Self.decodeHistory(at: Self.historyBackupURL)
        moveMainHistoryAside()
        if let file = fallback {
            Diagnostics.record("history", "history.json 无法解析，已回退到上一份备份")
            applyHistory(file)
            return
        }
        // 备份也读不出：坏文件已经改名保留，重新开始积累不会覆盖唯一证据。
        try? manager.removeItem(at: Self.historyBackupURL)
        Diagnostics.record("history", "历史文件与备份均无法解析，已改名保留后重新开始积累")
    }

    private func applyHistory(_ snapshot: HistorySnapshot) {
        let now = Date()
        for provider in UsageProvider.allCases {
            states[provider]?.history = UsageAnalytics.prune(snapshot.samples[provider] ?? [], now: now)
        }
    }

    private static func decodeHistory(at url: URL) -> HistorySnapshot? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return LocalData.decodeHistory(data)
    }

    /// 把读不出的主文件改名留证；备份是否删除由调用方决定。
    private func moveMainHistoryAside() {
        let manager = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let kept = Self.historyURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp)")
            .appendingPathExtension("json")
        try? manager.removeItem(at: kept)
        try? manager.moveItem(at: Self.historyURL, to: kept)
        // 只留最近两份取证文件，避免长期故障把目录塞满。
        let directory = Self.historyURL.deletingLastPathComponent()
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        let corrupt = names.filter { $0.hasPrefix("history.corrupt-") }.sorted()
        for name in corrupt.dropLast(2) {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func saveHistory() {
        let snapshot = HistorySnapshot(
            samples: Providers.all.reduce(into: [:]) { partial, descriptor in
                partial[descriptor.id] = history(for: descriptor.id)
            }
        )
        guard let data = LocalData.encodeHistory(snapshot) else {
            Diagnostics.record("history", "历史编码失败，本轮未写入")
            return
        }
        let manager = FileManager.default
        let directory = Self.historyURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            // 每次覆盖前先轮换一份备份：写入被中断时最多退回上一份，不会两个文件一起坏。
            if manager.fileExists(atPath: Self.historyURL.path) {
                try? manager.removeItem(at: Self.historyBackupURL)
                try manager.copyItem(at: Self.historyURL, to: Self.historyBackupURL)
            }
            try data.write(to: Self.historyURL, options: .atomic)
        } catch {
            Diagnostics.record("history", "历史写入失败：\(error.localizedDescription)")
        }
    }

    private func seedHistoryFromCache() {
        for provider in Providers.all {
            guard let result = result(for: provider.id), result.ok == true,
                  let date = result.updatedDate else { continue }
            recordHistory(provider: provider.id, result: result, at: date)
        }
    }

    private func recordHistory(provider: UsageProvider, result: ProviderResult, at date: Date? = nil) {
        let timestamp = date ?? result.updatedDate ?? Date()
        let input = usageInput(result)
        guard let sample = UsageAnalytics.sample(provider: provider, input: input, at: timestamp) else {
            return
        }
        var samples = history(for: provider)
        if let last = samples.last,
           sample.at - last.at < Int(UsageAnalytics.sampleInterval) {
            return
        }
        samples.append(sample)
        samples = UsageAnalytics.prune(samples)
        setHistory(samples, for: provider)
        saveHistory()
    }

    func exportHistory(days: Int) {
        let cutoff = Int(Date().timeIntervalSince1970) - days * 86400
        UsageExport.save(Providers.all.reduce(into: [:]) { partial, descriptor in
            partial[descriptor.id] = history(for: descriptor.id).filter { $0.at >= cutoff }
        }, days: days)
    }

    private func evaluateAlerts(provider: UsageProvider, result: ProviderResult) {
        guard !notificationsDenied else { return }
        let input = usageInput(result)
        let now = Date()
        evaluateLowAlert(provider: provider, input: input, now: now)
        if provider.isPercent {
            evaluateExhaustionAlert(provider: provider, input: input, now: now)
        } else {
            evaluateBudgetAlert(provider: provider, input: input, now: now)
        }
        evaluateAccelerationAlert(provider: provider, input: input, now: now)
    }

    private func evaluateLowAlert(provider: UsageProvider, input: UsageInput, now: Date) {
        guard alertLowBalance else { return }
        guard let percent = UsageAnalytics.currentPercent(provider: provider, input: input) else {
            return
        }
        let key = "alert.low.\(provider.rawValue).last"
        let defaults = UserDefaults.standard
        if percent > lowRecovery {
            defaults.removeObject(forKey: key)
            return
        }
        guard percent <= lowThreshold else { return }
        let epoch = now.timeIntervalSince1970
        let last = defaults.double(forKey: key)
        guard last == 0 || epoch - last >= UsageAnalytics.lowCooldown else { return }

        let threshold = Int(lowThreshold)
        let rounded = Int(percent.rounded())
        let title: String
        let body: String
        if provider.isPercent, let window = UsageAnalytics.lowestWindow(of: input) {
            title = "\(provider.displayName) \(UsageAnalytics.windowText(window.minutes))窗口低于 \(threshold)%"
            body = "当前剩余 \(rounded)%，请留意额度消耗或等待重置。"
        } else {
            title = "\(provider.displayName) 剩余低于 \(threshold)%"
            if let remaining = input.remaining {
                body = "当前剩余 \(Format.credits(remaining)) 额度（\(rounded)%），请及时领取或调整使用。"
            } else {
                body = "当前剩余 \(rounded)%，请及时领取或调整使用。"
            }
        }
        deliverAlert(
            id: "alert.low.\(provider.rawValue)",
            title: title,
            body: body,
            provider: provider
        ) {
            defaults.set(epoch, forKey: key)
        }
    }

    /// 窗口制的耗尽风险：按窗口「可能在重置前耗尽」逐一判定，去重键沿用既有的
    /// `alert.<provider>.exhaust.<minutes>`，写入的是该窗口的重置时间。
    private func evaluateExhaustionAlert(provider: UsageProvider, input: UsageInput, now: Date) {
        guard alertExhaustion else { return }
        guard let forecast = UsageAnalytics.forecast(
            provider: provider,
            input: input,
            samples: history(for: provider),
            now: now,
            lowThreshold: lowThreshold
        ) else { return }
        guard let risk = forecast.windows
            .filter({ $0.exhaustsBeforeReset })
            .min(by: { $0.exhaustAt < $1.exhaustAt }) else { return }
        if alertLowBalance && risk.remainingPercent <= lowThreshold {
            return
        }
        guard let reset = risk.resetsAt else { return }

        let defaults = UserDefaults.standard
        let key = "alert.\(provider.rawValue).exhaust.\(risk.minutes)"
        let resetEpoch = Int(reset.timeIntervalSince1970)
        guard defaults.integer(forKey: key) != resetEpoch else { return }

        let title = "\(provider.displayName) \(UsageAnalytics.windowText(risk.minutes))窗口可能在重置前耗尽"
        let body = "剩余 \(Int(risk.remainingPercent.rounded()))%，按近期速度预计 \(Format.reset(Int(risk.exhaustAt.timeIntervalSince1970))) 耗尽，早于重置时间 \(Format.reset(resetEpoch))。"
        deliverAlert(
            id: key,
            title: title,
            body: body,
            provider: provider
        ) {
            defaults.set(resetEpoch, forKey: key)
        }
    }

    private func evaluateAccelerationAlert(provider: UsageProvider, input: UsageInput, now: Date) {
        guard alertAcceleration else { return }
        guard let percent = UsageAnalytics.currentPercent(provider: provider, input: input) else {
            return
        }
        if alertLowBalance && percent <= lowThreshold { return }

        let rates = UsageAnalytics.rampRates(
            provider: provider,
            input: input,
            samples: history(for: provider),
            now: now
        )
        guard let short = rates.short,
              let baseline = rates.baseline,
              baseline >= 0.2,
              short >= UsageAnalytics.rampMinimumRate,
              short >= baseline * UsageAnalytics.rampRatio else { return }

        let defaults = UserDefaults.standard
        let key = "alert.ramp.\(provider.rawValue).last"
        let epoch = now.timeIntervalSince1970
        let last = defaults.double(forKey: key)
        guard last == 0 || epoch - last >= UsageAnalytics.rampCooldown else { return }

        let ratio = short / baseline
        let body = "近 15 分钟消耗速度约为此前 1 小时的 \(String(format: "%.1f", ratio)) 倍，当前剩余 \(Int(percent.rounded()))%，请留意额度消耗。"
        deliverAlert(
            id: "alert.ramp.\(provider.rawValue)",
            title: "\(provider.displayName) 消耗速度明显加快",
            body: body,
            provider: provider
        ) {
            defaults.set(epoch, forKey: key)
        }
    }

    /// 月度预算告警：每家额度制平台独立计数，本月消耗超预算时通知一次，按月去重，
    /// 月初消耗清零后自然重新布防。
    private func evaluateBudgetAlert(provider: UsageProvider, input: UsageInput, now: Date) {
        guard monthlyBudget > 0,
              let consumed = UsageAnalytics.monthConsumed(
                  provider: provider, input: input, samples: history(for: provider), now: now
              ),
              consumed > Double(monthlyBudget) else { return }
        let defaults = UserDefaults.standard
        let key = "alert.budget.\(provider.rawValue).month"
        let monthKey = Self.monthKey(now)
        guard defaults.string(forKey: key) != monthKey else { return }
        deliverAlert(
            id: "alert.budget.\(provider.rawValue)",
            title: "\(provider.displayName) 本月消耗超出预算",
            body: "本月已消耗 \(Format.credits(consumed)) 额度，超过设定的 \(Format.credits(Double(monthlyBudget))) 额度预算。",
            provider: provider
        ) {
            defaults.set(monthKey, forKey: key)
        }
    }

    private func deliverAlert(
        id: String,
        title: String,
        body: String,
        provider: UsageProvider,
        onDelivered: (() -> Void)? = nil
    ) {
        let center = notificationCenter
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Diagnostics.record(
                "alert",
                allowed
                    ? "\(provider.displayName) \(title)｜\(body)"
                    : "\(provider.displayName) \(title)｜通知未授权，只保留面板提示"
            )
            guard allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.categoryIdentifier = NotificationCategory.forProvider(provider)
            content.threadIdentifier = "alerts.\(provider.rawValue)"
            let request = UNNotificationRequest(
                identifier: "\(id).\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if let error {
                    Diagnostics.record("notify", "通知投递失败：\(error.localizedDescription)")
                } else {
                    onDelivered?()
                }
            }
        }
    }

    private func resetLowAlertState() {
        for provider in UsageProvider.allCases {
            UserDefaults.standard.removeObject(forKey: "alert.low.\(provider.rawValue).last")
        }
    }

    /// 一个刷新节奏一组一个定时器：快组照常 60 秒，走 CLI 的 Qoder 单独按自己的间隔跑。
    private func scheduleTimers() {
        for group in Self.groups {
            let timer = Timer(timeInterval: group.interval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh(group.providers) }
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimers.append(timer)
        }
    }

    /// 面板展开时补采注册表里标记的供应商：领取、消耗都要等下一个定时周期才反映太慢。
    /// 采集耗时约 5 秒且异步进行，面板先显示缓存值，回来后自动就地更新。
    func refreshStaleForPanel() {
        let now = Date()
        for provider in Providers.panelRefreshProviders {
            guard let at = lastCollectedAt(for: provider),
                  now.timeIntervalSince(at) >= provider.descriptor.refreshInterval else { continue }
            refresh([provider])
        }
    }

    private func loadCache() {
        guard FileManager.default.fileExists(atPath: Self.cacheURL.path) else { return }
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let snapshot = LocalData.decodeCache(data) else {
            Diagnostics.record("cache", "cache.json 无法解析，本次启动从空白状态开始")
            return
        }
        for descriptor in Providers.all {
            states[descriptor.id]?.result = snapshot.results[descriptor.id]
            states[descriptor.id]?.lastCollectedAt = snapshot.collectedAt[descriptor.id]
        }
    }

    private func saveCache() {
        var snapshot = CacheSnapshot()
        for descriptor in Providers.all {
            snapshot.results[descriptor.id] = states[descriptor.id]?.result
            if let at = states[descriptor.id]?.lastCollectedAt {
                snapshot.collectedAt[descriptor.id] = at
            }
        }
        guard let data = LocalData.encodeCache(snapshot) else {
            Diagnostics.record("cache", "缓存编码失败")
            return
        }
        do {
            let directory = Self.cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: Self.cacheURL, options: .atomic)
        } catch {
            Diagnostics.record("cache", "缓存写入失败：\(error.localizedDescription)")
        }
    }
}

extension UsageStore {
    var menuBarMetrics: [MenuBarMetric] {
        panelProviders.compactMap { menuBarMetric(for: $0) }
    }

    private func menuBarMetric(for descriptor: ProviderDescriptor) -> MenuBarMetric? {
        guard isShownInMenuBar(descriptor.id) else { return nil }
        let result = result(for: descriptor.id)
        let ok = result?.ok == true
        let value: String
        let compact: String
        let percent: Double?
        if descriptor.isPercent {
            percent = ok ? result?.primaryWindow?.remainingPercent : nil
            value = Format.percent(percent)
            compact = value
        } else {
            let remaining: Double? = ok ? result?.remaining : nil
            percent = percentOf(remaining, over: ok ? (result?.total ?? 0) : 0)
            value = Format.credits(remaining)
            compact = Format.compact(remaining)
        }
        let consumed = insight(for: descriptor.id)?.todayConsumed
        let today = consumed.map { descriptor.isPercent ? Format.percentDetailed($0) : Format.credits($0) }
        // 紧凑样式里今日消耗取整：136.9 这种小数在菜单栏那么小的字号上没有意义。
        let todayCompact = consumed.map { descriptor.isPercent ? Format.percentDetailed($0) : Format.compact($0.rounded()) }
        return MenuBarMetric(
            letter: descriptor.menuBarLetter,
            value: value,
            compact: compact,
            percent: Format.percent(percent),
            today: today,
            todayCompact: todayCompact,
            fraction: fractionOf(percent),
            tint: descriptor.color
        )
    }

    /// 只有数字类样式能滚动：条形样式画的是剩余比例，换成今日消耗会让竖条和文案含义分家。
    var menuBarRollAvailable: Bool {
        menuBarStyle != .bars && menuBarMetrics.contains { $0.today != nil }
    }

    func setMenuBarShowsToday(_ showsToday: Bool) {
        menuBarShowsToday = showsToday && menuBarRollAvailable
    }

    func menuBarText(for style: MenuBarStyle, font: NSFont) -> NSAttributedString {
        MenuBarText.compose(menuBarMetrics, style: style, showsToday: menuBarShowsToday, font: font)
    }

    private func percentOf(_ remaining: Double?, over total: Double) -> Double? {
        guard let remaining, total > 0 else { return nil }
        return remaining / total * 100
    }

    private func fractionOf(_ percent: Double?) -> Double? {
        percent.map { min(max($0 / 100, 0), 1) }
    }

    var menuBarTooltip: String {
        var parts: [String] = []
        if !isAttentionMuted, let item = attentionItems.first {
            parts.append(item.kind == .warning ? "需要关注：\(item.title)" : "待处理：\(item.title)")
        }
        parts.append(contentsOf: panelProviders.map { tooltipLine(for: $0) })
        return parts.joined(separator: " · ")
    }

    private func tooltipLine(for descriptor: ProviderDescriptor) -> String {
        let result = result(for: descriptor.id)
        if descriptor.isPercent {
            guard result?.ok == true, let window = result?.primaryWindow else {
                return "\(descriptor.displayName) 不可用"
            }
            var line = "\(descriptor.displayName) \(Format.window(window.windowMinutes))窗口剩余 \(Format.percent(window.remainingPercent))"
            if let suffix = forecastSuffix(for: descriptor.id) { line += " · \(suffix)" }
            return line
        }
        guard let result, result.ok == true else { return "\(descriptor.displayName) 不可用" }
        var line = "\(descriptor.displayName) 剩余 \(Format.credits(result.remaining)) / \(Format.credits(result.total)) \(descriptor.creditUnit)"
        if let suffix = forecastSuffix(for: descriptor.id) { line += " · \(suffix)" }
        return line
    }

    private func forecastSuffix(for provider: UsageProvider) -> String? {
        guard let forecast = forecast(for: provider), forecast.text != "样本积累中" else {
            return nil
        }
        return forecast.text
    }

}
