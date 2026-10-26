#!/usr/bin/env python3
"""Collect local usage for Codex, WorkBuddy and Qoder without touching credentials."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import pty
import queue
import re
import secrets
import select
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HOME = Path.home()
APP_SUPPORT = HOME / "Library" / "Application Support" / "TokenTool"
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
OSC_RE = re.compile(r"\x1b\][^\x07]*(?:\x07|\x1b\\)")


def fail(message: str) -> dict:
    return {"ok": False, "error": str(message)[:400], "updatedAt": int(time.time())}


def number(value, default=0.0) -> float:
    try:
        return float(str(value).replace(",", ""))
    except (TypeError, ValueError):
        return default


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", OSC_RE.sub("", text)).replace("\r", "\n")


# ---------------------------------------------------------------- Codex

def codex_binary():
    candidates = [
        Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"),
        Path("/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex"),
        HOME / ".codex" / "bin" / "codex",
    ]
    for path in candidates:
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    found = shutil.which("codex")
    return found


def proxy_url():
    for key in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"):
        value = os.environ.get(key)
        if value:
            return value
    try:
        raw = subprocess.run(
            ["/usr/sbin/scutil", "--proxy"], capture_output=True, text=True, timeout=5
        ).stdout
        values = {}
        for line in raw.splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                values[key.strip()] = value.strip()
        if values.get("HTTPSEnable") == "1" and values.get("HTTPSProxy"):
            return "http://%s:%s" % (values["HTTPSProxy"], values.get("HTTPSPort") or "443")
        if values.get("HTTPEnable") == "1" and values.get("HTTPProxy"):
            return "http://%s:%s" % (values["HTTPProxy"], values.get("HTTPPort") or "80")
    except Exception:
        pass
    return None


def window_payload(name, raw):
    if not isinstance(raw, dict):
        return None
    minutes = int(number(raw.get("windowDurationMins")))
    used = max(0.0, min(100.0, number(raw.get("usedPercent"))))
    resets = int(number(raw.get("resetsAt"))) or None
    return {
        "id": name,
        "windowMinutes": minutes,
        "usedPercent": round(used, 2),
        "remainingPercent": round(100.0 - used, 2),
        "resetsAt": resets,
    }


def collect_codex() -> dict:
    binary = codex_binary()
    if not binary:
        return fail("未找到 Codex CLI，请先安装并登录 ChatGPT 应用")
    env = dict(os.environ)
    proxy = proxy_url()
    if proxy:
        for key in ("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"):
            env[key] = proxy
    env["RUST_LOG"] = "error"
    proc = None
    try:
        proc = subprocess.Popen(
            [binary, "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
        messages: queue.Queue = queue.Queue()

        def pump(stream):
            try:
                for line in stream:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        messages.put(json.loads(line))
                    except Exception:
                        continue
            except Exception:
                pass

        threading.Thread(target=pump, args=(proc.stdout,), daemon=True).start()
        threading.Thread(target=pump, args=(proc.stderr,), daemon=True).start()

        def send(payload):
            proc.stdin.write(json.dumps(payload) + "\n")
            proc.stdin.flush()

        def wait_for(request_id, timeout):
            deadline = time.time() + timeout
            while time.time() < deadline:
                try:
                    message = messages.get(timeout=min(0.5, max(0.01, deadline - time.time())))
                except queue.Empty:
                    continue
                if message.get("id") == request_id:
                    return message
            return None

        def unwrap(message):
            if not message:
                raise RuntimeError("Codex 响应超时")
            if message.get("error"):
                detail = message["error"].get("message") or "未知错误"
                raise RuntimeError("Codex: " + str(detail))
            return message.get("result") or {}

        send({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"clientInfo": {"name": "token-tool", "version": "1.0"}},
        })
        unwrap(wait_for(1, 15))
        send({"jsonrpc": "2.0", "method": "initialized"})

        send({"jsonrpc": "2.0", "id": 2, "method": "account/read", "params": {}})
        account_result = unwrap(wait_for(2, 20))
        account = account_result.get("account") or {}

        send({
            "jsonrpc": "2.0", "id": 3, "method": "account/rateLimits/read",
            "params": {"excludeResetCreditDetails": True},
        })
        limits_result = unwrap(wait_for(3, 35))
        limits = limits_result.get("rateLimits") or {}
        limits_by_id = limits_result.get("rateLimitsByLimitId") or {}
        if not limits and isinstance(limits_by_id, dict) and limits_by_id:
            limits = next(iter(limits_by_id.values()))

        windows = []
        for name in ("primary", "secondary"):
            item = window_payload(name, limits.get(name))
            if item:
                windows.append(item)
        credits = limits.get("credits") or {}
        reset_credits = limits_result.get("rateLimitResetCredits") or {}
        balance = credits.get("balance")
        if balance is not None:
            try:
                balance = round(float(balance), 2)
            except (TypeError, ValueError):
                balance = None

        return {
            "ok": True,
            "plan": limits.get("planType") or account.get("planType") or "unknown",
            "accountType": account.get("type") or "unknown",
            "windows": windows,
            "credits": {
                "hasCredits": bool(credits.get("hasCredits")),
                "unlimited": bool(credits.get("unlimited")),
                "balance": balance,
            },
            "resetCredits": int(number(reset_credits.get("availableCount"))),
            "limitId": limits.get("limitId") or "codex",
            "updatedAt": int(time.time()),
        }
    except Exception as exc:
        return fail(exc)
    finally:
        if proc is not None:
            try:
                proc.terminate()
                proc.wait(timeout=3)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass


# ------------------------------------------------------------ WorkBuddy

def workbuddy_discovery():
    root = Path(os.environ.get("WORKBUDDY_CONFIG_DIR") or (HOME / ".workbuddy"))
    path = root / "wbipc" / "endpoint.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise RuntimeError("WorkBuddy 未运行（缺少本机 IPC 端点）")
    except Exception:
        raise RuntimeError("WorkBuddy IPC 端点信息无法读取")
    endpoint = str(data.get("endpoint") or "").strip()
    ticket = str(data.get("ticket") or "").strip()
    if not endpoint or not ticket:
        raise RuntimeError("WorkBuddy IPC 端点信息不完整")
    return endpoint, ticket


def wb_proof(ticket, role, protocol, endpoint, client_nonce, server_nonce):
    domain = "wbipc-s" if role == "server" else "wbipc-c"
    chunks = []
    for part in (domain, str(protocol), endpoint, client_nonce, server_nonce):
        raw = part.encode("utf-8")
        chunks.append(len(raw).to_bytes(4, "big") + raw)
    digest = hmac.new(ticket.encode("utf-8"), b"".join(chunks), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def wb_read_frame(sock, buffer):
    while b"\n" not in buffer:
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("WorkBuddy IPC 连接已关闭")
        buffer += chunk
        if len(buffer) > 1024 * 1024:
            raise RuntimeError("WorkBuddy IPC 数据过大")
    line, buffer = buffer.split(b"\n", 1)
    line = line.strip()
    if not line:
        return {}, buffer
    return json.loads(line.decode("utf-8")), buffer


def wb_send(sock, payload):
    sock.sendall((json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8"))


def wb_rpc(sock, buffer, request_id, method, params):
    wb_send(sock, {
        "jsonrpc": "2.0", "id": request_id, "method": method,
        "params": params, "mode": "call",
    })
    while True:
        frame, buffer = wb_read_frame(sock, buffer)
        if frame.get("id") != request_id:
            continue
        if frame.get("error"):
            error = frame["error"]
            raise RuntimeError(str(error.get("message") or error.get("code") or "WorkBuddy IPC 调用失败"))
        return frame.get("result") or {}, buffer


def wb_connect():
    endpoint, ticket = workbuddy_discovery()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(8)
    try:
        sock.connect(endpoint)
    except Exception:
        sock.close()
        raise RuntimeError("无法连接 WorkBuddy（请确认客户端正在运行）")
    try:
        protocol = 1
        client_nonce = base64.urlsafe_b64encode(secrets.token_bytes(16)).rstrip(b"=").decode("ascii")
        ticket_id = hashlib.sha256(ticket.encode("utf-8")).hexdigest()[:16]
        wb_send(sock, {
            "type": "session_hello",
            "protocol_min": protocol,
            "protocol_max": protocol,
            "client_nonce": client_nonce,
            "ticket_id": ticket_id,
            "client": {"kind": "skill", "id": "token-tool"},
        })
        buffer = b""
        challenge, buffer = wb_read_frame(sock, buffer)
        if challenge.get("type") == "session_hello_error":
            raise RuntimeError("WorkBuddy IPC 握手被拒绝")
        if challenge.get("type") != "session_challenge":
            raise RuntimeError("WorkBuddy IPC 握手响应异常")
        server_nonce = str(challenge.get("server_nonce") or "")
        expected = wb_proof(ticket, "server", protocol, endpoint, client_nonce, server_nonce)
        if not server_nonce or not hmac.compare_digest(expected, str(challenge.get("server_proof") or "")):
            raise RuntimeError("WorkBuddy IPC 端点校验失败")
        wb_send(sock, {
            "type": "session_prove",
            "client_proof": wb_proof(ticket, "client", protocol, endpoint, client_nonce, server_nonce),
        })
        ack, buffer = wb_read_frame(sock, buffer)
        if ack.get("type") != "session_hello_ack":
            raise RuntimeError("WorkBuddy IPC 授权失败")
        return sock, buffer, ack
    except Exception:
        sock.close()
        raise


def collect_workbuddy() -> dict:
    sock = None
    try:
        sock, buffer, ack = wb_connect()
        pipe_result, buffer = wb_rpc(sock, buffer, 1, "broker/GetPipe", {"pipe": "wb.request"})
        channel = str(pipe_result.get("channel") or "")
        if not channel:
            raise RuntimeError("WorkBuddy 未开放额度查询通道")
        raw_body = base64.b64encode(b"{}").decode("ascii")
        result, buffer = wb_rpc(sock, buffer, 2, channel + "/http.fetch", {
            "method": "POST",
            "path": "/billing/meter/get-user-resource-summary",
            "headers": {"accept": "application/json", "content-type": "application/json"},
            "body_b64": raw_body,
        })
        status = int(number(result.get("status")))
        if status == 401 or status == 403:
            raise RuntimeError("WorkBuddy 授权失效，请在客户端重新登录")
        if status < 200 or status >= 300:
            raise RuntimeError("WorkBuddy 额度接口返回 HTTP %d" % status)
        encoded = result.get("body_b64") or ""
        payload = json.loads(base64.b64decode(encoded).decode("utf-8"))
        if payload.get("code") != 0:
            raise RuntimeError("WorkBuddy 额度接口错误：" + str(payload.get("msg") or "未知错误")[:120])
        data = payload.get("data") or {}
        packages = data.get("Packages") if isinstance(data.get("Packages"), list) else []
        total = 0.0
        remains = 0.0
        for item in packages:
            if not isinstance(item, dict):
                continue
            cycle_total = item.get("CycleTotalCapacity")
            cycle_remain = item.get("CycleRemainCapacity")
            if cycle_total is not None or cycle_remain is not None:
                total += number(cycle_total)
                remains += number(cycle_remain)
            else:
                total += number(item.get("CapacitySize") or item.get("Capacity"))
                remains += number(item.get("CapacityRemain") or item.get("Remain"))
        reported_remaining = data.get("TotalCredits")
        remaining = number(reported_remaining, remains) if reported_remaining is not None else remains
        total = max(total, remaining)
        used = max(total - remaining, 0.0)
        percent = round(used * 100.0 / total, 2) if total > 0 else 0.0
        return {
            "ok": True,
            "plan": str(data.get("SubscriptionPackageName") or "WorkBuddy"),
            "total": round(total, 2),
            "remaining": round(remaining, 2),
            "used": round(used, 2),
            "usedPercent": percent,
            "remainingPercent": round(100.0 - percent, 2),
            "packages": len(packages),
            "unit": "credits",
            "updatedAt": int(time.time()),
        }
    except Exception as exc:
        return fail(exc)
    finally:
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass


# ---------------------------------------------------------------- Qoder

def qoder_cli_paths():
    return [
        HOME / ".local" / "bin" / "qoderclicn",
        HOME / ".qoder-cn" / "bin" / "qoderclicn" / "qoderclicn",
        Path("/usr/local/bin/qoderclicn"),
        Path("/opt/homebrew/bin/qoderclicn"),
    ]


def qoder_cli_search_path():
    # A GUI-launched app inherits a minimal PATH, so add the usual install dirs.
    parts = os.environ.get("PATH", "").split(os.pathsep)
    parts += [str(parent) for parent in {p.parent for p in qoder_cli_paths()}]
    seen = set()
    ordered = [p for p in parts if p and not (p in seen or seen.add(p))]
    return os.pathsep.join(ordered)


def qoder_cli():
    for path in qoder_cli_paths():
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    found = shutil.which("qoderclicn", path=qoder_cli_search_path())
    if found:
        return found
    version_dir = HOME / ".qoder-cn" / "bin" / "qoderclicn"
    if version_dir.is_dir():
        for path in sorted(version_dir.glob("qoderclicn-*"), reverse=True):
            if path.is_file() and os.access(path, os.X_OK):
                return str(path)
    return None


def qoder_cli_missing_message():
    blocked = [p for p in qoder_cli_paths() if p.exists() and not os.access(p, os.X_OK)]
    if blocked:
        return "未安装可用的 Qoder CLI；权限异常：" + str(blocked[0])
    install = "安装：curl -fsSL https://static.qoder.com.cn/qoder-cli-cn/install.sh | bash"
    if (Path("/Applications/Qoder CN.app") / "Contents" / "Info.plist").exists():
        return "未安装 Qoder CLI（已检测到 Qoder 客户端，但额度需官方 CLI 读取）；" + install
    return "未安装 Qoder CLI；" + install


def qoder_env():
    env = dict(os.environ)
    for key in list(env):
        if key.startswith("QODER_AGENT_SDK_") or key.startswith("QODER_SDK_"):
            env.pop(key, None)
    env["TERM"] = "xterm-256color"
    env["BROWSER"] = "/usr/bin/true"
    return env


def qoder_kill(pid, fd):
    try:
        group = os.getpgid(pid)
        if group != os.getpgid(0):
            os.killpg(group, signal.SIGKILL)
    except Exception:
        pass
    try:
        os.kill(pid, signal.SIGKILL)
    except Exception:
        pass
    try:
        os.waitpid(pid, os.WNOHANG)
    except Exception:
        pass
    try:
        os.close(fd)
    except Exception:
        pass


def qoder_field(compact, name, following):
    pattern = re.escape(name) + r":(.*?)(?=" + "|".join(re.escape(item) + ":" for item in following) + r"|$)"
    match = re.search(pattern, compact)
    return match.group(1) if match else None


def parse_qoder(text):
    compact = re.sub(r"\s+", "", strip_ansi(text))
    plan = qoder_field(compact, "QoderCNPlan", ["PlanExpiresAt", "PlanCreditsUsed", "Add-onCreditsUsed"])
    if plan is None:
        plan = qoder_field(compact, "Plan", ["PlanExpiresAt", "PlanCreditsUsed", "Add-onCreditsUsed"])
    expires = qoder_field(compact, "PlanExpiresAt", ["PlanCreditsUsed", "Add-onCreditsUsed", "OrgResourcePackage"])
    org = qoder_field(compact, "OrgResourcePackage", ["TotalDuration(API)", "TotalDuration", "TotalCodeChanges"])
    plan_match = re.search(r"PlanCreditsUsed:([\d,.]+)/([\d,.]+)", compact)
    addon_match = re.search(r"Add-onCreditsUsed:([\d,.]+)/([\d,.]+)", compact)
    if not addon_match and not plan_match:
        return None
    plan_used = number(plan_match.group(1)) if plan_match else 0.0
    plan_total = number(plan_match.group(2)) if plan_match else 0.0
    addon_used = number(addon_match.group(1)) if addon_match else 0.0
    addon_total = number(addon_match.group(2)) if addon_match else 0.0
    total = plan_total + addon_total
    remaining = max(total - plan_used - addon_used, 0.0)
    percent = round((plan_used + addon_used) * 100.0 / total, 2) if total > 0 else 0.0
    return {
        "ok": True,
        "plan": (plan or "未知").strip(),
        "planExpiresAt": (expires or "N/A").strip(),
        "planUsed": round(plan_used, 2),
        "planTotal": round(plan_total, 2),
        "addonUsed": round(addon_used, 2),
        "addonTotal": round(addon_total, 2),
        "orgResourcePackage": (org or "N/A").strip(),
        "total": round(total, 2),
        "remaining": round(remaining, 2),
        "used": round(plan_used + addon_used, 2),
        "usedPercent": percent,
        "remainingPercent": round(100.0 - percent, 2),
        "unit": "credits",
        "source": "Qoder CLI",
        "updatedAt": int(time.time()),
    }


def collect_qoder() -> dict:
    cli = qoder_cli()
    if not cli:
        return fail(qoder_cli_missing_message())
    workdir = APP_SUPPORT / "qoder-cwd"
    try:
        workdir.mkdir(parents=True, exist_ok=True)
    except Exception:
        return fail("无法创建 Qoder CLI 工作目录")
    pid = fd = None
    output = ""
    try:
        pid, fd = pty.fork()
        if pid == 0:
            try:
                os.chdir(str(workdir))
                os.execvpe(cli, [cli], qoder_env())
            finally:
                os._exit(127)
        deadline = time.time() + 50
        sent_trust = False
        sent_usage = False
        usage_started = 0.0
        while time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.5)
            if ready:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk.decode("utf-8", "replace")
            clean = strip_ansi(output)
            compact = re.sub(r"\s+", "", clean).lower()
            if not sent_trust and "doyoutrustthefilesinthisfolder" in compact:
                os.write(fd, b"1\r")
                sent_trust = True
                continue
            if not sent_usage and ("?forshortcuts" in compact or "typeyourmessage" in compact):
                time.sleep(1.2)
                os.write(fd, b"/usage\r")
                sent_usage = True
                usage_started = time.time()
                continue
            if sent_usage and ("add-oncreditsused" in compact or "plancreditsused" in compact):
                time.sleep(1.2)
                try:
                    ready, _, _ = select.select([fd], [], [], 0.3)
                    if ready:
                        output += os.read(fd, 65536).decode("utf-8", "replace")
                except Exception:
                    pass
                break
        try:
            os.write(fd, b"\x1b")
            time.sleep(0.2)
            os.write(fd, b"/quit\r")
            time.sleep(0.4)
            os.write(fd, b"\x03")
        except Exception:
            pass
        parsed = parse_qoder(output)
        if parsed:
            return parsed
        compact = re.sub(r"\s+", "", strip_ansi(output)).lower()
        if "notlogin" in compact or "pleaseauth" in compact or "waitingforauthentication" in compact:
            return fail("Qoder CLI 未登录，请在终端运行 qoderclicn login")
        if not sent_usage:
            return fail("Qoder CLI 未进入会话（可能未登录或版本不兼容）")
        if sent_usage and time.time() < deadline:
            return fail("Qoder 用量面板未返回数据")
        return fail("Qoder 用量读取超时")
    except Exception as exc:
        return fail(exc)
    finally:
        if pid is not None and fd is not None:
            qoder_kill(pid, fd)


# ---------------------------------------------------------------- main

def collect(provider):
    funcs = {
        "codex": collect_codex,
        "workbuddy": collect_workbuddy,
        "qoder": collect_qoder,
    }
    try:
        return funcs[provider]()
    except Exception as exc:
        return fail(exc)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider", default="all", choices=["all", "fast", "codex", "workbuddy", "qoder"])
    args = parser.parse_args()
    providers = []
    if args.provider in ("all", "fast", "codex"):
        providers.append("codex")
    if args.provider in ("all", "fast", "workbuddy"):
        providers.append("workbuddy")
    if args.provider in ("all", "qoder"):
        providers.append("qoder")
    result = {"version": 1, "updatedAt": int(time.time()), "providers": {}}
    if len(providers) > 1:
        with ThreadPoolExecutor(max_workers=len(providers)) as pool:
            futures = {name: pool.submit(collect, name) for name in providers}
            for name, future in futures.items():
                try:
                    result["providers"][name] = future.result()
                except Exception as exc:
                    result["providers"][name] = fail(exc)
    else:
        for name in providers:
            result["providers"][name] = collect(name)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
