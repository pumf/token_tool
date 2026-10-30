import Foundation

// Analytics 纯函数、供应商注册表、本地数据格式与 CSV 导出的回归测试。
//
// 本机只有 CommandLineTools（没有 Xcode，XCTest 与 swift-testing 都不可用），
// 因此测试与源码一起用 swiftc 编译成可执行文件，由 ./test.sh 运行。
//
// 这里覆盖的都是历史上真实踩过的口径：领取/重置带来的增加不能算成消耗、
// 天级以上的 Codex 窗口不能用近 1 小时速率外推、跨重置周期的样本必须剔除。

private var failures = 0
private var checks = 0

private func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    guard !condition else { return }
    failures += 1
    print("  ✗ 第 \(line) 行：\(message())")
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, line: Int = #line) {
    check(actual == expected, "期望 \(expected)，实际 \(actual)", line: line)
}

private func expectClose(
    _ actual: Double?,
    _ expected: Double,
    accuracy: Double = 0.01,
    line: Int = #line
) {
    let text = actual.map { String(format: "%g", $0) } ?? "nil"
    check(abs((actual ?? .nan) - expected) <= accuracy, "期望 \(expected)±\(accuracy)，实际 \(text)", line: line)
}

private func expectNil<T>(_ value: T?, line: Int = #line) {
    check(value == nil, "期望 nil，实际非空", line: line)
}

private func expectNotNil<T>(_ value: T?, line: Int = #line) {
    check(value != nil, "期望非空，实际 nil", line: line)
}

private func expectContains(_ text: String, _ needle: String, line: Int = #line) {
    check(text.contains(needle), "期望包含「\(needle)」，实际「\(text)」", line: line)
}

private func test(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print(failures == before ? "✓ \(name)" : "✗ \(name)")
}

// MARK: - 固定时钟与样本构造

private let calendar = Calendar.current

/// 固定「现在」为当天 12:00（本地时区），断言不随运行时刻漂移。
private let noon: Date = {
    let start = calendar.startOfDay(for: Date())
    return calendar.date(byAdding: .hour, value: 12, to: start)!
}()

/// 当天 12:00 之前/之后若干小时（负数为之前）。
private func offset(_ hours: Double) -> Date {
    noon.addingTimeInterval(hours * 3600)
}

private func creditSample(at date: Date, remaining: Double, total: Double = 2600) -> UsageSample {
    UsageSample(
        at: Int(date.timeIntervalSince1970),
        remaining: remaining,
        total: total,
        remainingPercent: remaining * 100 / total,
        windows: nil
    )
}

private func creditInput(remaining: Double, total: Double = 2600) -> UsageInput {
    UsageInput(remaining: remaining, total: total, remainingPercent: nil, windows: [])
}

private func codexSample(
    at date: Date,
    minutes: Int,
    remainingPercent: Double,
    resetsAt: Int
) -> UsageSample {
    UsageSample(
        at: Int(date.timeIntervalSince1970),
        remaining: nil,
        total: nil,
        remainingPercent: remainingPercent,
        windows: [WindowUsageSample(
            minutes: minutes,
            remainingPercent: remainingPercent,
            usedPercent: 100 - remainingPercent,
            resetsAt: resetsAt
        )]
    )
}

private func codexInput(minutes: Int, remainingPercent: Double, resetsAt: Int) -> UsageInput {
    UsageInput(remaining: nil, total: nil, remainingPercent: remainingPercent, windows: [
        UsageWindow(
            minutes: minutes,
            remainingPercent: remainingPercent,
            usedPercent: 100 - remainingPercent,
            resetsAt: resetsAt
        ),
    ])
}

private func creditForecast(samples: [UsageSample], remaining: Double, total: Double = 2600) -> UsageForecast? {
    UsageAnalytics.forecast(
        provider: .qoder,
        input: creditInput(remaining: remaining, total: total),
        samples: samples,
        now: noon
    )
}

@main
struct AnalyticsSuite {
    static func main() {
        runCurrentPercent()
        runPrune()
        runInsight()
        runCreditForecast()
        runCodexForecast()
        runRampRates()
        runFormatting()
        runSample()
        runRegistry()
        runPersistence()
        runExport()

        print("\n\(checks) 项断言，\(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: currentPercent

    static func runCurrentPercent() {
        test("积分制优先用上报的百分比") {
            let input = UsageInput(remaining: 100, total: 1000, remainingPercent: 71.9, windows: [])
            expectEqual(UsageAnalytics.currentPercent(provider: .qoder, input: input), 71.9)
        }
        test("积分制缺百分比时按剩余/总量折算") {
            let input = UsageInput(remaining: 250, total: 1000, remainingPercent: nil, windows: [])
            expectClose(UsageAnalytics.currentPercent(provider: .workbuddy, input: input), 25)
        }
        test("百分比越界被夹回 0...100") {
            let input = UsageInput(remaining: nil, total: nil, remainingPercent: 140, windows: [])
            expectEqual(UsageAnalytics.currentPercent(provider: .qoder, input: input), 100)
        }
        test("Codex 取最紧张的窗口") {
            let input = UsageInput(remaining: nil, total: nil, remainingPercent: 58, windows: [
                UsageWindow(minutes: 300, remainingPercent: 58, usedPercent: 42, resetsAt: nil),
                UsageWindow(minutes: 10080, remainingPercent: 12, usedPercent: 88, resetsAt: nil),
            ])
            expectEqual(UsageAnalytics.currentPercent(provider: .codex, input: input), 12)
        }
    }

    // MARK: prune

    static func runPrune() {
        test("保留期内之外的样本被裁掉") {
            let samples = [
                creditSample(at: offset(-40 * 24), remaining: 100),
                creditSample(at: offset(-10 * 24), remaining: 200),
                creditSample(at: offset(-1), remaining: 300),
            ]
            let pruned = UsageAnalytics.prune(samples, now: noon)
            expectEqual(pruned.count, 2)
            expectEqual(pruned.first?.remaining, 200)
            expectEqual(pruned.last?.remaining, 300)
        }
        test("超量时保留最新的样本") {
            let samples = (0...UsageAnalytics.maxSamplesPerProvider).map {
                creditSample(at: noon.addingTimeInterval(Double($0)), remaining: Double($0))
            }
            let pruned = UsageAnalytics.prune(samples, now: noon)
            expectEqual(pruned.count, UsageAnalytics.maxSamplesPerProvider)
            expectEqual(pruned.last?.remaining, Double(samples.count - 1))
        }
    }

    // MARK: insight

    static func runInsight() {
        test("样本不足 6 小时时不给日均，只给今日消耗") {
            let samples = [
                creditSample(at: offset(10), remaining: 1000),
                creditSample(at: offset(12), remaining: 950),
            ]
            let insight = UsageAnalytics.insight(
                provider: .qoder, input: creditInput(remaining: 950), samples: samples, now: noon
            )
            expectNotNil(insight)
            expectClose(insight?.todayConsumed, 50)
            expectNil(insight?.dailyAverage)
            expectNil(insight?.netDailyAverage)
            expectEqual(insight?.observedDays, 1)
            expectEqual(insight?.isPercent, false)
        }
        test("没有样本时不给洞察") {
            let insight = UsageAnalytics.insight(
                provider: .qoder, input: creditInput(remaining: 950), samples: [], now: noon
            )
            expectNil(insight)
        }
        test("领取回补不计入消耗，净日均低于毛日均") {
            // 6 小时里消耗 180，其中 07:00 领取回补 100 → 净消耗 80。
            let samples = [
                creditSample(at: offset(5), remaining: 500),
                creditSample(at: offset(6), remaining: 400),
                creditSample(at: offset(7), remaining: 500),
                creditSample(at: offset(8), remaining: 450),
                creditSample(at: offset(9), remaining: 440),
                creditSample(at: offset(10), remaining: 430),
                creditSample(at: offset(11), remaining: 420),
            ]
            let insight = UsageAnalytics.insight(
                provider: .qoder, input: creditInput(remaining: 420), samples: samples, now: noon
            )
            expectClose(insight?.todayConsumed, 180)
            expectClose(insight?.dailyAverage, 180)
            expectClose(insight?.netDailyAverage, 80)
        }
        test("套餐总量变化带来的增加整对跳过") {
            // 04:00→05:00 是升级套餐（2600→6000），这 1000 的增加不能被当成消耗或回补。
            let samples = [
                creditSample(at: offset(4), remaining: 500, total: 2600),
                creditSample(at: offset(5), remaining: 1500, total: 6000),
                creditSample(at: offset(6), remaining: 1400, total: 6000),
                creditSample(at: offset(7), remaining: 1300, total: 6000),
                creditSample(at: offset(8), remaining: 1200, total: 6000),
                creditSample(at: offset(9), remaining: 1100, total: 6000),
                creditSample(at: offset(10), remaining: 1000, total: 6000),
            ]
            let insight = UsageAnalytics.insight(
                provider: .qoder, input: creditInput(remaining: 1000, total: 6000), samples: samples, now: noon
            )
            expectClose(insight?.todayConsumed, 500)
            expectClose(insight?.netDailyAverage, 500)
        }
        test("跨零点的消耗按时间比例折算进今日") {
            // 昨天 23:00 → 今天 01:00 掉 10 个百分点，只有 00:00 之后的那一半算今日。
            let reset = Int(offset(20).timeIntervalSince1970)
            let samples = [
                codexSample(at: offset(-15), minutes: 300, remainingPercent: 65, resetsAt: reset),
                codexSample(at: offset(-13), minutes: 300, remainingPercent: 60, resetsAt: reset),
                codexSample(at: offset(-11), minutes: 300, remainingPercent: 50, resetsAt: reset),
            ]
            let insight = UsageAnalytics.insight(
                provider: .codex,
                input: codexInput(minutes: 300, remainingPercent: 50, resetsAt: reset),
                samples: samples,
                now: noon
            )
            expectClose(insight?.todayConsumed, 5)
            expectEqual(insight?.isPercent, true)
        }
        test("另一个重置周期的样本被剔除") {
            // 窗口重置后剩余比例会跳回 100%，与当前周期不可比（README 演示数据曾因此算不出今日消耗）。
            let currentReset = Int(offset(20).timeIntervalSince1970)
            let samples = [
                codexSample(at: offset(-3), minutes: 300, remainingPercent: 60, resetsAt: currentReset - 18000),
                codexSample(at: offset(-1), minutes: 300, remainingPercent: 50, resetsAt: currentReset - 18000),
            ]
            let insight = UsageAnalytics.insight(
                provider: .codex,
                input: codexInput(minutes: 300, remainingPercent: 40, resetsAt: currentReset),
                samples: samples,
                now: noon
            )
            expectNil(insight)
        }
    }

    // MARK: 积分制预测

    static func runCreditForecast() {
        test("样本积累中：不足 6 小时不下结论") {
            let forecast = creditForecast(samples: [
                creditSample(at: offset(11), remaining: 1000),
                creditSample(at: offset(12), remaining: 990),
            ], remaining: 990)
            expectEqual(forecast?.text, "样本积累中")
            expectEqual(forecast?.warning, false)
        }
        test("近期无明显消耗") {
            let samples = stride(from: 4.0, through: 12.0, by: 1).map {
                creditSample(at: offset($0), remaining: 1000)
            }
            expectEqual(creditForecast(samples: samples, remaining: 1000)?.text, "近期无明显消耗")
        }
        test("领取覆盖消耗时回答不会耗尽") {
            // 消耗 100、领取回补 100 → 净日均约 0，不该给出耗尽时刻。
            let samples = [
                creditSample(at: offset(5), remaining: 500),
                creditSample(at: offset(6), remaining: 400),
                creditSample(at: offset(7), remaining: 500),
                creditSample(at: offset(8), remaining: 500),
                creditSample(at: offset(9), remaining: 500),
                creditSample(at: offset(10), remaining: 500),
                creditSample(at: offset(11), remaining: 500),
            ]
            let forecast = creditForecast(samples: samples, remaining: 500)
            expectEqual(forecast?.text, "按当前节奏不会耗尽")
            expectContains(forecast?.help ?? "", "领取/重置")
        }
        test("按净日均外推剩余天数") {
            // 净日均 80 Credits、剩余 420 → 420/80 = 5.25 天。
            let samples = [
                creditSample(at: offset(5), remaining: 500),
                creditSample(at: offset(6), remaining: 400),
                creditSample(at: offset(7), remaining: 500),
                creditSample(at: offset(8), remaining: 450),
                creditSample(at: offset(9), remaining: 440),
                creditSample(at: offset(10), remaining: 430),
                creditSample(at: offset(11), remaining: 420),
            ]
            let forecast = creditForecast(samples: samples, remaining: 420)
            expectEqual(forecast?.text, "预计 5.2 天后耗尽")
            expectEqual(forecast?.warning, true)   // 420/2600 ≈ 16%，低于默认 20% 阈值
            expectClose(forecast?.ratePerHour, 80 / 24)
        }
    }

    // MARK: Codex 窗口制预测

    static func runCodexForecast() {
        test("天级以上窗口不用近 1 小时速率外推") {
            // 月度窗口 7 天净掉 10 个百分点，最后 1 小时又突降 3 个。
            // 按小时速率外推会得到「23 小时后耗尽」，正确口径是按日均 → 可撑到 20 天后的重置。
            let reset = Int(noon.addingTimeInterval(20 * 86400).timeIntervalSince1970)
            var samples = (1...168).map { hour in
                codexSample(
                    at: noon.addingTimeInterval(-Double(hour) * 3600),
                    minutes: 43200,
                    remainingPercent: 73 + Double(hour - 1) * 7.0 / 167.0,
                    resetsAt: reset
                )
            }
            samples.append(codexSample(at: noon, minutes: 43200, remainingPercent: 70, resetsAt: reset))
            let forecast = UsageAnalytics.forecast(
                provider: .codex,
                input: codexInput(minutes: 43200, remainingPercent: 70, resetsAt: reset),
                samples: samples,
                now: noon
            )
            expectEqual(forecast?.text, "可撑到重置（月度）")
            expectEqual(forecast?.warning, false)
            // 日均口径约 0.06%/小时；若误用小时速率会是 3%/小时。
            expectEqual((forecast?.ratePerHour ?? 1) < 1.0, true)
        }
        test("短窗口按近 1 小时速率给出耗尽风险") {
            // 5 小时窗口剩 40%，近 1 小时掉 11 个百分点 → 约 3.3 小时后耗尽，早于 5 小时后的重置。
            let reset = Int(noon.addingTimeInterval(5 * 3600).timeIntervalSince1970)
            var samples = (2...168).map { hour in
                codexSample(
                    at: noon.addingTimeInterval(-Double(hour) * 3600),
                    minutes: 300,
                    remainingPercent: 50,
                    resetsAt: reset
                )
            }
            for minute in stride(from: 55, through: 0, by: -5) {
                samples.append(codexSample(
                    at: noon.addingTimeInterval(-Double(minute) * 60),
                    minutes: 300,
                    remainingPercent: 40 + Double(minute) * 0.2,
                    resetsAt: reset
                ))
            }
            let forecast = UsageAnalytics.forecast(
                provider: .codex,
                input: codexInput(minutes: 300, remainingPercent: 40, resetsAt: reset),
                samples: samples,
                now: noon
            )
            expectEqual(forecast?.text, "5 小时窗口预计 3.3 小时后耗尽")
            expectEqual(forecast?.warning, true)
            expectContains(forecast?.help ?? "", "早于重置时间")
        }
        test("完全没有速率时不给耗尽估算") {
            let reset = Int(noon.addingTimeInterval(5 * 86400).timeIntervalSince1970)
            let samples = (1...168).map { hour in
                codexSample(
                    at: noon.addingTimeInterval(-Double(hour) * 3600),
                    minutes: 10080,
                    remainingPercent: 82,
                    resetsAt: reset
                )
            }
            let forecast = UsageAnalytics.forecast(
                provider: .codex,
                input: codexInput(minutes: 10080, remainingPercent: 82, resetsAt: reset),
                samples: samples,
                now: noon
            )
            expectEqual(forecast?.text, "近期无明显消耗")
        }
    }

    // MARK: 消耗加速

    static func runRampRates() {
        test("短窗口速率与基线速率分开统计") {
            // 前两小时每小时 1 个百分点，最后 15 分钟掉 8 个 → 短速率应显著高于基线。
            let samples = stride(from: 2.0, through: 0.0, by: -0.25).map { hoursAgo in
                UsageSample(
                    at: Int(offset(-hoursAgo).timeIntervalSince1970),
                    remaining: 1000,
                    total: 2600,
                    remainingPercent: hoursAgo < 0.01 ? 90 : 100 - (2.0 - hoursAgo),
                    windows: nil
                )
            }
            let rates = UsageAnalytics.rampRates(
                provider: .qoder, input: creditInput(remaining: 1000), samples: samples, now: noon
            )
            expectClose(rates.baseline, 1.0)
            expectClose(rates.short, 33.0)
            expectEqual((rates.short ?? 0) > (rates.baseline ?? 0) * 3, true)
        }
    }

    // MARK: 文案

    static func runFormatting() {
        test("时长文案分档") {
            expectEqual(UsageAnalytics.durationText(0.004), "不到 1 分钟")
            expectEqual(UsageAnalytics.durationText(0.5), "30 分钟")
            expectEqual(UsageAnalytics.durationText(3.5), "3.5 小时")
            expectEqual(UsageAnalytics.durationText(36), "1.5 天")
            expectEqual(UsageAnalytics.durationText(24 * 12.4), "12 天")
        }
        test("窗口时长文案") {
            expectEqual(UsageAnalytics.windowText(300), "5 小时")
            expectEqual(UsageAnalytics.windowText(1440), "1 天")
            expectEqual(UsageAnalytics.windowText(10080), "周")
            expectEqual(UsageAnalytics.windowText(43200), "月度")
            expectEqual(UsageAnalytics.windowText(45), "45 分钟")
            expectEqual(UsageAnalytics.windowText(0), "额度")
        }
    }

    // MARK: 采样

    static func runSample() {
        test("积分制样本记录剩余与总量") {
            let input = UsageInput(remaining: 1870, total: 2600, remainingPercent: 71.92, windows: [])
            let sample = UsageAnalytics.sample(provider: .qoder, input: input, at: noon)
            expectEqual(sample?.remaining, 1870)
            expectEqual(sample?.total, 2600)
            expectNil(sample?.windows)
        }
        test("Codex 样本以首个窗口为准并保留全部窗口") {
            let reset = Int(noon.addingTimeInterval(4 * 3600).timeIntervalSince1970)
            let input = UsageInput(remaining: nil, total: nil, remainingPercent: nil, windows: [
                UsageWindow(minutes: 300, remainingPercent: 58, usedPercent: 42, resetsAt: reset),
                UsageWindow(minutes: 10080, remainingPercent: 82, usedPercent: 18, resetsAt: reset),
            ])
            let sample = UsageAnalytics.sample(provider: .codex, input: input, at: noon)
            expectNil(sample?.remaining)
            expectEqual(sample?.remainingPercent, 58)
            expectEqual(sample?.windows?.count, 2)
        }
        test("无可用数据时不产生样本") {
            let input = UsageInput(remaining: nil, total: nil, remainingPercent: nil, windows: [])
            expectNil(UsageAnalytics.sample(provider: .qoder, input: input, at: noon))
        }
    }

    // MARK: 供应商注册表

    /// 注册表承担的是「行为等价的旧代码」这件事，所以断言写的都是重构前已经存在的
    /// 顺序、节奏与键名，而不是注册表自创的约定。
    static func runRegistry() {
        test("枚举里的供应商都有注册条目") {
            expectEqual(Providers.all.count, UsageProvider.allCases.count)
            for provider in UsageProvider.allCases {
                expectEqual(Providers.descriptor(provider).id, provider)
            }
        }
        test("采集键与开关键名互不重复") {
            expectEqual(Set(Providers.all.map(\.collectorKey)).count, Providers.all.count)
            expectEqual(Set(Providers.all.map(\.menuBarDefaultsKey)).count, Providers.all.count)
            expectEqual(Set(Providers.all.map(\.reminderDefaultsKey)).count, Providers.all.count)
        }
        test("面板展示顺序仍是 Qoder / WorkBuddy / Codex") {
            expectEqual(Providers.ordered.map(\.id), [.qoder, .workbuddy, .codex])
        }
        test("额度口径归属") {
            expectEqual(Providers.descriptor(.qoder).quotaKind, .credits)
            expectEqual(Providers.descriptor(.workbuddy).quotaKind, .credits)
            expectEqual(Providers.descriptor(.codex).quotaKind, .percentWindow)
            expectEqual(Providers.all.filter(\.isPercent).map(\.id), [UsageProvider.codex])
        }
        test("既有的 UserDefaults 键名保持不变") {
            expectEqual(Providers.descriptor(.qoder).menuBarDefaultsKey, "menuBar.qoder")
            expectEqual(Providers.descriptor(.workbuddy).menuBarDefaultsKey, "menuBar.workbuddy")
            expectEqual(Providers.descriptor(.codex).menuBarDefaultsKey, "menuBar.codex")
            expectEqual(Providers.descriptor(.qoder).reminderDefaultsKey, "reminder.qoder.claim")
            expectEqual(Providers.descriptor(.workbuddy).reminderDefaultsKey, "reminder.workbuddy.claim")
            expectEqual(Providers.descriptor(.codex).reminderDefaultsKey, "reminder.codex.reset")
        }
        test("刷新分组沿用旧的两档节奏与采集顺序") {
            let groups = Providers.groups
            expectEqual(groups.count, 2)
            // 60 秒一档里 Codex 的超时预算更大，所以仍然先起 Codex、再起 WorkBuddy。
            expectEqual(groups[0].interval, 60.0)
            expectEqual(groups[0].providers, [.codex, .workbuddy])
            expectEqual(groups[1].interval, 90.0)
            expectEqual(groups[1].providers, [UsageProvider.qoder])
            expectEqual(groups.flatMap(\.providers).count, Providers.all.count)
        }
        test("只有采集最慢的 Qoder 在面板展开时补采") {
            expectEqual(Providers.panelRefreshProviders, [UsageProvider.qoder])
        }
        test("登录引导只挂在需要 CLI 的供应商上") {
            let needingSetup = Providers.all.filter { descriptor in
                if case .qoderCLI = descriptor.setup { return true }
                return false
            }
            expectEqual(needingSetup.map(\.id), [UsageProvider.qoder])
        }
        test("每日领取提醒的时间与额度") {
            for descriptor in Providers.all {
                guard case let .daily(hour, grant, _) = descriptor.claimReminder else { continue }
                switch descriptor.id {
                case .qoder:
                    expectEqual(hour, 10)
                    expectEqual(grant, "100 Credits")
                case .workbuddy:
                    expectEqual(hour, 0)
                    expectEqual(grant, "100 积分")
                case .codex:
                    check(false, "Codex 不该有每日领取提醒")
                }
            }
        }
        test("通知分类标识保持旧字符串") {
            expectEqual(NotificationCategory.forProvider(.qoder), "provider.qoder")
            expectEqual(NotificationCategory.forProvider(.workbuddy), "provider.workbuddy")
            expectEqual(NotificationCategory.forProvider(.codex), "provider.codex")
            expectEqual(NotificationCategory.openAction(for: .codex), "open.codex")
            expectEqual(NotificationCategory.all.count, Providers.ordered.count)
        }
    }

    // MARK: 本地数据格式

    static func runPersistence() {
        test("v1 缓存：固定三家键，Codex 与 WorkBuddy 共用快刷时间") {
            let snapshot = LocalData.decodeCache(data("""
            {"codex":{"ok":true,"updatedAt":100},"workbuddy":{"ok":true,"updatedAt":100},
             "qoder":{"ok":true,"updatedAt":90,"remaining":1870,"total":2600},
             "fastAt":100,"qoderAt":90}
            """))
            expectEqual(snapshot?.results[.qoder]?.remaining, 1870)
            expectEqual(snapshot?.collectedAt[.codex], Date(timeIntervalSince1970: 100))
            expectEqual(snapshot?.collectedAt[.workbuddy], Date(timeIntervalSince1970: 100))
            expectEqual(snapshot?.collectedAt[.qoder], Date(timeIntervalSince1970: 90))
        }
        test("v1 缓存：缺某一家就只读到有的几家") {
            let snapshot = LocalData.decodeCache(data(#"{"qoder":{"ok":true,"total":500},"qoderAt":90}"#))
            expectEqual(snapshot?.results.count, 1)
            expectEqual(snapshot?.results[.qoder]?.total, 500)
            expectEqual(snapshot?.collectedAt.count, 1)
        }
        test("v2 缓存：按供应商键读取结果与采集时间") {
            let snapshot = LocalData.decodeCache(data("""
            {"version":2,"providers":{"qoder":{"ok":true,"remaining":120}},
             "lastAt":{"qoder":1600,"codex":1700}}
            """))
            expectEqual(snapshot?.results[.qoder]?.remaining, 120)
            expectEqual(snapshot?.collectedAt[.qoder], Date(timeIntervalSince1970: 1600))
            expectEqual(snapshot?.collectedAt[.codex], Date(timeIntervalSince1970: 1700))
        }
        test("v2 缓存：未注册的供应商键被忽略") {
            // 这条会往诊断日志里落一行「忽略未注册的供应商缓存」，属于预期行为。
            let snapshot = LocalData.decodeCache(data(
                #"{"version":2,"providers":{"someone":{"ok":true,"remaining":1}}"#
                    + #","lastAt":{"someone":1600}}"#
            ))
            expectEqual(snapshot?.results.count, 0)
            expectEqual(snapshot?.collectedAt.count, 0)
        }
        test("v2 缓存：写出带版本号，读回来数值不变") {
            let original = LocalData.decodeCache(data(
                #"{"version":2,"providers":{"workbuddy":{"ok":true,"remaining":42,"total":100}}"#
                    + #","lastAt":{"workbuddy":1600}}"#
            ))!
            let encoded = LocalData.encodeCache(original)!
            expectContains(String(data: encoded, encoding: .utf8)!, #""version":2"#)
            let restored = LocalData.decodeCache(encoded)
            expectEqual(restored?.results[.workbuddy]?.remaining, 42)
            expectEqual(restored?.collectedAt[.workbuddy], Date(timeIntervalSince1970: 1600))
        }
        test("v1 历史：固定三家键") {
            let snapshot = LocalData.decodeHistory(data("""
            {"qoder":[{"at":100,"remaining":1870,"total":2600,"remainingPercent":71.9}],
             "codex":[{"at":120,"remainingPercent":58,"windows":[{"minutes":300,
                "remainingPercent":58,"usedPercent":42,"resetsAt":130}]}]}
            """))
            expectEqual(snapshot?.samples[.qoder]?.count, 1)
            expectEqual(snapshot?.samples[.qoder]?.first?.remaining, 1870)
            expectEqual(snapshot?.samples[.codex]?.first?.windows?.first?.minutes, 300)
            expectEqual(snapshot?.samples[.workbuddy]?.count, 0)
        }
        test("v2 历史：未注册的供应商键被忽略，其余照常读出") {
            let snapshot = LocalData.decodeHistory(data(
                #"{"version":2,"providers":{"qoder":[{"at":100,"remaining":10,"total":20,"remainingPercent":50}],"someone":[]}}"#
            ))
            expectEqual(snapshot?.samples.count, 1)
            expectEqual(snapshot?.samples[.qoder]?.first?.total, 20)
        }
        test("v2 历史：写出带版本号并按注册表补齐每一家") {
            let original = LocalData.decodeHistory(data(
                #"{"version":2,"providers":{"codex":[{"at":100,"remainingPercent":30}]}}"#
            ))!
            let encoded = LocalData.encodeHistory(original)!
            let text = String(data: encoded, encoding: .utf8)!
            expectContains(text, #""version":2"#)
            for key in ["qoder", "workbuddy", "codex"] {
                expectContains(text, "\"\(key)\":")
            }
            expectEqual(LocalData.decodeHistory(encoded)?.samples[.codex]?.first?.remainingPercent, 30)
        }
        test("读不出来的文件返回 nil，交给上层回退备份") {
            expectNil(LocalData.decodeCache(data("not json at all")))
            expectNil(LocalData.decodeHistory(data("{")))
        }
    }

    // MARK: CSV 导出

    static func runExport() {
        test("表头与列结构保持不变") {
            let text = UsageExport.csv([:])
            expectEqual(
                text.split(separator: "\n").map(String.init)[0],
                "provider,timestamp,remaining,total,remaining_percent,"
                    + "window_minutes,window_remaining_percent,window_used_percent,resets_at"
            )
            expectEqual(text, "provider,timestamp,remaining,total,remaining_percent,"
                + "window_minutes,window_remaining_percent,window_used_percent,resets_at\n")
        }
        test("按注册表顺序导出，字典顺序不影响行序") {
            let samples: [UsageProvider: [UsageSample]] = [
                .codex: [UsageSample(
                    at: 1_700_000_000,
                    remaining: nil,
                    total: nil,
                    remainingPercent: 58,
                    windows: [WindowUsageSample(
                        minutes: 300,
                        remainingPercent: 58,
                        usedPercent: 42,
                        resetsAt: 1_700_001_800
                    )]
                )],
                .qoder: [UsageSample(
                    at: 1_700_000_000,
                    remaining: 1870,
                    total: 2600,
                    remainingPercent: 71.92,
                    windows: nil
                )],
            ]
            let rows = UsageExport.csv(samples).split(separator: "\n").map(String.init)
            expectEqual(rows.count, 3)
            check(rows[1].hasPrefix("qoder,"), "第二行应是 Qoder，实际「\(rows[1])」")
            expectContains(rows[1], "1870.00")
            expectContains(rows[1], "2600.00")
            check(rows[2].hasPrefix("codex,"), "第三行应是 Codex，实际「\(rows[2])」")
            expectContains(rows[2], ",300,58.00,42.00,")
        }
    }

    private static func data(_ text: String) -> Data {
        Data(text.utf8)
    }
}
