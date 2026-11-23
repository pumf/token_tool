#!/usr/bin/env python3
"""collector.py 解析层的回归测试：只喂固定文本，不启动任何 CLI 或 IPC。

采集器的取值口径都在纯函数里（strip_ansi / number / parse_qoder / window_payload /
claude_*），真机通道一旦改动这些函数就会先错，所以这里用固定 fixture 覆盖。
运行方式：python3 Tests/CollectorTests.py（test.sh 会带上）。
"""

from __future__ import annotations

import os
import sys
import tempfile
import time
from datetime import datetime, timedelta
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
    expect_equal(payload["usedScope"], "cumulative", "Qoder 的 used 是累计口径，不是今日消耗")


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
    expect_equal(
        sorted(collector.COLLECTORS),
        ["claude", "codex", "qoder", "trae", "workbuddy"],
        "采集器注册表五家",
    )
    expect_equal(collector.GROUPS["fast"], ("codex", "workbuddy"), "fast 分组仍是本地 IPC 两家")
    check("claude" not in collector.GROUPS, "Claude 单独一档，不进 fast 分组")
    check("trae" not in collector.GROUPS, "Trae 单独一档，不进 fast 分组")
    expect_equal(collector.CLAUDE_WINDOWS[0][1], 300, "会话窗口分钟数与 Swift 侧一致")
    expect_equal(collector.CLAUDE_WINDOWS[1][1], 10080, "周窗口分钟数与 Swift 侧一致")


# ---------------------------------------------------------------- Trae 日志


def trae_line(remaining, stamp="2026-11-11T14:48:42.529+08:00", level="info"):
    return (
        f"{stamp} [{level}] [ICubeUsageService] credits mutation refresh completed "
        f'{{"generation":1,"remaining":{remaining}}}\n'
    )


def write_trae_log(root, session, window, content, mtime=None):
    path = Path(root) / session / window / "renderer.log"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


def test_trae_credit_line():
    epoch = collector.trae_stamp_epoch("2026-11-11T14:48:42.529+08:00")
    expect_equal(
        collector.trae_latest_credit("噪音行\n" + trae_line(1200)),
        (epoch, 1200.0),
        "积分行读出余额与时刻",
    )
    text = trae_line(1200) + trae_line(1180, stamp="2026-11-11T15:02:07.001+08:00")
    latest = collector.trae_latest_credit(text)
    expect_equal(latest[1], 1180.0, "多条积分行取最后一条")
    check(latest[0] > epoch, "最后一条的时刻更新")
    expect_equal(
        collector.trae_latest_credit(trae_line(1200, level="warning")),
        (epoch, 1200.0),
        "日志级别变化不影响解析",
    )
    expect_equal(collector.trae_latest_credit("[info] 没有积分记录\n"), None, "无积分行返回空")
    expect_equal(
        collector.trae_latest_credit("credits mutation refresh completed {\"remaining\":1200}"),
        None,
        "缺时间戳的行不认，避免造出假时刻",
    )
    expect_equal(
        collector.trae_latest_credit(trae_line(1200, stamp="2026-13-45T99:99:99+08:00"))[1],
        1200.0,
        "时间戳非法时余额仍能读出",
    )
    check(collector.trae_stamp_epoch("2026-13-45T99:99:99+08:00") is None, "非法时间戳换算为空")


def test_trae_log_files():
    with tempfile.TemporaryDirectory() as root:
        newer = write_trae_log(root, "20261111T150000", "window4", "x\n", mtime=2000)
        older = write_trae_log(root, "20261111T144722", "window1", "x\n", mtime=1000)
        stray = Path(root) / "20261111T144722" / "window1" / "other.log"
        stray.write_text("x\n", encoding="utf-8")
        expect_equal(
            collector.trae_log_files(root),
            [newer, older],
            "候选日志按修改时间从新到旧，且只认 renderer.log",
        )
        expect_equal(collector.trae_log_files(Path(root) / "不存在"), [], "日志目录缺失时返回空")


def test_trae_scan_file():
    with tempfile.TemporaryDirectory() as root:
        # 积分行在开头、后面塞满 2MB 以上的噪音，尾部窗口读不到，只能靠整扫兜底。
        path = write_trae_log(root, "s", "window1", trae_line(1200))
        with path.open("a", encoding="utf-8") as handle:
            handle.write("[info] filler\n" * 400000)
        check(
            path.stat().st_size > collector.TRAE_LOG_TAIL_BYTES,
            "夹具确实比尾部窗口大",
        )
        expect_equal(
            collector.trae_scan_file(path)[1],
            1200.0,
            "尾部读不到时整扫兜底",
        )
        expect_equal(collector.trae_scan_file(path.parent / "missing.log"), None, "文件缺失不抛异常")


def test_collect_trae():
    original = collector.TRAE_LOG_ROOTS
    try:
        with tempfile.TemporaryDirectory() as root:
            collector.TRAE_LOG_ROOTS = [Path(root)]
            expect_equal(collector.collect_trae()["ok"], False, "没有日志目录时失败")
            check("Trae" in collector.collect_trae()["error"], "失败原因是中文提示")

            write_trae_log(root, "s", "window1", "[info] 还没有积分记录\n")
            result = collector.collect_trae()
            expect_equal(result["ok"], False, "日志里没有积分行时失败")
            check("额度面板" in result["error"], "提示用户去客户端打开一次面板")

            # 同一条积分行既出现在 window1 也出现在更新的 window4，取更新那份的值。
            write_trae_log(
                root, "s", "window1", trae_line(1200), mtime=1000
            )
            write_trae_log(
                root, "s", "window4", trae_line(1180, stamp="2026-11-11T15:02:07.001+08:00"), mtime=2000
            )
            result = collector.collect_trae()
            expect_equal(result["ok"], True, "读到积分余额")
            expect_equal(result["remaining"], 1180.0, "余额取最新日志")
            expect_equal(result["unit"], "credits", "口径是积分")
            expect_equal(result["source"], "trae-log", "来源标注为客户端日志")
            expect_equal(
                result["updatedAt"],
                collector.trae_stamp_epoch("2026-11-11T15:02:07.001+08:00"),
                "时间戳用日志时刻而不是采集时刻",
            )
            check("total" not in result, "Trae 没有总额度，不能凭空造 total")

            # 最新一份日志里余额是负数（脏数据），退回上一份有效记录而不是直接失败。
            write_trae_log(root, "s2", "window9", trae_line(-1), mtime=3000)
            expect_equal(collector.collect_trae()["remaining"], 1180.0, "脏数据退回上一份有效记录")

        with tempfile.TemporaryDirectory() as root:
            collector.TRAE_LOG_ROOTS = [Path(root)]
            write_trae_log(root, "s", "window1", trae_line(-1))
            expect_equal(collector.collect_trae()["ok"], False, "只有负数余额时不采信")
    finally:
        collector.TRAE_LOG_ROOTS = original


def trae_stamp(hours_ago):
    moment = datetime.now().astimezone() - timedelta(hours=hours_ago)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.000%z")


def test_collect_trae_stale():
    original = collector.TRAE_LOG_ROOTS
    try:
        with tempfile.TemporaryDirectory() as root:
            collector.TRAE_LOG_ROOTS = [Path(root)]
            # 客户端 7 小时没再写积分行：余额按「可能过期」上报，采集时刻单独给一份。
            write_trae_log(root, "s", "window1", trae_line(1200, stamp=trae_stamp(7)), mtime=1000)
            result = collector.collect_trae()
            expect_equal(result["stale"], True, "超过 6 小时没动的余额标记可能过期")
            expect_equal(result["remaining"], 1200.0, "过期标记不改变余额取值")
            check(isinstance(result["collectedAt"], int), "collectedAt 是本次采集时刻")
            check(
                result["collectedAt"] - result["updatedAt"] > 6 * 3600,
                "updatedAt 仍是日志时刻，与采集时刻拉开差距",
            )

            # 半小时前刚写过的积分行：照常当新鲜数据处理。
            write_trae_log(root, "s2", "window1", trae_line(1180, stamp=trae_stamp(0.5)), mtime=time.time())
            result = collector.collect_trae()
            expect_equal(result["stale"], False, "刚动过的余额不标过期")
            expect_equal(result["remaining"], 1180.0, "余额取最新日志")
    finally:
        collector.TRAE_LOG_ROOTS = original


def test_trae_cdp_parse():
    """CDP 实时采集的纯解析层：数字清洗、结构/文本/DOM 三路找余额。"""
    expect_equal(collector.trae_cdp_number("4,671.37"), 4671.37, "带千分位的字符串余额")
    expect_equal(collector.trae_cdp_number(-5), None, "负数不是有效余额")
    expect_equal(collector.trae_cdp_number(True), None, "布尔值不当作余额")
    expect_equal(collector.trae_cdp_number(99_999_999), None, "离谱量级不采信")

    payload = {"data": {"usage": [{"remainingCredits": "4,671.37", "total": 5000}]}}
    expect_equal(collector.trae_remaining_from_json(payload), 4671.37, "嵌套结构里找到 remaining 键")
    expect_equal(collector.trae_remaining_from_json({"foo": "bar"}), None, "无关结构返回空")

    expect_equal(
        collector.trae_remaining_from_text('{"x":1,"balance":"3,200"}'),
        3200.0,
        "非 JSON 文本里正则扫 balance",
    )
    expect_equal(collector.trae_remaining_from_text("no numbers here"), None, "无余额字样的文本返回空")

    expect_equal(collector.trae_remaining_from_dom(["4,671.37 / 5,000.00"]), 4671.37, "X / Y 取左侧余额")
    expect_equal(collector.trae_remaining_from_dom(["剩余积分", "4,671.37"]), 4671.37, "积分行内取数")
    expect_equal(collector.trae_remaining_from_dom(["4,600", "113"]), 4600.0, "裸数字取最大")
    expect_equal(collector.trae_remaining_from_dom(["无数字"]), None, "没有数字返回空")

    probe = {"global": {"workspace": '{"activeAIPanel":{"remaining":4600}}'}, "dom": ["999"]}
    expect_equal(collector.trae_remaining_from_probe(probe), 4600.0, "全局对象优先于 DOM 文本")
    expect_equal(collector.trae_remaining_from_probe({"dom": ["2,000 / 3,000"]}), 2000.0, "全局为空时退回 DOM")
    expect_equal(collector.trae_remaining_from_probe(None), None, "探测结果缺失不抛错")

    # 顶栏积分控件是最可信的 DOM 来源，优先于整页文本；整页兜底仍受 1M 上限闸约束
    expect_equal(
        collector.trae_remaining_from_probe({"widget": ["5,019"], "dom": ["7,329,783"]}),
        5019.0,
        "积分控件优先于整页文本",
    )
    expect_equal(
        collector.trae_remaining_from_probe({"dom": ["900,000", "5,019"]}),
        900000.0,
        "无控件时整页兜底仍按最大数",
    )

    # 自污染回环防线：Trae 内置 AI 聊天面板的文本也在页面里，「余额/剩余」
    # 泛词行 + 行内取最大数会把对话里提到的数字当成余额（实测抓走过 7,329,783）。
    expect_equal(collector.trae_remaining_from_dom(["余额 7,329,783"]), None, "「余额」泛词行不采信")
    expect_equal(collector.trae_remaining_from_dom(["剩余 5001 跳到 7,329,783"]), None, "「剩余」泛词行不采信")
    expect_equal(collector.trae_remaining_from_dom(["积分 1,200"]), 1200.0, "「积分」行仍采信")
    expect_equal(collector.trae_remaining_from_dom(["credits left: 4,671.37"]), 4671.37, "credits 行仍采信")
    expect_equal(collector.trae_remaining_from_json({"remaining_tokens": 7329783}), None, "remaining_tokens 键拒绝")
    expect_equal(collector.trae_remaining_from_json({"remaining_chars": 99999}), None, "remaining_chars 键拒绝")
    expect_equal(collector.trae_remaining_from_json({"remainingCredits": 5066}), 5066.0, "remainingCredits 复合键放行")
    expect_equal(collector.trae_remaining_from_json({"remaining": 5066}), 5066.0, "remaining 键放行")

    summary = collector.trae_usage_from_summary(
        {"usage_summary": {"total_amount": 1200, "consumed_amount": 134}}
    )
    expect_equal(summary["remaining"], 1066.0, "usage_summary 结构化解析")
    expect_equal(summary["total"], 1200.0, "结构化解析带回 total")
    expect_equal(summary["consumed"], 134.0, "结构化解析带回 consumed")
    expect_equal(collector.trae_usage_from_summary({"usage_summary": {}}), None, "空 summary 返回空")
    expect_equal(collector.trae_usage_from_summary({"other": 1}), None, "无 summary 返回空")


def test_trae_jwt_roundtrip():
    """JWT 抓取落盘：0600 权限、原子写、内容不变不重写。"""
    original = collector.TRAE_JWT_TOKEN_PATHS
    try:
        with tempfile.TemporaryDirectory() as tmp:
            collector.TRAE_JWT_TOKEN_PATHS = [Path(tmp) / "trae-jwt-token"]
            collector.trae_save_jwt("eyJaa.aaa.aaa" + "x" * 40)
            path = collector.TRAE_JWT_TOKEN_PATHS[0]
            expect_equal(collector.trae_read_jwt(), "eyJaa.aaa.aaa" + "x" * 40, "JWT 落盘后能读回")
            expect_equal(oct(path.stat().st_mode & 0o777), oct(0o600), "JWT 文件权限 0600")
            collector.trae_save_jwt("eyJaa.aaa.aaa" + "x" * 40)
            expect_equal(path.read_text().strip(), "eyJaa.aaa.aaa" + "x" * 40, "内容不变不重写")
    finally:
        collector.TRAE_JWT_TOKEN_PATHS = original


def test_provider_lock_and_transient_fail():
    # 跳过型失败带 transient 标记，普通失败不带；应用靠它区分「让位」与真错误。
    plain = collector.fail("普通失败")
    check("transient" not in plain, "普通失败不带 transient 标记")
    skipped = collector.fail("上一轮采集仍在进行，本轮跳过", transient=True)
    check(skipped.get("transient") is True, "跳过型失败带 transient 标记")
    check(skipped["ok"] is False, "跳过型失败 ok 仍为 False")

    # 每 provider 一把锁：同名互斥、异名并行，锁文件按 provider 命名。
    original = collector.APP_SUPPORT
    with tempfile.TemporaryDirectory() as tmp:
        collector.APP_SUPPORT = Path(tmp)
        try:
            first = collector.acquire_collection_lock("trae", wait_seconds=0.1)
            check(first is not None, "同名第一把锁能拿到")
            check((Path(tmp) / "collector-trae.lock").exists(), "锁文件按 provider 命名")
            second = collector.acquire_collection_lock("trae", wait_seconds=0.1)
            check(second is None, "同名第二把锁让位返回 None")
            other = collector.acquire_collection_lock("workbuddy", wait_seconds=0.1)
            check(other is not None, "不同名互不影响")
            check((Path(tmp) / "collector-workbuddy.lock").exists(), "第二家锁文件独立")
            for fd in (first, other):
                if fd is not None:
                    os.close(fd)
        finally:
            collector.APP_SUPPORT = original


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
