import Foundation
import Security

/// Dotted numeric versions ("1.2.3"). Anything else is rejected rather than guessed at.
public enum Version {
    public static func parse(_ s: String) -> [Int]? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") { t.removeFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 6, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    public static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        return x.lexicographicallyPrecedes(y) ? false : x != y
    }

    public static func normalized(_ s: String) -> String? { parse(s).map { $0.map(String.init).joined(separator: ".") } }
}

/// Release notes are written in Markdown on GitHub but shown as plain text (links must never become clickable).
/// This only strips the markup so the text reads cleanly; it never interprets it.
public enum ReleaseNotes {
    public static func plainText(_ md: String) -> String {
        var out: [String] = []
        for raw in md.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { line = "• " + line.dropFirst(2) }
            for mark in ["**", "__", "`"] { line = line.replacingOccurrences(of: mark, with: "") }
            if line.isEmpty, out.last?.isEmpty ?? true { continue }       // no leading or doubled blank lines
            out.append(line)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }
}

public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let notes: String
    public let pageURL: URL
    public let assetURL: URL
    public let assetSize: Int
    public let sha256: String
}

/// Looks up the newest published release. Only talks to api.github.com and only trusts what it can validate:
/// the tag, the exact asset name, a github.com download URL for this repo, a size cap and a SHA-256 digest.
public struct UpdateChecker {
    public static let repo = "liaw-boy/img_to_ig"
    public static let assetPrefix = "img_to_ig-"
    public static let maxAssetBytes = 150 * 1024 * 1024

    let http: HTTPClient
    let repo: String
    public init(http: HTTPClient, repo: String = UpdateChecker.repo) {
        self.http = http
        self.repo = repo
    }

    /// nil when the newest release is not newer than `current`.
    public func newerRelease(than current: String) async throws -> ReleaseInfo? {
        guard Self.validRepo(repo), let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw IGPubError("更新來源設定不合法")
        }
        let r: (status: Int, body: Data)
        do {
            r = try await http.send("GET", url, body: nil,
                                    headers: ["Accept": "application/vnd.github+json", "User-Agent": "img_to_ig-updater"])
        } catch {
            throw IGPubError("連不上更新伺服器，請確認網路")
        }
        if r.status == 404 { throw IGPubError("找不到發行版（repo 可能還沒公開，或還沒發佈過版本）") }
        guard r.status == 200 else { throw IGPubError("更新伺服器回應異常（HTTP \(r.status)）") }
        guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
            throw IGPubError("更新資訊格式不符")
        }
        return try Self.parse(obj, repo: repo, current: current)
    }

    static func validRepo(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy {
            !$0.isEmpty && $0.count <= 100 && !$0.hasPrefix(".") && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
        }
    }

    static func parse(_ obj: [String: Any], repo: String, current: String) throws -> ReleaseInfo? {
        if obj["draft"] as? Bool == true || obj["prerelease"] as? Bool == true { return nil }
        guard let tag = obj["tag_name"] as? String, let version = Version.normalized(tag) else {
            throw IGPubError("更新資訊的版本號格式不符")
        }
        guard Version.isNewer(version, than: current) else { return nil }
        let name = "\(assetPrefix)\(version).zip"
        guard let assets = obj["assets"] as? [[String: Any]],
              let a = assets.first(where: { $0["name"] as? String == name }) else {
            throw IGPubError("新版 \(version) 沒有附上 \(name)")
        }
        guard let size = (a["size"] as? NSNumber)?.intValue, size > 0, size <= maxAssetBytes else {
            throw IGPubError("新版檔案大小不合理")
        }
        guard let digest = a["digest"] as? String, digest.hasPrefix("sha256:"),
              case let hex = String(digest.dropFirst(7)).lowercased(), hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else {
            throw IGPubError("新版沒有可驗證的 SHA-256，已停止更新")
        }
        guard let dl = (a["browser_download_url"] as? String).flatMap(URL.init(string:)), isAllowedDownload(dl, repo: repo) else {
            throw IGPubError("新版的下載網址不在允許範圍內，已停止更新")
        }
        guard let page = (obj["html_url"] as? String).flatMap(URL.init(string:)), isAllowedPage(page, repo: repo) else {
            throw IGPubError("新版的說明網址不在允許範圍內")
        }
        let notes = String((obj["body"] as? String ?? "").prefix(1500))
        return ReleaseInfo(version: version, notes: notes, pageURL: page, assetURL: dl, assetSize: size, sha256: hex)
    }

    static func isAllowedDownload(_ u: URL, repo: String) -> Bool {
        guard u.scheme == "https", u.host == "github.com", u.user == nil, u.port == nil, u.query == nil else { return false }
        return u.path.hasPrefix("/\(repo)/releases/download/") && !u.path.contains("..")
    }

    static func isAllowedPage(_ u: URL, repo: String) -> Bool {
        u.scheme == "https" && u.host == "github.com" && u.user == nil && u.port == nil && u.path.hasPrefix("/\(repo)/")
    }
}

/// Downloads the release asset. Redirects (GitHub hands the file to its CDN) are followed only to known
/// GitHub hosts over https; no credentials are ever sent.
public enum UpdateDownloader {
    static let allowedRedirectHosts: Set<String> = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    static func isAllowedRedirect(_ u: URL?) -> Bool {
        guard let u, u.scheme == "https", u.user == nil, u.port == nil, let h = u.host?.lowercased() else { return false }
        return allowedRedirectHosts.contains(h)
    }

    private final class Guard: NSObject, URLSessionTaskDelegate {
        var hops = 0
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            hops += 1
            guard hops <= 5, UpdateDownloader.isAllowedRedirect(request.url) else { completionHandler(nil); return }
            var r = URLRequest(url: request.url!)
            r.setValue("img_to_ig-updater", forHTTPHeaderField: "User-Agent")   // nothing else is carried over
            completionHandler(r)
        }
    }

    /// Streams the file into `dir`, stopping the moment it exceeds the size the release declared.
    public static func download(_ release: ReleaseInfo, repo: String = UpdateChecker.repo, into dir: URL) async throws -> URL {
        guard UpdateChecker.isAllowedDownload(release.assetURL, repo: repo) else { throw IGPubError("下載網址不在允許範圍內") }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        let session = URLSession(configuration: cfg, delegate: Guard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: release.assetURL)
        req.setValue("img_to_ig-updater", forHTTPHeaderField: "User-Agent")
        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200, isAllowedRedirect(http.url) else {
            bytes.task.cancel()
            throw IGPubError("下載失敗，或下載來源不在允許範圍內")
        }
        if http.expectedContentLength > Int64(release.assetSize) { bytes.task.cancel(); throw IGPubError("下載的檔案比發行版宣告的大，已停止") }
        let dest = dir.appendingPathComponent("update.zip")
        try? FileManager.default.removeItem(at: dest)
        guard FileManager.default.createFile(atPath: dest.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let out = FileHandle(forWritingAtPath: dest.path) else { throw IGPubError("無法建立暫存檔") }
        defer { try? out.close() }
        var total = 0
        var buf = Data()
        buf.reserveCapacity(1 << 16)
        for try await b in bytes {
            buf.append(b)
            total += 1
            if total > release.assetSize { bytes.task.cancel(); try? FileManager.default.removeItem(at: dest); throw IGPubError("下載的檔案比發行版宣告的大，已停止") }
            if buf.count >= 1 << 16 { try out.write(contentsOf: buf); buf.removeAll(keepingCapacity: true) }
        }
        if !buf.isEmpty { try out.write(contentsOf: buf) }
        guard total == release.assetSize else {
            try? FileManager.default.removeItem(at: dest)
            throw IGPubError("下載的檔案大小和發行版不符，已丟棄")
        }
        return dest
    }
}

/// Verifies, unpacks and swaps in a downloaded update. The decisive check is the code signature: the new app
/// must satisfy the *running* app's designated requirement (same bundle id, same signing certificate).
/// The SHA-256 only catches a damaged download: it comes from the same release page as the file, so it is
/// NOT a trust anchor. Only the signature, made with a private key that never leaves the developer's Mac, is.
public enum UpdateInstaller {
    public static let appName = "img_to_ig.app"
    static let maxUnpackedBytes = 600 * 1024 * 1024

    public static func checkDigest(_ file: URL, expected: String) throws {
        guard try Files.sha256(file).lowercased() == expected.lowercased() else {
            throw IGPubError("下載的檔案和發行版的 SHA-256 不符，已丟棄")
        }
    }

    static let maxEntries = 20_000

    /// `zipinfo -t` prints "N files, M bytes uncompressed, ..." without extracting anything.
    static func checkArchiveSize(_ zip: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-t", zip.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0,
              let m = text.range(of: #"(\d+) files?, (\d+) bytes uncompressed"#, options: .regularExpression) else {
            throw IGPubError("更新檔無法檢查，已停止")
        }
        let nums = text[m].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 2, nums[0] <= maxEntries, nums[1] <= maxUnpackedBytes else {
            throw IGPubError("更新檔解壓後過大或檔案過多，已停止")
        }
    }

    /// Every symbolic link inside the bundle must stay inside it.
    static func checkLinksStayInside(_ app: URL) throws {
        let root = app.resolvingSymlinksInPath().path + "/"
        guard let e = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { continue }
            let dest = u.resolvingSymlinksInPath().path
            guard dest.hasPrefix(root) else { throw IGPubError("更新檔含有指向外部的連結，已停止") }
        }
    }

    /// Unpacks with ditto (no shell) into a fresh private directory and returns the app inside.
    public static func unpack(_ zip: URL, into dir: URL) throws -> URL {
        try checkArchiveSize(zip)
        let out = dir.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(120)
        while p.isRunning {
            if Date() > deadline || directorySize(out) > maxUnpackedBytes {      // zip bomb guard
                p.terminate()
                throw IGPubError("更新檔解壓後過大或太久，已停止")
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        guard p.terminationStatus == 0 else { throw IGPubError("更新檔無法解壓") }
        let app = try locateApp(in: out)
        try checkLinksStayInside(app)
        return app
    }

    /// Exactly one entry, named img_to_ig.app, a real directory (not a link).
    static func locateApp(in dir: URL) throws -> URL {
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            .filter { $0.lastPathComponent != "__MACOSX" }
        guard items.count == 1, items[0].lastPathComponent == appName,
              let v = try? items[0].resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              v.isSymbolicLink != true, v.isDirectory == true else { throw IGPubError("更新檔內容不符，已停止") }
        return items[0]
    }

    static func directorySize(_ dir: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total = 0
        for case let u as URL in e { total += (try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0 }
        return total
    }

    /// The text of the designated requirement of the app at `url`.
    public static func designatedRequirement(of url: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw IGPubError("讀不到 App 的簽章") }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess, let req else { throw IGPubError("讀不到 App 的簽章規則") }
        var text: CFString?
        guard SecRequirementCopyString(req, [], &text) == errSecSuccess, let text else { throw IGPubError("讀不到 App 的簽章規則") }
        return text as String
    }

    /// A requirement made of a cdhash only matches that one build, so it cannot vouch for a different build.
    public static func isAdHocRequirement(_ text: String) -> Bool { text.contains("cdhash") }

    /// Throws unless `candidate` is validly signed and satisfies `current`'s designated requirement.
    public static func verifySignature(of candidate: URL, matching current: URL) throws {
        let reqText = try designatedRequirement(of: current)
        guard !isAdHocRequirement(reqText) else {
            throw IGPubError("目前這個版本是臨時簽章，無法驗證新版是同一個開發者簽的，所以不自動更新")
        }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(reqText as CFString, [], &req) == errSecSuccess, let req else {
            throw IGPubError("簽章規則無法使用")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &code) == errSecSuccess, let code else {
            throw IGPubError("讀不到新版的簽章")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var err: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(code, flags, req, &err) == errSecSuccess else {
            throw IGPubError("新版的簽章驗證失敗（不是同一個簽章身分，或內容被改過），已停止更新")
        }
    }

    public static func bundleInfo(_ app: URL) -> (id: String?, version: String?) {
        let d = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return (d?["CFBundleIdentifier"] as? String, d?["CFBundleShortVersionString"] as? String)
    }

    /// Full verification of an unpacked app against the running one and the release it should be.
    public static func verifyCandidate(_ candidate: URL, running: URL, expectedVersion: String, currentVersion: String) throws {
        let cand = bundleInfo(candidate), cur = bundleInfo(running)
        guard let id = cand.id, id == cur.id else { throw IGPubError("新版的 App 識別碼和目前的不同，已停止更新") }
        guard cand.version == expectedVersion, Version.isNewer(expectedVersion, than: currentVersion) else {
            throw IGPubError("新版的版本號和發行版不符，或不是比較新的版本，已停止更新")
        }
        try verifySignature(of: candidate, matching: running)
    }

    /// Copies the verified app next to the running one, re-verifies the copy, then swaps it in atomically
    /// (the old app is kept as a backup by the system until the swap succeeds).
    public static func install(_ candidate: URL, over running: URL, expectedVersion: String, currentVersion: String) throws {
        let parent = running.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw IGPubError("沒有權限寫入 \(parent.path)，請手動下載更新")
        }
        let staged = parent.appendingPathComponent(".img_to_ig-update-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: candidate, to: staged)
        try verifyCandidate(staged, running: running, expectedVersion: expectedVersion, currentVersion: currentVersion)
        _ = try FileManager.default.replaceItemAt(running, withItemAt: staged)
    }
}
