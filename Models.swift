import Foundation

/// 采集器字段全部按可选解码：上游改字段名或删字段时，这一家降级成「部分未知」，
/// 不会让整份 JSON 解码失败、把另外两家一起打回「无法解析」。
struct CodexWindow: Codable, Sendable, Identifiable {
    let id: String
    let windowMinutes: Int?
    let usedPercent: Double?
    let remainingPercent: Double?
    let resetsAt: Int?

    private enum CodingKeys: String, CodingKey {
        case id, windowMinutes, usedPercent, remainingPercent, resetsAt
    }

    init(
        id: String,
        windowMinutes: Int?,
        usedPercent: Double?,
        remainingPercent: Double?,
        resetsAt: Int?
    ) {
        self.id = id
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minutes = (try? container.decode(Int.self, forKey: .windowMinutes)) ?? nil
        let percent = (try? container.decode(Double.self, forKey: .usedPercent)) ?? nil
        id = (try? container.decode(String.self, forKey: .id)) ?? "window-\(minutes ?? 0)"
        windowMinutes = minutes
        usedPercent = percent
        remainingPercent = (try? container.decode(Double.self, forKey: .remainingPercent)) ?? nil
        resetsAt = (try? container.decode(Int.self, forKey: .resetsAt)) ?? nil
    }
}

struct CodexCredits: Codable, Sendable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: Double?
}

struct ProviderResult: Codable, Sendable {
    var ok: Bool?
    var error: String?
    var updatedAt: Int?
    var plan: String?
    var accountType: String?
    var windows: [CodexWindow]?
    var credits: CodexCredits?
    var resetCredits: Int?
    var total: Double?
    var remaining: Double?
    var used: Double?
    var usedPercent: Double?
    var remainingPercent: Double?
    var packages: Int?
    var unit: String?
    var planExpiresAt: String?
    var planUsed: Double?
    var planTotal: Double?
    var addonUsed: Double?
    var addonTotal: Double?
    var orgResourcePackage: String?
    var source: String?

    var updatedDate: Date? {
        guard let updatedAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(updatedAt))
    }

    var primaryWindow: CodexWindow? { windows?.first }

    private enum CodingKeys: String, CodingKey {
        case ok, error, updatedAt, plan, accountType, windows, credits, resetCredits
        case total, remaining, used, usedPercent, remainingPercent, packages, unit
        case planExpiresAt, planUsed, planTotal, addonUsed, addonTotal
        case orgResourcePackage, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.loose(Bool.self, .ok)
        error = container.loose(String.self, .error)
        updatedAt = container.loose(Int.self, .updatedAt)
        plan = container.loose(String.self, .plan)
        accountType = container.loose(String.self, .accountType)
        windows = container.loose([CodexWindow].self, .windows)
        credits = container.loose(CodexCredits.self, .credits)
        resetCredits = container.loose(Int.self, .resetCredits)
        total = container.loose(Double.self, .total)
        remaining = container.loose(Double.self, .remaining)
        used = container.loose(Double.self, .used)
        usedPercent = container.loose(Double.self, .usedPercent)
        remainingPercent = container.loose(Double.self, .remainingPercent)
        packages = container.loose(Int.self, .packages)
        unit = container.loose(String.self, .unit)
        planExpiresAt = container.loose(String.self, .planExpiresAt)
        planUsed = container.loose(Double.self, .planUsed)
        planTotal = container.loose(Double.self, .planTotal)
        addonUsed = container.loose(Double.self, .addonUsed)
        addonTotal = container.loose(Double.self, .addonTotal)
        orgResourcePackage = container.loose(String.self, .orgResourcePackage)
        source = container.loose(String.self, .source)
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer {
    /// 字段级宽容解码：类型不符就当没有，而不是让整个对象解码失败。
    func loose<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

struct CollectorOutput: Decodable, Sendable {
    let version: Int?
    let updatedAt: Int?
    let providers: [String: ProviderResult]?
    /// 解码失败或版本不符的 provider，键为采集器里的名字，值为可直接展示的中文原因。
    let providerErrors: [String: String]

    private enum CodingKeys: String, CodingKey {
        case version, updatedAt, providers
    }

    static let supportedVersion = 1

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = container.loose(Int.self, .version)
        updatedAt = container.loose(Int.self, .updatedAt)
        var parsed: [String: ProviderResult] = [:]
        var failures: [String: String] = [:]
        if version != nil, version != Self.supportedVersion {
            failures["all"] = "采集器输出版本 \(version!) 与当前应用不匹配"
        }
        if let nested = try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .providers) {
            for key in nested.allKeys {
                if let result = try? nested.decode(ProviderResult.self, forKey: key) {
                    parsed[key.stringValue] = result
                } else {
                    failures[key.stringValue] = "该平台的返回结构已变化，请升级应用"
                }
            }
        } else if container.contains(.providers) {
            failures["all"] = "采集器返回的 providers 不是对象"
        }
        providers = parsed.isEmpty ? nil : parsed
        providerErrors = failures
    }
}

struct CollectorAction: Decodable, Sendable {
    let ok: Bool
    let status: String?
    let cli: String?
    let url: String?
    let message: String?
    let error: String?
}

/// 通知分类与「打开客户端」按钮的标识符。旧版本按供应商手写，这里改成从枚举原值派生，
/// 保持既有字符串不变（provider.qoder / open.qoder ...），已发出的通知仍可正常响应。
enum NotificationCategory {
    static func forProvider(_ provider: UsageProvider) -> String {
        "provider.\(provider.rawValue)"
    }

    static func openAction(for provider: UsageProvider) -> String {
        "open.\(provider.rawValue)"
    }

    static var all: [String] {
        Providers.ordered.map { forProvider($0.id) }
    }
}

enum AttentionKind: Int, Comparable, Sendable {
    case none = 0
    case claim = 1
    case warning = 2

    static func < (lhs: AttentionKind, rhs: AttentionKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct AttentionItem: Identifiable, Sendable {
    let id: String
    let provider: UsageProvider
    let kind: AttentionKind
    let icon: String
    let title: String
    let detail: String
    let actionTitle: String
    let canDismiss: Bool
}
