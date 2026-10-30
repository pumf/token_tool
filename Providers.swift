import SwiftUI

/// 额度口径。分析、预测、告警与渲染都按口径分派，而不是按具体供应商，
/// 新增一家供应商时只要归进已有口径就不需要改这些逻辑。
enum QuotaKind: Sendable {
    /// 积分制：有剩余与总量的 Credits，可能带每日领取。
    case credits
    /// 窗口制：按滚动限额窗口计百分比，窗口到点重置。
    case percentWindow
}

/// 领取提醒的形态。
enum ClaimReminder: Sendable {
    /// 每天固定时刻可领取固定额度；body 是到点通知的正文。
    case daily(hour: Int, grant: String, body: String)
    /// 没有领取动作，按最近一个限额窗口的重置时间提醒。
    case windowReset
}

/// 积分制供应商卡片里的额度布局。两家的额度构成不一样，进度条不能共用一种排法。
enum CreditLayout: Sendable {
    /// 套餐额度 + 附加额度两段进度条。
    case planBreakdown
    /// 单一资源包进度条，附资源包数量。
    case resourcePackage
}

/// 登录/安装类引导动作。实现仍是显式分支，但集中在一处，不再散落到界面代码。
enum ProviderSetup: Sendable {
    case none
    case qoderCLI
}

/// 一个供应商所需的全部静态信息。
struct ProviderDescriptor: Sendable {
    let id: UsageProvider
    let collectorKey: String
    let displayName: String
    let subtitle: String
    let icon: String
    let menuBarLetter: String
    let color: Color
    let quotaKind: QuotaKind
    /// 卡片脚注里的额度单位；窗口制不使用。
    let creditUnit: String
    /// 积分制的额度排布；窗口制传 nil。
    let creditLayout: CreditLayout?
    let refreshInterval: TimeInterval
    let collectorTimeout: TimeInterval
    let clientName: String
    let clientBundleID: String
    let clientAppPath: String
    let clientHelp: String
    let websiteURL: String
    let websiteHelp: String
    let claimReminder: ClaimReminder
    /// 既有的 UserDefaults 键名，重构不允许改动用户已保存的开关状态。
    let reminderDefaultsKey: String
    let menuBarDefaultsKey: String
    /// 面板展开时是否补采一次。采集节奏慢、又是用户点开面板最想立刻看到的一家才需要。
    let refreshOnPanelOpen: Bool
    let setup: ProviderSetup

    var isPercent: Bool { quotaKind == .percentWindow }
}

enum Providers {
    static let all: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: .qoder,
            collectorKey: "qoder",
            displayName: "Qoder",
            subtitle: "官方 CLI · 账号额度",
            icon: "curlybraces",
            menuBarLetter: "Q",
            color: Theme.qoder,
            quotaKind: .credits,
            creditUnit: "Credits",
            creditLayout: .planBreakdown,
            refreshInterval: 90,
            collectorTimeout: 80,
            clientName: "Qoder",
            clientBundleID: "com.qodercn.app",
            clientAppPath: "/Applications/Qoder CN.app",
            clientHelp: "打开 Qoder CN",
            websiteURL: "https://qoder.com.cn",
            websiteHelp: "打开 Qoder 官网",
            claimReminder: .daily(hour: 10, grant: "100 Credits", body: "打开 Qoder 领取今日额度。"),
            reminderDefaultsKey: "reminder.qoder.claim",
            menuBarDefaultsKey: "menuBar.qoder",
            refreshOnPanelOpen: true,
            setup: .qoderCLI
        ),
        ProviderDescriptor(
            id: .workbuddy,
            collectorKey: "workbuddy",
            displayName: "WorkBuddy",
            subtitle: "本机客户端 · 资源包",
            icon: "briefcase.fill",
            menuBarLetter: "W",
            color: Theme.workbuddy,
            quotaKind: .credits,
            creditUnit: "credits",
            creditLayout: .resourcePackage,
            refreshInterval: 60,
            collectorTimeout: 25,
            clientName: "WorkBuddy",
            clientBundleID: "com.tencent.workbuddy.mac",
            clientAppPath: "/Applications/WorkBuddy.app",
            clientHelp: "打开 WorkBuddy",
            websiteURL: "https://www.workbuddy.cn",
            websiteHelp: "打开 WorkBuddy 官网",
            claimReminder: .daily(hour: 0, grant: "100 积分", body: "打开 WorkBuddy 领取今日积分。"),
            reminderDefaultsKey: "reminder.workbuddy.claim",
            menuBarDefaultsKey: "menuBar.workbuddy",
            refreshOnPanelOpen: false,
            setup: .none
        ),
        ProviderDescriptor(
            id: .codex,
            collectorKey: "codex",
            displayName: "Codex",
            subtitle: "ChatGPT 登录 · 限额窗口",
            icon: "terminal.fill",
            menuBarLetter: "C",
            color: Theme.codex,
            quotaKind: .percentWindow,
            creditUnit: "",
            creditLayout: nil,
            refreshInterval: 60,
            collectorTimeout: 70,
            clientName: "ChatGPT",
            clientBundleID: "com.openai.codex",
            clientAppPath: "/Applications/ChatGPT.app",
            clientHelp: "打开 ChatGPT",
            websiteURL: "https://openai.com/codex/",
            websiteHelp: "打开 Codex 官网",
            claimReminder: .windowReset,
            reminderDefaultsKey: "reminder.codex.reset",
            menuBarDefaultsKey: "menuBar.codex",
            refreshOnPanelOpen: false,
            setup: .none
        ),
    ]

    /// 面板与菜单栏的固定展示顺序。
    static let ordered: [ProviderDescriptor] = all

    static func descriptor(_ id: UsageProvider) -> ProviderDescriptor {
        guard let found = all.first(where: { $0.id == id }) else {
            preconditionFailure("供应商 \(id.rawValue) 缺少注册表条目")
        }
        return found
    }
}

extension UsageProvider {
    var descriptor: ProviderDescriptor { Providers.descriptor(self) }
    var quotaKind: QuotaKind { descriptor.quotaKind }
    var displayName: String { descriptor.displayName }
    var menuBarLetter: String { descriptor.menuBarLetter }
    var isPercent: Bool { descriptor.isPercent }
}

/// 一组共用同一个定时器的供应商。
struct RefreshGroup: Sendable {
    let interval: TimeInterval
    let providers: [UsageProvider]
}

extension Providers {
    /// 按刷新节奏分组；组内按超时预算从大到小排，慢的一家先开始采集，
    /// 与重构前 Codex 先、WorkBuddy 后的顺序一致。
    static let groups: [RefreshGroup] = {
        let grouped = Dictionary(grouping: all, by: \.refreshInterval)
        return grouped
            .map { interval, items in
                RefreshGroup(
                    interval: interval,
                    providers: items
                        .sorted { $0.collectorTimeout > $1.collectorTimeout }
                        .map(\.id)
                )
            }
            .sorted { $0.interval < $1.interval }
    }()

    /// 面板展开时补采的供应商：采集节奏慢、又是点开面板最想立刻看到的那几家。
    static let panelRefreshProviders: [UsageProvider] = all
        .filter(\.refreshOnPanelOpen)
        .map(\.id)
}
