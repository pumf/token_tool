import Foundation

/// cache.json / history.json 的落盘格式。
///
/// v1 把三家供应商写成固定键，新增一家就要改结构；v2 改成「版本号 + 按供应商键的字典」，
/// 未注册的键读时被忽略。旧文件仍然可读，写出时只用 v2。
enum LocalDataFormat {
    static let currentVersion = 2
}

/// 一次读取 cache.json 的结果。
struct CacheSnapshot: Sendable {
    var results: [UsageProvider: ProviderResult] = [:]
    var collectedAt: [UsageProvider: Date] = [:]
}

/// 一次读取 history.json 的结果。
struct HistorySnapshot: Sendable {
    var samples: [UsageProvider: [UsageSample]] = [:]
}

private struct CacheEnvelope: Decodable {
    var version: Int?
    var providers: [String: ProviderResult]?
    var lastAt: [String: Double]?
    // v1
    var codex: ProviderResult?
    var workbuddy: ProviderResult?
    var qoder: ProviderResult?
    var fastAt: Double?
    var qoderAt: Double?
}

private struct HistoryEnvelope: Decodable {
    var version: Int?
    var providers: [String: [UsageSample]]?
    // v1
    var qoder: [UsageSample]?
    var workbuddy: [UsageSample]?
    var codex: [UsageSample]?
}

private struct CacheRecord: Encodable {
    let version: Int
    let providers: [String: ProviderResult]
    let lastAt: [String: Double]
}

private struct HistoryRecord: Encodable {
    let version: Int
    let providers: [String: [UsageSample]]
}

enum LocalData {
    /// 读 cache.json：v2 按注册表取键，缺失的供应商就没有缓存；v1 用固定键并共享快刷时间。
    static func decodeCache(_ data: Data) -> CacheSnapshot? {
        guard let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data) else { return nil }
        var snapshot = CacheSnapshot()
        if envelope.version != nil || envelope.providers != nil {
            for pair in envelope.providers ?? [:] {
                guard let id = providerID(forCollectorKey: pair.key) else {
                    Diagnostics.record("cache", "忽略未注册的供应商缓存：\(pair.key)")
                    continue
                }
                snapshot.results[id] = pair.value
            }
            for pair in envelope.lastAt ?? [:] {
                guard let id = providerID(forCollectorKey: pair.key) else { continue }
                snapshot.collectedAt[id] = Date(timeIntervalSince1970: pair.value)
            }
            return snapshot
        }
        // v1：三家固定键，Codex 与 WorkBuddy 共用一次快刷时间。
        let legacyResults = [
            "codex": envelope.codex,
            "workbuddy": envelope.workbuddy,
            "qoder": envelope.qoder,
        ].compactMapValues { $0 }
        let legacyLastAt = [
            "codex": envelope.fastAt,
            "workbuddy": envelope.fastAt,
            "qoder": envelope.qoderAt,
        ].compactMapValues { epoch in epoch.map { Date(timeIntervalSince1970: $0) } }
        for descriptor in Providers.all {
            if let result = legacyResults[descriptor.collectorKey] {
                snapshot.results[descriptor.id] = result
            }
            if let at = legacyLastAt[descriptor.collectorKey] {
                snapshot.collectedAt[descriptor.id] = at
            }
        }
        return snapshot
    }

    static func encodeCache(_ snapshot: CacheSnapshot) -> Data? {
        var providers: [String: ProviderResult] = [:]
        var lastAt: [String: Double] = [:]
        for descriptor in Providers.all {
            if let result = snapshot.results[descriptor.id] {
                providers[descriptor.collectorKey] = result
            }
            if let at = snapshot.collectedAt[descriptor.id] {
                lastAt[descriptor.collectorKey] = at.timeIntervalSince1970
            }
        }
        let record = CacheRecord(
            version: LocalDataFormat.currentVersion,
            providers: providers,
            lastAt: lastAt
        )
        return try? JSONEncoder().encode(record)
    }

    /// 读 history.json：只取注册表里认识的键，未注册供应商的历史被忽略。
    static func decodeHistory(_ data: Data) -> HistorySnapshot? {
        guard let envelope = try? JSONDecoder().decode(HistoryEnvelope.self, from: data) else { return nil }
        var snapshot = HistorySnapshot()
        if envelope.version != nil || envelope.providers != nil {
            for pair in envelope.providers ?? [:] {
                guard let id = providerID(forCollectorKey: pair.key) else {
                    Diagnostics.record("history", "忽略未注册的供应商历史：\(pair.key)")
                    continue
                }
                snapshot.samples[id] = pair.value
            }
            return snapshot
        }
        // v1：固定键写死三家，缺键按空历史处理。
        let legacySamples = [
            "qoder": envelope.qoder,
            "workbuddy": envelope.workbuddy,
            "codex": envelope.codex,
        ].compactMapValues { $0 }
        for descriptor in Providers.all {
            snapshot.samples[descriptor.id] = legacySamples[descriptor.collectorKey] ?? []
        }
        return snapshot
    }

    static func encodeHistory(_ snapshot: HistorySnapshot) -> Data? {
        var providers: [String: [UsageSample]] = [:]
        for descriptor in Providers.all {
            providers[descriptor.collectorKey] = snapshot.samples[descriptor.id] ?? []
        }
        let record = HistoryRecord(version: LocalDataFormat.currentVersion, providers: providers)
        return try? JSONEncoder().encode(record)
    }

    private static func providerID(forCollectorKey key: String) -> UsageProvider? {
        Providers.all.first { $0.collectorKey == key }?.id
    }
}
