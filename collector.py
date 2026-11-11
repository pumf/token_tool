#!/usr/bin/env python3
"""Collect local usage for Codex, WorkBuddy, Qoder and Claude Code without touching credentials."""

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
from datetime import datetime
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


# ------------------------------------------------- Qoder bootstrap actions

QODER_INSTALL_URL = "https://static.qoder.com.cn/qoder-cli-cn/install.sh"
QODER_LOGIN_STATE = APP_SUPPORT / "qoder-login.json"
URL_RE = re.compile(r"https?://[^\s\x07\x1b\"'<>]+")


def _redact_urls(text):
    return URL_RE.sub("<url>", text)


def _login_state_read():
    try:
        data = json.loads(QODER_LOGIN_STATE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _login_state_write(**fields):
    state = _login_state_read()
    state.update(fields)
    state["updatedAt"] = int(time.time())
    try:
        APP_SUPPORT.mkdir(parents=True, exist_ok=True)
        QODER_LOGIN_STATE.write_text(
            json.dumps(state, ensure_ascii=False), encoding="utf-8"
        )
    except Exception:
        pass
    return state


def qoder_install():
    existing = qoder_cli()
    if existing:
        return {"ok": True, "status": "already", "cli": existing}
    env = dict(os.environ)
    env["PATH"] = qoder_cli_search_path()
    command = f"curl -fsSL {QODER_INSTALL_URL} | bash"
    try:
        proc = subprocess.run(
            ["/bin/zsh", "-c", command],
            capture_output=True,
            text=True,
            timeout=300,
            env=env,
        )
    except subprocess.TimeoutExpired:
        return fail("Qoder CLI 安装超时，请在终端手动执行安装命令")
    except Exception as exc:
        return fail(exc)
    installed = qoder_cli()
    if installed:
        return {"ok": True, "status": "installed", "cli": installed}
    tail = _redact_urls(strip_ansi((proc.stdout or "") + "\n" + (proc.stderr or "")))
    return fail("安装脚本已执行但未找到 qoderclicn（退出码 %d）：%s" % (proc.returncode, tail[-300:]))


def _qoder_login_daemon(cli):
    pid = fd = None
    output = ""
    url = None
    status = "failed"
    message = "登录进程异常退出"
    try:
        pid, fd = pty.fork()
        if pid == 0:
            try:
                os.chdir(str(APP_SUPPORT))
                os.execvpe(cli, [cli, "login"], qoder_env())
            finally:
                os._exit(127)
        deadline = time.time() + 300
        exit_code = None
        while time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], 1.0)
            if ready:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    chunk = b""
                if chunk:
                    output += chunk.decode("utf-8", "replace")
                    if url is None:
                        match = URL_RE.search(strip_ansi(output))
                        if match:
                            url = match.group(0).rstrip(".,)]}、。")
                            _login_state_write(status="waiting", url=url)
                    continue
            try:
                done, raw_status = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                done, raw_status = pid, 0
            if done == pid:
                exit_code = os.waitstatus_to_exitcode(raw_status) if hasattr(os, "waitstatus_to_exitcode") else (raw_status >> 8)
                pid = None
                break
        compact = re.sub(r"\s+", "", strip_ansi(output)).lower()
        if url is None:
            message = "登录进程未输出授权链接：" + _redact_urls(strip_ansi(output))[-200:]
        elif exit_code == 0 or "loginsuccess" in compact or "登录成功" in strip_ansi(output):
            status = "done"
            message = None
        elif exit_code is None:
            message = "登录等待超时，请重新发起登录"
        else:
            message = "登录未完成（退出码 %s）" % exit_code
    except Exception as exc:
        message = str(exc)[:200]
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except Exception:
                pass
        if pid:
            qoder_kill(pid, None)
        _login_state_write(status=status, message=message, url=None)


def qoder_login_start():
    cli = qoder_cli()
    if not cli:
        return fail(qoder_cli_missing_message())
    _login_state_write(status="starting", url=None, message=None)
    try:
        APP_SUPPORT.mkdir(parents=True, exist_ok=True)
        pid = os.fork()
    except Exception as exc:
        return fail("无法启动登录进程：" + str(exc)[:120])
    if pid == 0:
        try:
            os.setsid()
            if os.fork() == 0:
                _qoder_login_daemon(cli)
                os._exit(0)
        except Exception:
            os._exit(1)
        os._exit(0)
    try:
        os.waitpid(pid, 0)
    except Exception:
        pass
    deadline = time.time() + 20
    while time.time() < deadline:
        state = _login_state_read()
        if state.get("url") or state.get("status") in ("done", "failed"):
            break
        time.sleep(0.3)
    state = _login_state_read()
    if state.get("status") == "failed":
        return fail(state.get("message") or "登录启动失败")
    if not state.get("url"):
        return fail("未获取到授权链接，请稍后重试")
    return {"ok": True, "status": "waiting", "url": state["url"]}


def qoder_login_status():
    state = _login_state_read()
    status = state.get("status") or "idle"
    if status == "waiting" and time.time() - int(state.get("updatedAt") or 0) > 330:
        status = "failed"
    return {
        "ok": True,
        "status": status,
        "url": state.get("url"),
        "message": state.get("message"),
    }


# ------------------------------------------------------------ Claude Code

CLAUDE_WEEKDAYS = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}
CLAUDE_UNIT_SECONDS = {"d": 86400.0, "h": 3600.0, "m": 60.0, "s": 1.0}
# /usage 的订阅额度分两个窗口：5 小时会话窗口与 7 天周窗口，和 Codex 一样归到窗口制口径。
CLAUDE_WINDOWS = (
    ("session", 300, ("current session",)),
    ("week", 10080, ("current week", "this week")),
)


def claude_binary():
    for path in (
        Path("/opt/homebrew/bin/claude"),
        Path("/usr/local/bin/claude"),
        HOME / ".claude" / "local" / "claude",
    ):
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return shutil.which("claude")


def claude_run(binary, args, timeout):
    env = dict(os.environ)
    # 采集是后台子进程，绝不允许触发自动更新去改写用户的 CLI。
    env["DISABLE_AUTOUPDATER"] = "1"
    return subprocess.run(
        [binary] + list(args), capture_output=True, text=True, timeout=timeout, env=env
    ).stdout


def claude_json(raw):
    try:
        payload = json.loads(raw)
    except (TypeError, ValueError):
        return {}
    return payload if isinstance(payload, dict) else {}


def claude_line(text, label):
    for raw in text.splitlines():
        if label in raw.lower():
            return raw
    return None


def claude_percent(line):
    """取窗口已用百分比；「X% left / remaining」这种反向表述换算成已用。"""
    if not line:
        return None
    used = re.search(r"(\d+(?:\.\d+)?)\s*%\s*used", line, re.I)
    if used:
        return max(0.0, min(100.0, number(used.group(1))))
    left = re.search(r"(\d+(?:\.\d+)?)\s*%\s*(?:left|remaining)", line, re.I)
    if left:
        return max(0.0, min(100.0, 100.0 - number(left.group(1))))
    return None


def claude_reset_epoch(line, now=None):
    """把重置文案换算成时间戳：'3:00 PM' 取下一个该时刻，'Mon' 取下一个周一零点，
    'in 2h 15m' 按相对时长。认不出来返回 None，界面按「重置时间未知」显示。"""
    if not line:
        return None
    parts = line.lower().split("resets")
    if len(parts) < 2:
        return None
    text = parts[1].strip()
    moment = time.time() if now is None else float(now)

    clock = re.search(r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)", text)
    if clock:
        hour = int(clock.group(1)) % 12 + (12 if clock.group(3) == "pm" else 0)
        local = time.localtime(moment)
        candidate = time.mktime(
            (local.tm_year, local.tm_mon, local.tm_mday, hour, int(clock.group(2) or 0), 0, 0, 0, -1)
        )
        if candidate <= moment:
            candidate += 86400
        return int(candidate)

    span = 0.0
    matched = False
    for value, unit in re.findall(r"(\d+(?:\.\d+)?)\s*([a-z]+)", text):
        seconds = CLAUDE_UNIT_SECONDS.get(unit[0])
        if seconds:
            span += number(value) * seconds
            matched = True
    if matched and span > 0:
        return int(moment + span)

    day = re.search(r"\b(mon|tue|wed|thu|fri|sat|sun)", text)
    if day:
        local = time.localtime(moment)
        delta = (CLAUDE_WEEKDAYS[day.group(1)] - local.tm_wday) % 7 or 7
        return int(time.mktime(
            (local.tm_year, local.tm_mon, local.tm_mday + delta, 0, 0, 0, 0, 0, -1)
        ))
    return None


def claude_usage_windows(text, now=None):
    windows = []
    for name, minutes, labels in CLAUDE_WINDOWS:
        line = None
        for label in labels:
            line = claude_line(text, label)
            if line:
                break
        used = claude_percent(line)
        if used is None:
            continue
        windows.append({
            "id": name,
            "windowMinutes": minutes,
            "usedPercent": round(used, 2),
            "remainingPercent": round(100.0 - used, 2),
            "resetsAt": claude_reset_epoch(line, now),
        })
    return windows


def collect_claude() -> dict:
    binary = claude_binary()
    if not binary:
        return fail("未找到 Claude Code CLI，请先安装 claude 命令")
    try:
        auth = claude_json(claude_run(binary, ["auth", "status"], 20))
    except subprocess.TimeoutExpired:
        return fail("Claude Code: 登录状态查询超时")
    if not auth.get("loggedIn"):
        return fail("Claude Code 未登录，请在终端执行 claude /login")
    try:
        # --no-session-persistence：否则每次采集都在 ~/.claude/projects 里留下一个空会话。
        payload = claude_json(claude_run(
            binary,
            ["-p", "/usage", "--output-format", "json", "--no-session-persistence"],
            45,
        ))
    except subprocess.TimeoutExpired:
        return fail("Claude Code: 用量查询超时")
    if payload.get("is_error"):
        return fail("Claude Code: /usage 返回错误")
    windows = claude_usage_windows(strip_ansi(str(payload.get("result") or "")))
    if not windows:
        # 走 API key 或中继计费时 /usage 只报本次会话花费，没有订阅额度窗口。
        return fail("Claude Code 按 API 计费，没有订阅额度窗口")
    return {
        "ok": True,
        "plan": "unknown",
        "windows": windows,
        "source": "claude-cli",
        "updatedAt": int(time.time()),
    }


# ---------------------------------------------------------------- Trae

# Trae 个人版没有免凭据的用量接口：本机 17788 端口是登录用的 OAuth 回调服务，
# 官方 traecli 也没有 usage 子命令。唯一可读的来源是客户端自己在 renderer 日志里
# 写的一行 `credits mutation refresh completed {"generation":1,"remaining":1200}`。
# 因此这里只匹配这一行、只取数字；同一文件里的其他内容一概不读，也不带进错误信息。
TRAE_LOG_ROOT = APP_SUPPORT.parent / "Trae CN" / "logs"
TRAE_CREDIT_RE = re.compile(
    r"(?P<stamp>\d{4}-\d{2}-\d{2}T[\d:.]+\+[\d:]{2,5})\s+\[[a-z]+\]"
    r"[^\n]*?credits mutation refresh completed\s+"
    r"\{[^{}]*?\"remaining\"\s*:\s*(?P<remaining>-?[\d.]+)"
)
TRAE_LOG_TAIL_BYTES = 2 * 1024 * 1024
TRAE_LOG_FILES_LIMIT = 6


def trae_stamp_epoch(stamp):
    """日志行首的 ISO-8601 时间戳换算成 epoch；认不出来返回 None，由调用方退回采集时刻。"""
    try:
        return int(datetime.fromisoformat(stamp).timestamp())
    except ValueError:
        return None


def trae_log_files(root=None):
    """候选日志按修改时间从新到旧；只认 window*/renderer.log，不翻整个目录树。"""
    base = Path(root) if root else TRAE_LOG_ROOT
    try:
        files = [path for path in base.glob("*/window*/renderer.log") if path.is_file()]
    except OSError:
        return []
    return sorted(files, key=lambda path: path.stat().st_mtime, reverse=True)


def trae_latest_credit(text):
    """取一段日志文本里最后一条积分记录，返回 (epoch, remaining)；没有则 None。"""
    matches = list(TRAE_CREDIT_RE.finditer(text))
    if not matches:
        return None
    return trae_credit_from_match(matches[-1])


def trae_credit_from_match(match):
    return trae_stamp_epoch(match.group("stamp")), number(match.group("remaining"))


def trae_read_tail(path):
    """只读文件末尾，日志可能上百 MB，不能整份读进来。"""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(size - TRAE_LOG_TAIL_BYTES, 0))
            return handle.read()
    except OSError:
        return ""


def trae_scan_file(path):
    """先扫末尾（积分变动通常就在最近）；尾部没有再逐行整扫一遍，内存不随日志大小涨。"""
    credit = trae_latest_credit(trae_read_tail(path))
    if credit is not None:
        return credit
    found = None
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = TRAE_CREDIT_RE.search(line)
                if match:
                    found = match
    except OSError:
        return None
    return trae_credit_from_match(found) if found else None


def collect_trae() -> dict:
    files = trae_log_files()
    if not files:
        return fail("未找到 Trae 日志，请先打开 Trae 并登录")
    now = int(time.time())
    for path in files[:TRAE_LOG_FILES_LIMIT]:
        credit = trae_scan_file(path)
        if credit is None:
            continue
        epoch, remaining = credit
        if remaining < 0:
            continue
        # 积分是余额而不是周期额度，所以只有 remaining、没有 total/usedPercent；
        # 时间戳用日志里那条记录的时刻，重复采集同一个余额不会被算成「没消耗」。
        return {
            "ok": True,
            "plan": "unknown",
            "remaining": round(remaining, 2),
            "unit": "credits",
            "source": "trae-log",
            "updatedAt": epoch if epoch is not None else now,
        }
    return fail("Trae 日志里还没有积分记录，请在 Trae 里打开一次额度面板")


# ---------------------------------------------------------------- main

# 采集入口与分组。分组与 Swift 侧 Providers 注册表的刷新节奏一一对应：
# "fast" 是本地 IPC/子进程较慢的几家共用的一次采集，qoder 走 CLI 单独一档。
# 顺序即 JSON 里 providers 的写出顺序，保持与旧版本一致。
COLLECTORS = {
    "codex": collect_codex,
    "workbuddy": collect_workbuddy,
    "qoder": collect_qoder,
    "claude": collect_claude,
    "trae": collect_trae,
}

GROUPS = {
    "fast": ("codex", "workbuddy"),
    "qoder": ("qoder",),
}


def collect(provider):
    try:
        return COLLECTORS[provider]()
    except Exception as exc:
        return fail(exc)


QODER_ACTIONS = {
    "qoder-install": qoder_install,
    "qoder-login": qoder_login_start,
    "qoder-login-status": qoder_login_status,
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--provider",
        default="all",
        choices=["all", "fast"] + list(COLLECTORS),
    )
    parser.add_argument("--action", default=None, choices=sorted(QODER_ACTIONS))
    args = parser.parse_args()
    if args.action:
        try:
            payload = QODER_ACTIONS[args.action]()
        except Exception as exc:
            payload = fail(exc)
        print(json.dumps(
            {"version": 1, "updatedAt": int(time.time()), "action": args.action, "result": payload},
            ensure_ascii=False,
        ))
        return
    if args.provider == "all":
        providers = list(COLLECTORS)
    else:
        providers = list(GROUPS.get(args.provider, (args.provider,)))
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
