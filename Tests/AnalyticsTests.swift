import AppKit
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

/// 本周一 00:00（随 Calendar.firstWeekday），周汇总测试以此为锚点构造样本。
private let weekStart: Date = Calendar.current.dateInterval(of: .weekOfYear, for: noon)!.start

/// 本周一之后若干天（负数为上周）。
private func weekOffset(_ days: Double) -> Date {
    weekStart.addingTimeInterval(days * 86400)
}

private func creditWeekly(samples: [UsageSample], remaining: Double, total: Double = 2600) -> WeeklyUsage? {
    UsageAnalytics.weekly(
        provider: .qoder,
        input: creditInput(remaining: remaining, total: total),
        samples: samples,
        now: noon
    )
}

/// 本月 1 号 00:00，月度预算测试以此为锚点。
private let monthStart: Date = Calendar.current.dateInterval(of: .month, for: noon)!.start

private func monthOffset(_ days: Double) -> Date {
    monthStart.addingTimeInterval(days * 86400)
}

@main
struct AnalyticsSuite {
    static func main() {
        runCurrentPercent()
        runPrune()
        runInsight()
        runWeekly()
        runMonthConsumed()
        runCreditForecast()
        runCodexForecast()
        runRampRates()
        runFormatting()
        runSample()
        runRegistry()
        runCardOrder()
        runPersistence()
        runExport()
        runMenuBar()
        runUpdate()
        runDiagnostics()

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
                creditSample(at: offset(-100 * 24), remaining: 100),
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
            expectNil(insight?.yesterdayConsumed)
            expectEqual(insight?.observedDays, 1)
            expectEqual(insight?.isPercent, false)
        }
        test("昨日全天只算昨天 00:00 到今天 00:00 那段") {
            // 昨天每小时掉 50（24 小时共 1200），今天每小时掉 10（00:00→12:00 共 120）。
            let samples = (0...36).map { hour -> UsageSample in
                let consumed = Double(hour) <= 24
                    ? Double(hour) * 50
                    : 1200 + (Double(hour) - 24) * 10
                return creditSample(at: offset(-36 + Double(hour)), remaining: 2600 - consumed)
            }
            let insight = UsageAnalytics.insight(
                provider: .qoder, input: creditInput(remaining: 1280), samples: samples, now: noon
            )
            expectClose(insight?.yesterdayConsumed, 1200)
            expectClose(insight?.todayConsumed, 120)
        }
        test("昨日全天里领取回补不计入，跨零点的样本对不再丢") {
            let samples = [
                creditSample(at: offset(-36), remaining: 1000),
                creditSample(at: offset(-30), remaining: 400),
                creditSample(at: offset(-24), remaining: 900),   // 昨天中午领取回补 500
                creditSample(at: offset(-12), remaining: 800),   // 正好落在今天 00:00
                creditSample(at: offset(0), remaining: 700),
            ]
            let insight = UsageAnalytics.insight(
                provider: .qoder, input: creditInput(remaining: 700), samples: samples, now: noon
            )
            // 昨天 00:00→24:00 一共掉 700，回补的 500 不算消耗，跨零点对归昨天不归今日。
            expectClose(insight?.yesterdayConsumed, 700)
            expectClose(insight?.todayConsumed, 100)
        }
        test("昨天没采满时不给昨日参照") {
            // 昨天下午才开机，昨天 00:00 到 15:00 那段没有样本，硬给「昨天用了 X」会低估。
            let samples = (0...20).map { hour -> UsageSample in
                creditSample(at: offset(-21 + Double(hour)), remaining: 2000 - Double(hour) * 30)
            }
            let insight = UsageAnalytics.insight(
                provider: .qoder, input: creditInput(remaining: 1400), samples: samples, now: noon
            )
            expectNotNil(insight)
            expectNil(insight?.yesterdayConsumed)
            expectClose(insight?.todayConsumed, 330)
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

    // MARK: 每周汇总

    static func runWeekly() {
        test("本周消耗只算下降，领取回补不计入") {
            let samples = [
                creditSample(at: weekOffset(0), remaining: 1000),
                creditSample(at: weekOffset(1.0 / 24), remaining: 900),
                creditSample(at: weekOffset(2.0 / 24), remaining: 1000),   // 领取回补 100
                creditSample(at: weekOffset(3.0 / 24), remaining: 950),
            ]
            let weekly = creditWeekly(samples: samples, remaining: 950)
            expectClose(weekly?.thisWeek, 150)
            expectNil(weekly?.lastWeek)
            expectEqual(weekly?.isPercent, false)
        }
        test("上周满采时给对比，跨周那一对按时间比例拆分") {
            // 上周每小时掉 1（周一 00:00 到周日 23:00 共 167），跨周对 2 小时掉 20 → 各分 10。
            var samples = (0...167).map { hour in
                creditSample(at: weekOffset(-7 + Double(hour) / 24), remaining: 2000 - Double(hour))
            }
            samples.append(creditSample(at: weekOffset(1.0 / 24), remaining: 1813))
            let weekly = creditWeekly(samples: samples, remaining: 1813)
            expectClose(weekly?.thisWeek, 10)
            expectClose(weekly?.lastWeek, 177)
        }
        test("上周有采样即给对比，间隙按端点差值折算") {
            // 上周只采到两天，但端点差值仍能给出周总量（间隙里剩余没掉就是没消耗）。
            var samples = [
                creditSample(at: weekOffset(-7), remaining: 1000),
                creditSample(at: weekOffset(-6), remaining: 900),
            ]
            samples.append(creditSample(at: weekOffset(0), remaining: 900))
            samples.append(creditSample(at: weekOffset(1.0 / 24), remaining: 880))
            let weekly = creditWeekly(samples: samples, remaining: 880)
            expectClose(weekly?.thisWeek, 20)
            expectClose(weekly?.lastWeek, 100)
        }
        test("套餐总量变化带来的增加整对跳过") {
            let samples = [
                creditSample(at: weekOffset(0), remaining: 500, total: 2600),
                creditSample(at: weekOffset(1.0 / 24), remaining: 1500, total: 6000),
                creditSample(at: weekOffset(2.0 / 24), remaining: 1400, total: 6000),
            ]
            let weekly = creditWeekly(samples: samples, remaining: 1400, total: 6000)
            expectClose(weekly?.thisWeek, 100)
        }
        test("Codex 一周内多个重置周期的消耗累加，跨重置对跳过") {
            let resetA = Int(weekOffset(1).timeIntervalSince1970)
            let resetB = Int(weekOffset(2).timeIntervalSince1970)
            let samples = [
                codexSample(at: weekOffset(0), minutes: 300, remainingPercent: 80, resetsAt: resetA),
                codexSample(at: weekOffset(1.0 / 24), minutes: 300, remainingPercent: 60, resetsAt: resetA),
                codexSample(at: weekOffset(2.0 / 24), minutes: 300, remainingPercent: 100, resetsAt: resetB),
                codexSample(at: weekOffset(3.0 / 24), minutes: 300, remainingPercent: 70, resetsAt: resetB),
            ]
            let weekly = UsageAnalytics.weekly(
                provider: .codex,
                input: codexInput(minutes: 300, remainingPercent: 70, resetsAt: resetB),
                samples: samples,
                now: noon
            )
            expectClose(weekly?.thisWeek, 50)
            expectEqual(weekly?.isPercent, true)
        }
        test("只有上周样本时本周为空") {
            let samples = (0...168).map { hour in
                creditSample(at: weekOffset(-7 + Double(hour) / 24), remaining: 2000 - Double(hour))
            }
            let weekly = creditWeekly(samples: samples, remaining: 1832)
            expectNil(weekly?.thisWeek)
            expectClose(weekly?.lastWeek, 168)
        }
    }

    // MARK: 月度消耗

    static func runMonthConsumed() {
        func consumed(_ samples: [UsageSample], remaining: Double, total: Double = 2600) -> Double? {
            UsageAnalytics.monthConsumed(
                provider: .qoder,
                input: creditInput(remaining: remaining, total: total),
                samples: samples,
                now: noon
            )
        }
        test("本月消耗只算下降，领取回补不计入") {
            let samples = [
                creditSample(at: monthOffset(0), remaining: 1000),
                creditSample(at: monthOffset(1.0 / 24), remaining: 900),
                creditSample(at: monthOffset(2.0 / 24), remaining: 1000),
                creditSample(at: monthOffset(3.0 / 24), remaining: 950),
            ]
            expectClose(consumed(samples, remaining: 950), 150)
        }
        test("套餐总量变化带来的增加整对跳过") {
            let samples = [
                creditSample(at: monthOffset(0), remaining: 500, total: 2600),
                creditSample(at: monthOffset(1.0 / 24), remaining: 1500, total: 6000),
                creditSample(at: monthOffset(2.0 / 24), remaining: 1400, total: 6000),
            ]
            expectClose(consumed(samples, remaining: 1400, total: 6000), 100)
        }
        test("本月样本不足两个时不给消耗") {
            expectNil(consumed([creditSample(at: monthOffset(0), remaining: 1000)], remaining: 1000))
        }
        test("上月样本不计入本月") {
            let samples = [
                creditSample(at: monthOffset(-1), remaining: 2000),
                creditSample(at: monthOffset(0), remaining: 1000),
                creditSample(at: monthOffset(1.0 / 24), remaining: 950),
            ]
            expectClose(consumed(samples, remaining: 950), 50)
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
        test("只有余额的一家也要留下样本") {
            let input = UsageInput(remaining: 1286, total: nil, remainingPercent: nil, windows: [])
            let sample = UsageAnalytics.sample(provider: .trae, input: input, at: noon)
            expectEqual(sample?.remaining, 1286)
            expectNil(sample?.total)
            expectNil(sample?.remainingPercent)
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
        test("面板展示顺序仍是 Qoder / WorkBuddy / Codex / Claude Code / Trae") {
            expectEqual(Providers.ordered.map(\.id), [.qoder, .workbuddy, .codex, .claude, .trae])
        }
        test("额度口径归属") {
            expectEqual(Providers.descriptor(.qoder).quotaKind, .credits)
            expectEqual(Providers.descriptor(.workbuddy).quotaKind, .credits)
            expectEqual(Providers.descriptor(.codex).quotaKind, .percentWindow)
            expectEqual(Providers.descriptor(.claude).quotaKind, .percentWindow)
            expectEqual(Providers.descriptor(.trae).quotaKind, .credits)
            expectEqual(Providers.all.filter(\.isPercent).map(\.id), [.codex, .claude])
        }
        test("既有的 UserDefaults 键名保持不变") {
            expectEqual(Providers.descriptor(.qoder).menuBarDefaultsKey, "menuBar.qoder")
            expectEqual(Providers.descriptor(.workbuddy).menuBarDefaultsKey, "menuBar.workbuddy")
            expectEqual(Providers.descriptor(.codex).menuBarDefaultsKey, "menuBar.codex")
            expectEqual(Providers.descriptor(.claude).menuBarDefaultsKey, "menuBar.claude")
            expectEqual(Providers.descriptor(.trae).menuBarDefaultsKey, "menuBar.trae")
            expectEqual(Providers.descriptor(.qoder).reminderDefaultsKey, "reminder.qoder.claim")
            expectEqual(Providers.descriptor(.workbuddy).reminderDefaultsKey, "reminder.workbuddy.claim")
            expectEqual(Providers.descriptor(.codex).reminderDefaultsKey, "reminder.codex.reset")
            expectEqual(Providers.descriptor(.claude).reminderDefaultsKey, "reminder.claude.reset")
            expectEqual(Providers.descriptor(.trae).reminderDefaultsKey, "reminder.trae.claim")
        }
        test("新接入的 Claude Code 与 Trae 首次不进菜单栏，旧三家保持显示") {
            expectEqual(Providers.descriptor(.claude).defaultInMenuBar, false)
            expectEqual(Providers.descriptor(.trae).defaultInMenuBar, false)
            expectEqual(Providers.all.filter(\.defaultInMenuBar).map(\.id), [.qoder, .workbuddy, .codex])
        }
        test("刷新分组沿用旧的两档节奏与采集顺序") {
            let groups = Providers.groups
            expectEqual(groups.count, 3)
            // 60 秒一档里 Codex 的超时预算更大，所以仍然先起 Codex、再起 WorkBuddy。
            expectEqual(groups[0].interval, 60.0)
            expectEqual(groups[0].providers, [.codex, .workbuddy])
            expectEqual(groups[1].interval, 90.0)
            expectEqual(groups[1].providers, [UsageProvider.qoder])
            expectEqual(groups[2].interval, 120.0)
            expectEqual(groups[2].providers, [UsageProvider.claude, UsageProvider.trae])
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
                    expectEqual(grant, "100 额度")
                case .workbuddy:
                    expectEqual(hour, 0)
                    expectEqual(grant, "100 额度")
                case .codex:
                    check(false, "Codex 不该有每日领取提醒")
                case .claude:
                    check(false, "Claude Code 不该有每日领取提醒")
                case .trae:
                    expectEqual(hour, 0)
                    expectEqual(grant, "100 积分")
                }
            }
        }
        test("通知分类标识保持旧字符串") {
            expectEqual(NotificationCategory.forProvider(.qoder), "provider.qoder")
            expectEqual(NotificationCategory.forProvider(.workbuddy), "provider.workbuddy")
            expectEqual(NotificationCategory.forProvider(.codex), "provider.codex")
            expectEqual(NotificationCategory.forProvider(.claude), "provider.claude")
            expectEqual(NotificationCategory.forProvider(.trae), "provider.trae")
            expectEqual(NotificationCategory.openAction(for: .codex), "open.codex")
            expectEqual(NotificationCategory.all.count, Providers.ordered.count)
        }
    }

    // MARK: 卡片顺序与显示密度

    static func runCardOrder() {
        let base: [UsageProvider] = [.qoder, .workbuddy, .codex, .claude, .trae]
        test("没有存过顺序时用注册表顺序") {
            expectEqual(Providers.order(stored: []), base)
        }
        test("存过的顺序丢弃下架项并把新接入的排到末尾") {
            expectEqual(Providers.order(stored: ["trae", "qoder", "removed"]), [.trae, .qoder, .workbuddy, .codex, .claude])
        }
        test("往下拖落到目标的槽位") {
            expectEqual(Providers.moved(base, .qoder, onto: .claude), [.workbuddy, .codex, .qoder, .claude, .trae])
        }
        test("往上拖落到目标的槽位") {
            expectEqual(Providers.moved(base, .trae, onto: .workbuddy), [.qoder, .trae, .workbuddy, .codex, .claude])
        }
        test("拖给自己或不存在的位置不改顺序") {
            expectEqual(Providers.moved(base, .codex, onto: .codex), base)
            expectEqual(Providers.moved(base, .codex, onto: .claude).count, base.count)
        }
        test("上移下移越界停在两端") {
            expectEqual(Providers.shifted(base, .codex, by: -1), [.qoder, .codex, .workbuddy, .claude, .trae])
            expectEqual(Providers.shifted(base, .codex, by: 1), [.qoder, .workbuddy, .claude, .codex, .trae])
            expectEqual(Providers.shifted(base, .claude, by: -base.count).first, .claude)
            expectEqual(Providers.shifted(base, .workbuddy, by: base.count).last, .workbuddy)
            expectEqual(Providers.shifted(base, .codex, by: 0), base)
        }
        test("换位与移动后顺序始终是完整五家") {
            let moved = Providers.shifted(Providers.moved(base, .trae, onto: .qoder), .claude, by: 1)
            expectEqual(Set(moved).count, 5)
            expectEqual(moved.count, 5)
        }
        test("密度从旧的 simpleMode 布尔迁移") {
            expectEqual(PanelDensity.stored(raw: nil, legacySimple: true), .simple)
            expectEqual(PanelDensity.stored(raw: nil, legacySimple: false), .full)
            expectEqual(PanelDensity.stored(raw: nil, legacySimple: nil), .full)
            expectEqual(PanelDensity.stored(raw: "minimal", legacySimple: true), .minimal)
            expectEqual(PanelDensity.stored(raw: "bogus", legacySimple: true), .simple)
        }
        test("三档密度都有标题与说明") {
            expectEqual(PanelDensity.allCases.map(\.title), ["常规", "简单", "极简"])
            for density in PanelDensity.allCases {
                check(!density.help.isEmpty, "密度 \(density.title) 缺少说明")
            }
        }
        test("隐藏名单只认注册表里的供应商") {
            expectEqual(Providers.hidden(stored: ["trae", "removed"]), [.trae])
            expectEqual(Providers.hidden(stored: []).count, 0)
        }
        test("隐藏是从面板摘掉，顺序本身不动") {
            expectEqual(Providers.visible(base, hidden: [.qoder, .codex]), [.workbuddy, .claude, .trae])
            expectEqual(Providers.visible(base, hidden: Set(base)).count, 0)
        }
        test("重新显示回到原来的槽位") {
            var hidden = Providers.hidden(stored: ["codex"])
            expectEqual(Providers.visible(base, hidden: hidden), [.qoder, .workbuddy, .claude, .trae])
            hidden.remove(.codex)
            expectEqual(Providers.visible(base, hidden: hidden), base)
        }
        test("拖动过的顺序不受隐藏影响") {
            let dragged = Providers.moved(base, .trae, onto: .qoder)
            expectEqual(Providers.visible(dragged, hidden: [.claude]), [.trae, .qoder, .workbuddy, .codex])
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

    static func runMenuBar() {
        let credits = MenuBarMetric(
            letter: "Q",
            value: "1,870",
            compact: "1.9k",
            percent: "94%",
            today: "320",
            todayCompact: "320",
            fraction: 0.94,
            tint: Theme.qoder
        )
        let noToday = MenuBarMetric(
            letter: "C",
            value: "58%",
            compact: "58%",
            percent: "58%",
            today: nil,
            todayCompact: nil,
            fraction: 0.58,
            tint: Theme.codex
        )
        test("数字样式滚动到今日时加下降标识，没有今日数据的平台继续显示剩余") {
            expectEqual(MenuBarText.compose([credits, noToday], style: .classic, showsToday: false), "Q 1,870   C 58%")
            expectEqual(MenuBarText.compose([credits, noToday], style: .classic, showsToday: true), "Q ↓320    C 58%")
        }
        test("紧凑样式滚动时用缩写") {
            expectEqual(MenuBarText.compose([credits, noToday], style: .compact, showsToday: true), "Q↓320 C58%")
        }
        test("滚动两拍的整行宽度一致，菜单栏不会因切拍左右跳") {
            // 模拟菜单栏字体宽度：数字与逗号 6pt、箭头 10pt、空格 3pt。
            let widthOf: (String) -> CGFloat = { text in
                text.reduce(CGFloat(0)) { sum, ch in sum + (ch == "↓" ? 10 : ch == " " ? 3 : 6) }
            }
            let remaining = MenuBarText.compose([credits, noToday], style: .classic, showsToday: false, widthOf: widthOf)
            let today = MenuBarText.compose([credits, noToday], style: .classic, showsToday: true, widthOf: widthOf)
            // 补位空格落在字母与数值之间：`Q 1,870`(39pt) 和 `Q ↓320`(40pt) 各占同一格，
            // 差值只可能来自一个空格的取整，而不是原来 5pt 的整段位移。
            expectEqual(today, "Q ↓320    C 58%")
            check(abs(widthOf(today) - widthOf(remaining)) <= 3,
                  "两拍行宽相差 \(abs(widthOf(today) - widthOf(remaining)))pt，超过一个空格")
            // 差得多的时候左右各补一半：字母钉在组左端，数值居中，组宽仍等于「W 12,345」。
            let wide = MenuBarMetric(
                letter: "W",
                value: "12,345",
                compact: "12.3k",
                percent: "50%",
                today: "3",
                todayCompact: "3",
                fraction: 0.5,
                tint: Theme.qoder
            )
            expectEqual(
                MenuBarText.compose([wide], style: .classic, showsToday: true, widthOf: widthOf),
                "W" + String(repeating: " ", count: 4) + "↓3" + String(repeating: " ", count: 4)
            )
        }
        test("条形样式不参与滚动，仍是剩余比例") {
            expectEqual(MenuBarText.compose([credits, noToday], style: .bars, showsToday: true), "94% 58%")
        }
        test("kern 补零头后两拍实测宽度逐像素一致") {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: NSFont.Weight.semibold)
            func width(_ text: NSAttributedString) -> CGFloat { text.size().width }
            let wide = MenuBarMetric(
                letter: "W",
                value: "12,345",
                compact: "12.3k",
                percent: "50%",
                today: "3",
                todayCompact: "3",
                fraction: 0.5,
                tint: Theme.qoder
            )
            for style in [MenuBarStyle.classic, .compact] {
                let remaining = MenuBarText.compose([credits, wide, noToday], style: style, showsToday: false, font: font)
                let today = MenuBarText.compose([credits, wide, noToday], style: style, showsToday: true, font: font)
                let gap = abs(width(today) - width(remaining))
                check(gap < 0.05, "\(style) 两拍实测宽度相差 \(gap)pt，补零头没有补齐")
            }
        }
        test("全部平台算不出今日消耗时滚动不改变文案") {
            let metrics = [credits, noToday].map {
                MenuBarMetric(
                    letter: $0.letter,
                    value: $0.value,
                    compact: $0.compact,
                    percent: $0.percent,
                    today: nil,
                    todayCompact: nil,
                    fraction: $0.fraction,
                    tint: $0.tint
                )
            }
            expectEqual(MenuBarText.compose(metrics, style: .classic, showsToday: true), "Q 1,870   C 58%")
        }
        test("没有可见平台时显示占位文案") {
            expectEqual(MenuBarText.compose([], style: .classic, showsToday: true), "AI")
        }
        test("今日消耗不足 1% 保留小数，避免显示成 0%") {
            expectEqual(Format.percentDetailed(0.4), "0.4%")
            expectEqual(Format.percentDetailed(9.96), "10.0%")
            expectEqual(Format.percentDetailed(42), "42%")
            expectEqual(Format.percentDetailed(nil), "--")
        }
    }

    // MARK: 升级：安装包挑选、校验值解析与自动替换门槛

    static func runUpdate() {
        func remoteAsset(_ name: String, scheme: String = "https") -> UpdateRelease.Asset {
            UpdateRelease.Asset(
                name: name,
                url: URL(string: "\(scheme)://github.com/pumf/token_tool/releases/download/v9.9.9/\(name)")!
            )
        }
        let dmg = "TokenTool-9.9.9.dmg"
        let arm64DMG = "TokenTool-9.9.9-arm64.dmg"
        let x86DMG = "TokenTool-9.9.9-x86_64.dmg"
        let arm64ZIP = "TokenTool-9.9.9-arm64.zip"
        let release = UpdateRelease(
            version: "9.9.9",
            tag: "v9.9.9",
            pageURL: URL(string: "https://github.com/pumf/token_tool/releases/tag/v9.9.9")!,
            notes: "\(arm64ZIP) 的校验值 \(String(repeating: "c", count: 64))",
            assets: [dmg, arm64DMG, x86DMG, "TokenTool-9.9.9.zip", arm64ZIP].map { remoteAsset($0) },
            checksums: UpdateRelease.checksums(fromSHA256SUMS: """
                \(String(repeating: "a", count: 64))  \(dmg)
                \(String(repeating: "b", count: 64)) *\(arm64DMG)
                short \(arm64ZIP)
                """)
        )

        test("按当前芯片挑对应的 DMG") {
            expectEqual(release.installerURL(for: "arm64")?.lastPathComponent, arm64DMG)
            expectEqual(release.installerURL(for: "x86_64")?.lastPathComponent, x86DMG)
        }
        test("缺芯片专属包时退回通用包，而不是抓错另一颗芯片") {
            let legacy = UpdateRelease(version: "9.9.9", tag: "v9.9.9", pageURL: release.pageURL, notes: "",
                                       assets: [remoteAsset(dmg), remoteAsset(x86DMG), remoteAsset("TokenTool-9.9.9.zip")])
            expectEqual(legacy.installerURL(for: "arm64")?.lastPathComponent, dmg)
        }
        test("ZIP 与明文清单都不会被当成安装包") {
            let tricky = UpdateRelease(version: "9.9.9", tag: "v9.9.9", pageURL: release.pageURL, notes: "",
                                       assets: [remoteAsset("TokenTool-9.9.9.zip"), remoteAsset("SHA256SUMS")])
            expectNil(tricky.installerURL(for: "arm64"))
        }
        test("SHA256SUMS 键统一小写，兼容二进制标记与残行") {
            expectEqual(release.checksums.count, 2)
            expectEqual(release.checksum(for: arm64DMG), String(repeating: "b", count: 64))
            expectEqual(release.checksum(for: dmg.lowercased()), String(repeating: "a", count: 64))
            expectNil(release.checksum(for: "TokenTool-9.9.9.zip"))
        }
        test("没有 SHA256SUMS 时从发布说明里捞校验值") {
            expectEqual(release.checksum(for: arm64ZIP), String(repeating: "c", count: 64))
        }
        test("Release 页面的相对链接补全成 github.com，非 https 直接丢弃") {
            let html = """
                <a href="/pumf/token_tool/releases/download/v9.9.9/\(dmg)">\(dmg)</a>
                <a href="/pumf/token_tool/releases/download/v9.9.9/SHA256SUMS">SHA256SUMS</a>
                <a href="https://github.com/pumf/token_tool/releases/download/v9.9.9/\(arm64DMG)">\(arm64DMG)</a>
                <a href="http://example.com/releases/download/v9.9.9/TokenTool-9.9.9.dmg">明文下载</a>
                <a href="/pumf/token_tool/releases/expanded_assets/v9.9.9">本 releases 页面</a>
                """
            let parsed = UpdateRelease.assets(fromExpandedHTML: html, tag: "v9.9.9")
            // 清单本身也是 release 资产，会一起枚举到；挑安装包时只认 .dmg。
            expectEqual(parsed.map(\.name), [dmg, "SHA256SUMS", arm64DMG])
            check(parsed.allSatisfy { $0.url.scheme == "https" }, "解析出了非 https 的地址")
            check(parsed.allSatisfy { $0.url.host == "github.com" }, "相对链接没有补全成 github.com")
            expectEqual(
                UpdateRelease(version: "9.9.9", tag: "v9.9.9", pageURL: release.pageURL, notes: "", assets: parsed)
                    .installerURL(for: "arm64")?.lastPathComponent,
                arm64DMG
            )
        }
        test("只有已校验且跑在 /Applications 才自动替换") {
            let installed = URL(fileURLWithPath: "/Applications/TokenTool.app")
            check(UpdateInstaller.canInstall(bundleURL: installed, verified: true), "正式安装 + 已校验应允许自动替换")
            check(!UpdateInstaller.canInstall(bundleURL: installed, verified: false), "没有校验值不能自动替换")
            check(
                !UpdateInstaller.canInstall(
                    bundleURL: URL(fileURLWithPath: "/Users/dev/Project/token_tool/build/TokenTool.app"),
                    verified: true
                ),
                "开发实例不能覆盖自己的 build 目录"
            )
            check(
                !UpdateInstaller.canInstall(bundleURL: URL(fileURLWithPath: "/Applications/Other.app"), verified: true),
                "只认 TokenTool.app"
            )
        }
        test("版本号按数字段比较，补齐缺失的尾段") {
            check(UpdateVersion.isNewer("1.7.0", than: "1.6.9"), "1.7.0 应比 1.6.9 新")
            check(UpdateVersion.isNewer("1.10.0", than: "1.9.0"), "按字典序会误判 1.10 更旧")
            check(UpdateVersion.isNewer("1.7.1", than: "1.7"), "缺省尾段按 0 补齐")
            check(!UpdateVersion.isNewer("1.7", than: "1.7.0"), "1.7 与 1.7.0 视为同一个版本")
            check(!UpdateVersion.isNewer("v1.6.5", than: "1.6.5"), "同一个版本不算新版")
            check(!UpdateVersion.isNewer("1.6.5", than: "1.7.0"), "旧版本不算新版")
        }
    }

    // MARK: 诊断日志脱敏

    static func runDiagnostics() {
        test("凭据类关键词后面的值被打码") {
            check(Diagnostics.sanitize("qoder token: abcdef123456").contains("<redacted>"), "token 冒号形式没打码")
            check(Diagnostics.sanitize("refresh_token=abcdefghijklmnop").contains("<redacted>"), "等号形式没打码")
            check(Diagnostics.sanitize("authorization Bearer abcdef123456").contains("<redacted>"), "Bearer 头没打码")
            check(!Diagnostics.sanitize("authorization Bearer abcdef123456").contains("abcdef123456"), "Bearer 后面的凭据残留")
            check(Diagnostics.sanitize("WBIPC 返回 code: -32001").contains("<redacted>"), "错误码没打码")
            check(Diagnostics.sanitize("https://x.com/cb?code=abc12345&state=1").contains("<redacted>"), "查询参数没打码")
            check(!Diagnostics.sanitize("https://x.com/cb?code=abc12345&state=1").contains("abc12345"), "查询参数残留原文")
        }
        test("长随机串一律打码") {
            let leaked = Diagnostics.sanitize("异常输出 \(String(repeating: "K", count: 40)) 已丢弃")
            check(leaked.contains("<redacted>"), "40 位串没打码")
            check(!leaked.contains(String(repeating: "K", count: 40)), "长串残留原文")
        }
        test("中文文案与产品名不被误伤") {
            // 「Claude Code 数据不可用」这类句子必须原样留在日志里，否则排查时读不懂。
            let message = "Claude Code 数据不可用：Claude Code 按 API 计费，没有订阅额度窗口"
            expectEqual(Diagnostics.sanitize(message), message)
            let hotKey = "⌥⇧T 注册失败（-17368），组合键可能被其他应用占用"
            expectEqual(Diagnostics.sanitize(hotKey), hotKey)
            let http = "GitHub 返回 HTTP 403"
            expectEqual(Diagnostics.sanitize(http), http)
        }
        test("超长详情截断到 220 字以内") {
            check(Diagnostics.sanitize(String(repeating: "说", count: 400)).count <= 220, "详情没有截断")
        }
    }

    private static func data(_ text: String) -> Data {
        Data(text.utf8)
    }
}
