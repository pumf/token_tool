#!/usr/bin/env python3
"""collector.py 解析层的回归测试：只喂固定文本，不启动任何 CLI 或 IPC。

采集器的取值口径都在纯函数里（strip_ansi / number / parse_qoder / window_payload /
claude_*），真机通道一旦改动这些函数就会先错，所以这里用固定 fixture 覆盖。
运行方式：python3 Tests/CollectorTests.py（test.sh 会带上）。
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import collector  # noqa: E402

failures = 0
checks = 0


def check(condition, message):
    global failures, checks
    checks += 1
    if not condition:
        failures += 1
        print(f"  ✗ {message}")
    return condition


def expect_equal(actual, expected, message):
    check(actual == expected, f"{message}：期望 {expected!r}，实际 {actual!r}")


def expect_close(actual, expected, message, accuracy=0.01):
    check(
        isinstance(actual, (int, float)) and abs(actual - expected) <= accuracy,
        f"{message}：期望 {expected}±{accuracy}，实际 {actual!r}",
    )


# 固定「现在」：当天 12:00（本地时区），重置时间断言只验证相对关系与钟点。
LOCAL_NOON = time.mktime(time.localtime()[:3] + (12, 0, 0, 0, 0, -1))


def local_moment(epoch):
    return time.localtime(epoch)


# ---------------------------------------------------------------- 基础换算


def test_number_and_ansi():
    expect_equal(collector.number("2,600"), 2600.0, "千分位")
    expect_equal(collector.number(None, default=7.0), 7.0, "空值走默认")
    expect_equal(collector.number("abc", default=-1.0), -1.0, "非数字走默认")
    expect_equal(collector.strip_ansi("\x1b]0;title\x07a\r\nb"), "a\n\nb", "OSC 与回车换行")
    expect_equal(collector.strip_ansi("\x1b[1m粗体\x1b[0m"), "粗体", "SGR 颜色码")


# ---------------------------------------------------------------- Qoder /usage


def test_qoder_plan_and_addon():
    text = (
        "\x1b[1mQoderCNPlan: Pro\x1b[0m\n"
        "PlanExpiresAt: 2026-12-01\n"
        "PlanCreditsUsed: 400/2,600\n"
        "Add-onCreditsUsed: 50/400\n"
        "OrgResourcePackage: 剩余 1,800 / 2,000\n"
        "TotalDuration(API): 12s\n"
    )
    payload = collector.parse_qoder(text)
    check(payload is not None, "Qoder /usage 没有解析出额度")
    if not payload:
        return
    expect_equal(payload["plan"], "Pro", "套餐名")
    expect_equal(payload["planExpiresAt"], "2026-12-01", "到期日")
    expect_equal(payload["planUsed"], 400.0, "套餐已用")
    expect_equal(payload["planTotal"], 2600.0, "套餐总量")
    expect_equal(payload["addonUsed"], 50.0, "加包已用")
    expect_equal(payload["total"], 3000.0, "总量是套餐加加包")
    expect_equal(payload["remaining"], 2550.0, "剩余按两包合计")
    expect_equal(payload["usedPercent"], 15.0, "已用百分比")
    expect_equal(payload["orgResourcePackage"], "剩余1,800/2,000", "组织资源包原样带出")


def test_qoder_variants():
    addon_only = collector.parse_qoder("Plan: Teams\nAdd-onCreditsUsed: 30/100\n")
    check(addon_only is not None, "只有加包时应当仍可解析")
    if addon_only:
        expect_equal(addon_only["total"], 100.0, "只有加包时总量")
        expect_equal(addon_only["usedPercent"], 30.0, "只有加包时已用")
        expect_equal(addon_only["planExpiresAt"], "N/A", "缺到期日回退 N/A")

    no_numbers = collector.parse_qoder("QoderCNPlan: Pro\nPlanExpiresAt: 2026-12-01\n")
    check(no_numbers is None, "没有任何额度数字时不应编造结果")

    legacy = collector.parse_qoder("Plan: Community\nPlanCreditsUsed: 10/100\n")
    check(legacy is not None and legacy["plan"] == "Community", "旧版 Plan: 字段应当兼容")


# ---------------------------------------------------------------- Codex 窗口


def test_codex_window_payload():
    window = collector.window_payload("w5h", {"windowDurationMins": 300, "usedPercent": 42.5, "resetsAt": 1_700_000_000})
    check(window is not None, "窗口结构没有解析出来")
    if window:
        expect_equal(window["windowMinutes"], 300, "窗口时长")
        expect_equal(window["usedPercent"], 42.5, "已用比例")
        expect_equal(window["remainingPercent"], 57.5, "剩余比例")
        expect_equal(window["resetsAt"], 1_700_000_000, "重置时间")

    clamped = collector.window_payload("w7d", {"windowDurationMins": 10080, "usedPercent": 140})
    check(clamped is not None, "越界比例仍应给出窗口")
    if clamped:
        expect_equal(clamped["usedPercent"], 100.0, "已用比例被夹回 100")
        expect_equal(clamped["remainingPercent"], 0.0, "剩余比例跟着夹到 0")
        expect_equal(clamped["resetsAt"], None, "缺 resetsAt 时按未知处理")

    expect_equal(collector.window_payload("w", None), None, "非字典输入返回 None")
    blank = collector.window_payload("w", {})
    check(blank is not None, "字段缺失时仍给出窗口结构，交给上层判断")
    if blank:
        expect_equal(blank["windowMinutes"], 0, "缺时长记 0")
        expect_equal(blank["usedPercent"], 0.0, "缺比例记 0")
        expect_equal(blank["resetsAt"], None, "缺重置时间记 None")


# ---------------------------------------------------------------- Claude /usage


def test_claude_windows():
    text = (
        "Current session: 18% used · resets 3:00 PM\n"
        "Current week (all models): 55% used · resets Mon\n"
    )
    windows = collector.claude_usage_windows(text, now=LOCAL_NOON)
    expect_equal(len(windows), 2, "会话窗口与周窗口各一条")
    if len(windows) == 2:
        expect_equal(windows[0]["id"], "session", "第一条是会话窗口")
        expect_equal(windows[0]["windowMinutes"], 300, "会话窗口 5 小时")
        expect_equal(windows[0]["usedPercent"], 18.0, "会话窗口已用")
        expect_equal(windows[0]["remainingPercent"], 82.0, "会话窗口剩余")
        expect_equal(windows[1]["id"], "week", "第二条是周窗口")
        expect_equal(windows[1]["windowMinutes"], 10080, "周窗口 7 天")
        expect_equal(windows[1]["usedPercent"], 55.0, "周窗口已用")

    reset = local_moment(windows[0]["resetsAt"]) if windows and windows[0]["resetsAt"] else None
    check(reset is not None and reset.tm_hour == 15, "3:00 PM 换算成当天或次日 15 点")
    if reset:
        check(windows[0]["resetsAt"] > LOCAL_NOON, "重置时间必须在未来")
        check(windows[0]["resetsAt"] <= LOCAL_NOON + 86400, "钟点式重置不超过 24 小时")

    week_reset = local_moment(windows[1]["resetsAt"]) if len(windows) == 2 and windows[1]["resetsAt"] else None
    check(week_reset is not None and week_reset.tm_wday == 0, "Mon 换算到下一个周一")
    if week_reset:
        check(week_reset.tm_hour == 0, "周一重置取零点")
        check(0 < windows[1]["resetsAt"] - LOCAL_NOON <= 7 * 86400, "周一重置落在一周之内")


def test_claude_percent_and_reset():
    expect_equal(collector.claude_percent("Current session: 12% used"), 12.0, "已用写法")
    expect_equal(collector.claude_percent("Current session: 40% left"), 60.0, "剩余写法换算成已用")
    expect_equal(collector.claude_percent("Current week: 25% remaining"), 75.0, "remaining 写法")
    expect_equal(collector.claude_percent("Current session: 140% used"), 100.0, "越界夹回 100")
    expect_equal(collector.claude_percent("no percent here"), None, "没有百分比时返回 None")
    expect_equal(collector.claude_percent(None), None, "空行返回 None")

    relative = collector.claude_reset_epoch("Current session: 9% used · resets in 2h 15m", now=LOCAL_NOON)
    expect_equal(relative, int(LOCAL_NOON + 2 * 3600 + 15 * 60), "相对时长按秒累加")

    midnight = collector.claude_reset_epoch("Current session: 9% used · resets 12:00 AM", now=LOCAL_NOON)
    check(midnight is not None and local_moment(midnight).tm_hour == 0, "12:00 AM 是零点而不是中午")

    expect_equal(collector.claude_reset_epoch("Current session: 9% used", now=LOCAL_NOON), None, "没有 resets 文案时返回 None")
    expect_equal(collector.claude_reset_epoch("resets soon", now=LOCAL_NOON), None, "认不出的重置文案返回 None")


def test_claude_api_billed():
    # 走 API/中继计费时 /usage 只有本次会话花费，不能凭空造出窗口。
    text = "Current session cost: $0.02\nTotal cost: $1.34\n"
    expect_equal(collector.claude_usage_windows(text, now=LOCAL_NOON), [], "API 计费文本不产生窗口")
    expect_equal(collector.claude_usage_windows("", now=LOCAL_NOON), [], "空结果不产生窗口")
    expect_equal(collector.claude_json("not json"), {}, "非 JSON 输出回退空字典")
    expect_equal(collector.claude_json("[1,2]"), {}, "JSON 数组不是字典时回退空字典")
    expect_equal(collector.claude_json('{"loggedIn": true}'), {"loggedIn": True}, "登录状态正常读出")


def test_claude_registry():
    expect_equal(sorted(collector.COLLECTORS), ["claude", "codex", "qoder", "workbuddy"], "采集器注册表四家")
    expect_equal(collector.GROUPS["fast"], ("codex", "workbuddy"), "fast 分组仍是本地 IPC 两家")
    check("claude" not in collector.GROUPS, "Claude 单独一档，不进 fast 分组")
    expect_equal(collector.CLAUDE_WINDOWS[0][1], 300, "会话窗口分钟数与 Swift 侧一致")
    expect_equal(collector.CLAUDE_WINDOWS[1][1], 10080, "周窗口分钟数与 Swift 侧一致")


def main():
    for name, body in sorted(globals().items()):
        if name.startswith("test_") and callable(body):
            before = failures
            body()
            print(f"{'✓' if failures == before else '✗'} {name[len('test_'):]}")
    print(f"\n{checks} 项断言，{failures} 项失败")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
