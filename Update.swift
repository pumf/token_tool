import AppKit
import Combine
import CryptoKit
import Foundation

struct UpdateRelease: Equatable {
    struct Asset: Equatable {
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

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading(UpdateRelease)
        case ready(UpdateRelease, URL, verified: Bool)
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
        case .available(let release), .downloading(let release), .ready(let release, _, _):
            return release
        default:
            return nil
        }
    }

    var isWorking: Bool {
        switch state {
        case .checking, .downloading:
            return true
        default:
            return false
        }
    }

    var primaryActionTitle: String {
        switch state {
        case .downloading:
            return "下载中"
        case .ready:
            return "打开安装包"
        default:
            return "下载更新"
        }
    }

    var canPerformPrimaryAction: Bool {
        if case .downloading = state { return false }
        return true
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
        case .ready(_, let url, _):
            NSWorkspace.shared.open(url)
        default:
            break
        }
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
                self.state = .ready(release, destination, verified: verified)
                NSWorkspace.shared.open(destination)
            } catch {
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
