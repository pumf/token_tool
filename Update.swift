import AppKit
import Combine
import CryptoKit
import Foundation

struct UpdateRelease: Equatable, Sendable {
    struct Asset: Equatable, Sendable {
        let name: String
        let url: URL
    }

    let version: String
    let tag: String
    let pageURL: URL
    let notes: String
    let assets: [Asset]
    let checksums: [String: String]

    init(
        version: String,
        tag: String,
        pageURL: URL,
        notes: String,
        assets: [Asset],
        checksums: [String: String] = [:]
    ) {
        self.version = version
        self.tag = tag
        self.pageURL = pageURL
        self.notes = notes
        self.assets = assets
        self.checksums = checksums
    }

    static func assets(fromExpandedHTML html: String, tag: String) -> [Asset] {
        let marker = "/releases/download/\(tag)/"
        guard let regex = try? NSRegularExpression(pattern: #"href="([^"]+?)""#) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var found: [Asset] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges > 1,
                  let pathRange = Range(match.range(at: 1), in: html) else { continue }
            var path = String(html[pathRange])
                .replacingOccurrences(of: "&amp;", with: "&")
            guard path.contains(marker) else { continue }
            if path.hasPrefix("/") { path = "https://github.com" + path }
            guard let url = URL(string: path),
                  url.scheme == "https",
                  let name = url.lastPathComponent.removingPercentEncoding,
                  !name.isEmpty,
                  seen.insert(name).inserted else { continue }
            found.append(Asset(name: name, url: url))
        }
        return found
    }

    static func conventionalAssets(version: String, tag: String) -> [Asset] {
        let base = "https://github.com/pumf/token_tool/releases/download/\(tag)/"
        let names = [
            "TokenTool-\(version)-arm64.dmg",
            "TokenTool-\(version)-x86_64.dmg",
            "TokenTool-\(version).dmg",
            "TokenTool-\(version)-arm64.zip",
            "TokenTool-\(version)-x86_64.zip",
            "TokenTool-\(version).zip"
        ]
        return names.compactMap { name in
            guard let url = URL(string: base + name) else { return nil }
            return Asset(name: name, url: url)
        }
    }

    func installerURL(for architecture: String) -> URL? {
        let images = assets.filter {
            $0.name.lowercased().hasSuffix(".dmg") && $0.url.scheme == "https"
        }
        let nativeSuffix = "-\(architecture)."
        if let native = images.first(where: { $0.name.lowercased().contains(nativeSuffix) }) {
            return native.url
        }
        let universal = images.first {
            let name = $0.name.lowercased()
            return !name.contains("-arm64.") && !name.contains("-x86_64.")
        }
        return universal?.url
    }

    func checksum(for assetName: String) -> String? {
        if let direct = checksums[assetName.lowercased()] {
            return direct
        }
        for line in notes.components(separatedBy: .newlines) where line.contains(assetName) {
            if let range = line.range(of: #"[0-9a-fA-F]{64}"#, options: .regularExpression) {
                return String(line[range]).lowercased()
            }
        }
        return nil
    }

    static func checksums(fromSHA256SUMS text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  parts[0].count == 64,
                  parts[0].allSatisfy({ $0.isHexDigit && $0.isASCII }) else { continue }
            var name = parts[1]
            if name.hasPrefix("*") { name = name.dropFirst() }
            let lowered = name.lowercased()
            guard !lowered.isEmpty else { continue }
            result[lowered] = parts[0].lowercased()
        }
        return result
    }
}

enum UpdateVersion {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate)
        let rhs = components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func components(_ value: String) -> [Int] {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { part in
                let digits = part.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}

private enum UpdateError: Error {
    case badResponse
    case http(Int)
    case invalidDownload
    case checksumMismatch

    var message: String {
        switch self {
        case .badResponse:
            return "GitHub 返回了无法识别的版本信息"
        case .http(let code):
            return code == 403 ? "GitHub 访问受限，请稍后重试" : "GitHub 返回 HTTP \(code)"
        case .invalidDownload:
            return "下载的安装包无效"
        case .checksumMismatch:
            return "安装包 SHA-256 校验失败，请重试或从 Release 页面手动下载"
        }
    }
}

enum UpdateInstaller {
    struct Failure: Error {
        let message: String
    }

    /// 只有从 /Applications 里运行、且安装包过了 SHA-256 校验，才敢自动替换；
    /// 从 build 目录里跑的开发实例、或没有校验值的包，都退回手动拖拽。
    static func canInstall(bundleURL: URL, verified: Bool) -> Bool {
        verified && bundleURL.path.hasPrefix("/Applications/")
            && bundleURL.lastPathComponent == "TokenTool.app"
    }

    /// 挂载 DMG → 复制新版本到临时位置 → 原子替换 → 备份清理。
    /// 任一步失败都在替换前中止，或替换失败后回滚，不留半装状态。
    static func install(dmg: URL, replacing destination: URL, expectedVersion: String?) throws {
        let manager = FileManager.default
        let mount = manager.temporaryDirectory
            .appendingPathComponent("TokenTool-mount-\(UUID().uuidString)")
        try manager.createDirectory(at: mount, withIntermediateDirectories: false)
        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path], timeout: 30)
            try? manager.removeItem(at: mount)
        }
        _ = try run(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, dmg.path],
            timeout: 90
        )
        guard let source = mountedApp(in: mount) else {
            throw Failure(message: "安装包里找不到 TokenTool.app")
        }
        if let expectedVersion, let mounted = bundleVersion(source), mounted != expectedVersion {
            throw Failure(message: "安装包版本是 \(mounted)，与发布标记 \(expectedVersion) 不一致")
        }

        let staging = manager.temporaryDirectory
            .appendingPathComponent("TokenTool-new-\(UUID().uuidString)/TokenTool.app")
        try manager.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging.deletingLastPathComponent()) }
        _ = try run("/usr/bin/ditto", [source.path, staging.path], timeout: 180)
        guard bundleVersion(staging) != nil else {
            throw Failure(message: "复制后的应用无法识别")
        }

        let backup = destination.appendingPathExtension("previous")
        try? manager.removeItem(at: backup)
        do {
            try manager.moveItem(at: destination, to: backup)
            try manager.moveItem(at: staging, to: destination)
        } catch {
            // 写回原版本；能撤就撤，撤不掉就把错误抛给调用方去手动安装。
            try? manager.moveItem(at: backup, to: destination)
            throw Failure(message: "写入 /Applications 失败，请手动拖拽安装")
        }
        try? manager.removeItem(at: backup)
    }

    static func mountedApp(in mount: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: mount, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries.first {
            $0.lastPathComponent == "TokenTool.app" && bundleVersion($0) != nil
        }
    }

    static func bundleVersion(_ url: URL) -> String? {
        let path = url.appendingPathComponent("Contents/Info.plist").path
        guard let plist = NSDictionary(contentsOfFile: path) else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    private static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let tool = URL(fileURLWithPath: launchPath).lastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokentool-install-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: outputURL) else {
            throw Failure(message: "无法收集 \(tool) 的输出")
        }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = handle
        process.standardError = handle
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw Failure(message: "\(tool) 启动失败")
        }
        guard exited.wait(timeout: .now() + timeout) != .timedOut else {
            process.terminate()
            _ = exited.wait(timeout: .now() + 5)
            throw Failure(message: "\(tool) 超时")
        }
        let text = (try? Data(contentsOf: outputURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard process.terminationStatus == 0 else {
            throw Failure(message: "\(tool) 失败（\(process.terminationStatus)）")
        }
        return text
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading(UpdateRelease)
        case ready(UpdateRelease, URL, verified: Bool)
        case installing(UpdateRelease)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var lastCheckAt: Date?
    @Published private(set) var showsResult = false
    let currentVersion: String

    private static let lastCheckKey = "updates.lastCheckAt"
    private static let repository = "https://github.com/pumf/token_tool"
    private static let endpoint = URL(string: "https://api.github.com/repos/pumf/token_tool/releases/latest")!
    private let session: URLSession
    private var didAutoCheck = false
    private var resultTask: Task<Void, Never>?

    init() {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if last > 0 {
            lastCheckAt = Date(timeIntervalSince1970: last)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration)
    }

    var pendingRelease: UpdateRelease? {
        switch state {
        case .available(let release), .downloading(let release),
             .ready(let release, _, _), .installing(let release):
            return release
        default:
            return nil
        }
    }

    var isWorking: Bool {
        switch state {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }

    /// 只有已校验、且当前就跑在 /Applications 里，才敢承诺「安装并重启」。
    var canAutoInstall: Bool {
        guard case .ready(_, _, let verified) = state else { return false }
        return UpdateInstaller.canInstall(bundleURL: Bundle.main.bundleURL, verified: verified)
    }

    var primaryActionTitle: String {
        switch state {
        case .downloading:
            return "下载中"
        case .installing:
            return "安装中"
        case .ready:
            return canAutoInstall ? "安装并重启" : "打开安装包"
        default:
            return "下载更新"
        }
    }

    var canPerformPrimaryAction: Bool {
        switch state {
        case .downloading, .installing:
            return false
        default:
            return true
        }
    }

    func checkIfNeeded() {
        guard !didAutoCheck else { return }
        didAutoCheck = true
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard last == 0 || Date().timeIntervalSince1970 - last >= 86400 else { return }
        check()
    }

    func checkFromUser() {
        check(userInitiated: true)
    }

    func dismissResult() {
        resultTask?.cancel()
        showsResult = false
    }

    func check(userInitiated: Bool = false) {
        guard !isWorking else { return }
        state = .checking
        lastError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let release = try await self.fetchLatest()
                let now = Date()
                UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)
                self.lastCheckAt = now
                if UpdateVersion.isNewer(release.version, than: self.currentVersion) {
                    self.state = .available(release)
                } else {
                    self.state = .upToDate
                }
            } catch {
                let message = Self.message(for: error)
                Diagnostics.record("update", "检查更新失败：\(message)")
                self.lastError = message
                self.state = .failed(message)
            }
            if userInitiated {
                self.flashResult()
            }
        }
    }

    private func flashResult() {
        resultTask?.cancel()
        showsResult = true
        resultTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.showsResult = false
        }
    }

    func performPrimaryAction() {
        switch state {
        case .available(let release):
            download(release)
        case .ready(let release, let url, true):
            install(release, from: url)
        case .ready(_, let url, false):
            confirmAndOpen(url)
        default:
            break
        }
    }

    /// 校验通过的包直接半自动升级：挂载、替换 /Applications 里的应用、启动新版本。
    /// 不满足自动安装条件（开发实例、非 /Applications）时退回打开安装包。
    private func install(_ release: UpdateRelease, from dmg: URL) {
        let destination = Bundle.main.bundleURL
        guard UpdateInstaller.canInstall(bundleURL: destination, verified: true) else {
            NSWorkspace.shared.open(dmg)
            return
        }
        state = .installing(release)
        lastError = nil
        let expectedVersion = release.version
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try UpdateInstaller.install(dmg: dmg, replacing: destination, expectedVersion: expectedVersion)
                    return nil
                } catch {
                    return (error as? UpdateInstaller.Failure)?.message ?? "自动安装失败"
                }
            }.value
            if let outcome {
                Diagnostics.record("update", "自动安装失败：\(outcome)")
                self.lastError = outcome
                self.state = .ready(release, dmg, verified: true)
                return
            }
            Diagnostics.record("update", "已自动安装 \(expectedVersion)，正在重启")
            NSWorkspace.shared.open(destination)
            NSApp.terminate(nil)
        }
    }

    /// 没有校验值就不默认打开：先讲清风险，用户确认后才挂载安装包。
    private func confirmAndOpen(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "安装包缺少 SHA-256 校验值"
        alert.informativeText = """
            这次没能从 Release 页面拿到 \(url.lastPathComponent) 的校验值，无法确认它和发布版本一致。
            可以先从 Release 页面自行核对，或确认网络环境后继续打开。
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "仍要打开")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            Diagnostics.record("update", "用户取消了未校验的安装包")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func download(_ release: UpdateRelease) {
        guard let url = release.installerURL(for: Self.architecture) else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        state = .downloading(release)
        lastError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (temporaryURL, response) = try await self.session.download(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size > 100_000 else { throw UpdateError.invalidDownload }
                var verified = false
                if let expected = release.checksum(for: url.lastPathComponent) {
                    let actual = try UpdateVerification.sha256Hex(of: destination)
                    guard actual == expected else {
                        try? FileManager.default.removeItem(at: destination)
                        throw UpdateError.checksumMismatch
                    }
                    verified = true
                }
                Diagnostics.record(
                    "update",
                    verified
                        ? "已下载并通过 SHA-256 校验：\(url.lastPathComponent)"
                        : "已下载但没有校验值：\(url.lastPathComponent)"
                )
                self.state = .ready(release, destination, verified: verified)
            } catch {
                Diagnostics.record("update", "下载更新失败：\(Self.message(for: error))")
                self.lastError = Self.message(for: error)
                self.state = .available(release)
            }
        }
    }

    private func fetchLatest() async throws -> UpdateRelease {
        let release: UpdateRelease
        do {
            release = try await fetchLatestFromAPI()
        } catch {
            release = try await fetchLatestFromWeb()
        }
        guard release.checksums.isEmpty else { return release }
        let checksums = await fetchChecksums(tag: release.tag)
        guard !checksums.isEmpty else { return release }
        return UpdateRelease(
            version: release.version,
            tag: release.tag,
            pageURL: release.pageURL,
            notes: release.notes,
            assets: release.assets,
            checksums: checksums
        )
    }

    private func fetchChecksums(tag: String) async -> [String: String] {
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        guard let url = URL(string: Self.repository + "/releases/download/\(encodedTag)/SHA256SUMS") else {
            return [:]
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("TokenTool/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            return [:]
        }
        return UpdateRelease.checksums(fromSHA256SUMS: text)
    }

    private func fetchLatestFromAPI() async throws -> UpdateRelease {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TokenTool/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }

        let payload: GitHubRelease
        do {
            payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.badResponse
        }
        guard let pageURL = URL(string: payload.htmlURL) else { throw UpdateError.badResponse }
        let assets = payload.assets.compactMap { item -> UpdateRelease.Asset? in
            guard let url = URL(string: item.browserDownloadURL), url.scheme == "https" else { return nil }
            return UpdateRelease.Asset(name: item.name, url: url)
        }
        let version = payload.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard !version.isEmpty else { throw UpdateError.badResponse }
        return UpdateRelease(
            version: version,
            tag: payload.tagName,
            pageURL: pageURL,
            notes: payload.body ?? "",
            assets: assets
        )
    }

    private func fetchLatestFromWeb() async throws -> UpdateRelease {
        guard let latestURL = URL(string: Self.repository + "/releases/latest") else {
            throw UpdateError.badResponse
        }
        var request = URLRequest(url: latestURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("TokenTool/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
        guard let pageURL = response.url, pageURL.path.contains("/releases/tag/") else {
            throw UpdateError.badResponse
        }
        let tag = pageURL.lastPathComponent.removingPercentEncoding ?? pageURL.lastPathComponent
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard !version.isEmpty else { throw UpdateError.badResponse }

        let assets = (try? await fetchAssetsFromWeb(tag: tag))
            ?? UpdateRelease.conventionalAssets(version: version, tag: tag)
        let checksums = await fetchChecksums(tag: tag)
        return UpdateRelease(
            version: version,
            tag: tag,
            pageURL: pageURL,
            notes: "",
            assets: assets,
            checksums: checksums
        )
    }

    private func fetchAssetsFromWeb(tag: String) async throws -> [UpdateRelease.Asset] {
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        guard let url = URL(string: Self.repository + "/releases/expanded_assets/" + encodedTag) else {
            throw UpdateError.badResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("TokenTool/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
        guard let html = String(data: data, encoding: .utf8) else { throw UpdateError.badResponse }
        let assets = UpdateRelease.assets(fromExpandedHTML: html, tag: tag)
        guard !assets.isEmpty else { throw UpdateError.badResponse }
        return assets
    }

    private static var architecture: String {
#if arch(arm64)
        "arm64"
#else
        "x86_64"
#endif
    }

    private static func message(for error: Error) -> String {
        if let updateError = error as? UpdateError { return updateError.message }
        if (error as NSError).domain == NSURLErrorDomain {
            return "无法访问 GitHub，请检查网络或代理"
        }
        return "更新请求失败"
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

enum UpdateVerification {
    static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
