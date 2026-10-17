import Foundation

/// Setup wizard step that fixes an error (raw values match the wizard's step indices).
public enum SetupStep: Int, Equatable, Sendable {
    case intro = 0, account = 1, meta = 2, storage = 3, test = 4
}

public struct IGPubError: Error, LocalizedError, Equatable {
    public let message: String
    public let fix: SetupStep?
    public let hint: String?
    public init(_ message: String, fix: SetupStep? = nil, hint: String? = nil) {
        self.message = message
        self.fix = fix
        self.hint = hint
    }
    public var errorDescription: String? { message }
}

/// Non-secret settings. Tokens and keys live in the Keychain only (see SecretStore).
public struct AppConfig: Codable, Equatable {
    public var userId = ""
    public var apiHost = "graph.instagram.com"
    public var apiVersion = "v25.0"
    public var endpoint = ""
    public var region = "auto"
    public var bucket = ""
    public var prefix = "igpub/"
    public var urlExpiry = 900
    public var defaultCaption = ""
    public var maxBytes = 8 * 1024 * 1024
    public var username: String?
    public var tokenSavedAt: Date?
    public var tokenExpiresAt: Date?

    public init() {}

    /// Tolerates missing keys so config.json files from older versions still load (missing -> default).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        userId = try c.decodeIfPresent(String.self, forKey: .userId) ?? d.userId
        apiHost = try c.decodeIfPresent(String.self, forKey: .apiHost) ?? d.apiHost
        apiVersion = try c.decodeIfPresent(String.self, forKey: .apiVersion) ?? d.apiVersion
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? d.endpoint
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? d.region
        bucket = try c.decodeIfPresent(String.self, forKey: .bucket) ?? d.bucket
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? d.prefix
        urlExpiry = try c.decodeIfPresent(Int.self, forKey: .urlExpiry) ?? d.urlExpiry
        defaultCaption = try c.decodeIfPresent(String.self, forKey: .defaultCaption) ?? d.defaultCaption
        maxBytes = try c.decodeIfPresent(Int.self, forKey: .maxBytes) ?? d.maxBytes
        username = try c.decodeIfPresent(String.self, forKey: .username)
        tokenSavedAt = try c.decodeIfPresent(Date.self, forKey: .tokenSavedAt)
        tokenExpiresAt = try c.decodeIfPresent(Date.self, forKey: .tokenExpiresAt)
    }

    public static let apiHosts: Set<String> = ["graph.instagram.com", "graph.facebook.com"]
    public static let maxCaption = 2200

    /// Cloudflare R2 account ids are 32 hex characters.
    public static func isR2AccountId(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    /// "https://<id>.r2.cloudflarestorage.com" for a bare account id; nil if it is not one.
    public static func r2Endpoint(accountId: String) -> String? {
        let id = accountId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isR2AccountId(id) ? "https://\(id).r2.cloudflarestorage.com" : nil
    }

    /// The account id if `endpoint` is exactly an R2 endpoint, else nil.
    public static func r2AccountId(endpoint: String) -> String? {
        guard let u = URLComponents(string: endpoint), u.scheme == "https", let host = u.host,
              host.hasSuffix(".r2.cloudflarestorage.com"), (u.path.isEmpty || u.path == "/") else { return nil }
        let id = String(host.dropLast(".r2.cloudflarestorage.com".count))
        return isR2AccountId(id) ? id : nil
    }

    public var endpointHost: String { URLComponents(string: endpoint)?.host ?? "" }

    /// Where the token may be sent. Checked before every Instagram request, whatever the config's origin.
    public func checkAPITransport() throws {
        if !Self.apiHosts.contains(apiHost) {
            throw IGPubError("API 主機必須是 graph.instagram.com 或 graph.facebook.com", fix: .meta)
        }
        if !apiVersion.isEmpty, apiVersion.wholeMatch(of: #/v\d{1,2}\.\d/#) == nil {
            throw IGPubError("API 版本格式應為 v23.0，或留空", fix: .meta)
        }
    }

    /// Where photos and signed requests may be sent. Checked before every storage request.
    public func checkStorageTransport() throws {
        guard let u = URLComponents(string: endpoint), u.scheme == "https", let host = u.host, !host.isEmpty,
              u.path.isEmpty || u.path == "/", u.user == nil, u.query == nil, u.port == nil else {
            throw IGPubError("儲存空間 endpoint 必須是 https://主機名稱 的格式", fix: .storage)
        }
    }

    /// Same rules as the Python tool's config.py.
    public func validate() throws {
        if userId.wholeMatch(of: #/\d{5,25}/#) == nil {
            throw IGPubError("Instagram user id 必須是 5～25 位數字", fix: .meta)
        }
        try checkAPITransport()
        try checkStorageTransport()
        if bucket.wholeMatch(of: #/[a-z0-9][a-z0-9.\-]{1,61}[a-z0-9]/#) == nil {
            throw IGPubError("bucket 名稱不合法（3～63 個小寫英數、點、連字號）", fix: .storage)
        }
        if prefix.wholeMatch(of: #/[A-Za-z0-9_\-\/]{0,60}/#) == nil || prefix.contains("..") || prefix.hasPrefix("/") {
            throw IGPubError("prefix 只能包含英數、底線、連字號、斜線", fix: .storage)
        }
        if region.wholeMatch(of: #/[a-z0-9\-]{2,30}/#) == nil {
            throw IGPubError("region 不合法（R2 請填 auto）", fix: .storage)
        }
        if !(60...3600).contains(urlExpiry) { throw IGPubError("簽名網址有效秒數必須在 60～3600", fix: .storage) }
        if defaultCaption.count > Self.maxCaption { throw IGPubError("預設文案超過 2200 字") }
        if !(1024...(100 * 1024 * 1024)).contains(maxBytes) { throw IGPubError("檔案大小上限超出範圍") }
    }
}

/// Persists AppConfig as JSON under Application Support (no secrets).
public struct ConfigStore {
    public let url: URL

    public init(url: URL = ConfigStore.defaultURL) {
        self.url = url
        if url == ConfigStore.defaultURL { Self.migrateLegacy(from: Self.legacyURL, to: url) }
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("img_to_ig/config.json")
    }

    static var legacyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IGPub/config.json")
    }

    /// One-time move from the old folder name: atomic copy, then remove the old file (and its folder if now empty).
    static func migrateLegacy(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path),
              (try? fm.attributesOfItem(atPath: old.path)[.type] as? FileAttributeType) == .typeRegular else { return }
        let dir = new.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".config-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try fm.copyItem(at: old, to: tmp)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            try fm.moveItem(at: tmp, to: new)
            try fm.removeItem(at: old)
            let oldDir = old.deletingLastPathComponent()
            if (try? fm.contentsOfDirectory(atPath: oldDir.path))?.isEmpty == true { try? fm.removeItem(at: oldDir) }
        } catch {
            try? fm.removeItem(at: tmp)
        }
    }

    public func load() -> AppConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        // Re-validate: a tampered file must not point apiHost (and the token) elsewhere.
        guard let cfg = try? dec.decode(AppConfig.self, from: data), (try? cfg.validate()) != nil else { return nil }
        return cfg
    }

    /// Removes config.json; a missing file is not an error.
    public func delete() throws {
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
    }

    public func save(_ cfg: AppConfig) throws {
        try cfg.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(cfg).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
