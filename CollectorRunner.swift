import Foundation
import AppKit
import Darwin

enum CollectorRunner {
    struct RunResult: Sendable {
        let output: CollectorOutput?
        let error: String?
    }

    struct ActionResult: Sendable {
        let action: CollectorAction?
        let error: String?
    }

    private struct ActionEnvelope: Decodable {
        let result: CollectorAction?
    }

    static func run(provider: String, timeout: TimeInterval = 80) -> RunResult {
        switch execute(["--provider", provider], timeout: timeout) {
        case .failure(let message):
            return RunResult(output: nil, error: message)
        case .success(let data):
            do {
                return RunResult(
                    output: try JSONDecoder().decode(CollectorOutput.self, from: data),
                    error: nil
                )
            } catch {
                return RunResult(output: nil, error: "采集器输出无法解析")
            }
        }
    }

    static func action(_ name: String, timeout: TimeInterval) -> ActionResult {
        switch execute(["--action", name], timeout: timeout) {
        case .failure(let message):
            return ActionResult(action: nil, error: message)
        case .success(let data):
            guard let envelope = try? JSONDecoder().decode(ActionEnvelope.self, from: data),
                  let result = envelope.result else {
                return ActionResult(action: nil, error: "采集器输出无法解析")
            }
            if !result.ok {
                return ActionResult(action: result, error: result.error ?? "操作失败")
            }
            return ActionResult(action: result, error: nil)
        }
    }

    private enum Capture {
        case success(Data)
        case failure(String)
    }

    // Output goes to temp files rather than pipes: install scripts can write more
    // than the 64KB pipe buffer and would otherwise block the child process.
    private static func execute(_ arguments: [String], timeout: TimeInterval) -> Capture {
        guard let script = Bundle.main.url(forResource: "collector", withExtension: "py") else {
            return .failure("采集器文件缺失")
        }
        let directory = FileManager.default.temporaryDirectory
        let tag = UUID().uuidString
        let outputURL = directory.appendingPathComponent("tokentool-\(tag).out")
        let errorURL = directory.appendingPathComponent("tokentool-\(tag).err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let process = Process()
        var didLaunch = false
        guard let outputHandle = try? FileHandle(forWritingTo: outputURL),
              let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
            return .failure("无法创建采集器输出文件")
        }
        defer {
            // 无论走哪条返回路径都要关句柄、回收子进程、删临时文件；
            // 旧实现在超时分支直接 return，每次超时都留下一个僵尸进程和两个未关闭的 fd。
            try? outputHandle.close()
            try? errorHandle.close()
            if didLaunch { reap(process) }
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        let extraPath = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = extraPath + ":" + (environment["PATH"] ?? "")
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        // 退出事件用信号量等，不 sleep 轮询；handler 必须在 run 之前装好，
        // 否则秒退的子进程可能错过信号。
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
            didLaunch = true
        } catch {
            return .failure("无法启动采集器：\(error.localizedDescription)")
        }

        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if didLaunch { reap(process) }
        let stderr = readTail(of: errorURL, bytes: 600)
        if timedOut {
            return .failure(classify(timeout: timeout, stderr: stderr))
        }
        guard let data = try? Data(contentsOf: outputURL), !data.isEmpty else {
            return .failure(classify(status: process.terminationStatus, stderr: stderr))
        }
        if process.terminationStatus != 0, !stderr.isEmpty {
            Diagnostics.record("collector", "退出码 \(process.terminationStatus)：\(stderr)")
        }
        return .success(data)
    }

    /// 先 TERM、再 KILL，最后 waitUntilExit 收尸；重复调用安全。
    private static func reap(_ process: Process) {
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
    }

    private static func readTail(of url: URL, bytes: Int) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        let tail = data.suffix(bytes)
        return String(decoding: tail, as: UTF8.self)
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(3)
            .joined(separator: " / ")
    }

    /// 把「python3 不存在」「需要命令行工具」这类环境问题说清楚，而不是统一报采集超时。
    private static func classify(timeout: TimeInterval, stderr: String) -> String {
        let reason = stderr.isEmpty ? "" : "（\(stderr)）"
        return "采集超时 \(Int(timeout)) 秒\(reason)"
    }

    private static func classify(status: Int32, stderr: String) -> String {
        if stderr.contains("python3") && stderr.contains("No such file") {
            return "本机没有 python3，请安装 Xcode 命令行工具（xcode-select --install）后重试"
        }
        if stderr.contains("xcode-select") {
            return "需要先安装 Xcode 命令行工具才能采集（xcode-select --install）"
        }
        if status == 127 {
            return "找不到 python3，请安装 Xcode 命令行工具后重试"
        }
        let reason = stderr.isEmpty ? "" : "：\(stderr)"
        return "采集器没有输出任何数据（退出码 \(status)\(reason)）"
    }
}

enum LaunchAtLogin {
    static let label = "com.local.tokentool"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        // plist 存在不代表真的会启动：被 bootout、disable 或加载失败时以 launchd 的实际状态为准。
        FileManager.default.fileExists(atPath: plistURL.path)
            && run(["/bin/launchctl", "print", "gui/\(getuid())/\(label)"]) == 0
    }

    static func setEnabled(_ enabled: Bool) {
        let manager = FileManager.default
        if enabled {
            let appPath = Bundle.main.bundleURL.path
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", appPath],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
            ]
            guard let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            ) else { return }
            try? manager.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: plistURL, options: .atomic)
            _ = run(["/bin/launchctl", "enable", "gui/\(getuid())/\(label)"])
            // 立即加载让开关当场生效，而不是只写文件等下次登录；已加载时 bootstrap 报错，忽略即可。
            _ = run(["/bin/launchctl", "bootstrap", "gui/\(getuid())", plistURL.path])
        } else {
            _ = run(["/bin/launchctl", "bootout", "gui/\(getuid())/\(label)"])
            try? manager.removeItem(at: plistURL)
        }
    }

    @discardableResult
    static func run(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
