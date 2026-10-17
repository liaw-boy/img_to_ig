import Foundation

public struct RefreshedToken: Equatable, Sendable {
    public let token: String
    /// Seconds until expiry, as reported by Instagram (`expires_in`).
    public let expiresIn: Int?
    public init(token: String, expiresIn: Int?) {
        self.token = token
        self.expiresIn = expiresIn
    }
}

extension SecretStore {
    /// Lets callers store a refreshed token directly (keeps `secrets.set(name, try await ig.refreshToken())` working).
    public func set(_ account: String, _ value: RefreshedToken) throws { try set(account, value.token) }
}

/// Instagram Content Publishing API: container -> (wait) -> publish.
public struct InstagramClient {
    public let config: AppConfig
    let token: String
    let http: HTTPClient
    let sleep: (TimeInterval) async -> Void
    let pollSeconds: TimeInterval
    let pollTries: Int

    public init(config: AppConfig, token: String, http: HTTPClient,
                pollSeconds: TimeInterval = 60, pollTries: Int = 5,
                sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.config = config
        self.token = token
        self.http = http
        self.pollSeconds = pollSeconds
        self.pollTries = pollTries
        self.sleep = sleep
    }

    private static let formSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    static func formEncode(_ params: [(String, String)]) -> String {
        params.map {
            let k = $0.0.addingPercentEncoding(withAllowedCharacters: formSafe) ?? $0.0
            let v = $0.1.addingPercentEncoding(withAllowedCharacters: formSafe) ?? $0.1
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    func url(_ path: String, host: String? = nil) -> String {
        let v = config.apiVersion.isEmpty ? "" : "\(config.apiVersion)/"
        return "https://\(host ?? config.apiHost)/\(v)\(path)"
    }

    private func call(_ method: String, _ path: String, _ params: [(String, String)] = []) async throws -> [String: Any] {
        try config.checkAPITransport()
        let body = Self.formEncode(params + [("access_token", token)])
        var status = 0
        var payload: [String: Any] = [:]
        do {
            let r: (status: Int, body: Data)
            if method == "GET" {
                guard let u = URL(string: url(path) + "?" + body) else { throw IGPubError("bad url") }
                r = try await http.send("GET", u, body: nil, headers: [:])
            } else {
                guard let u = URL(string: url(path)) else { throw IGPubError("bad url") }
                r = try await http.send(method, u, body: Data(body.utf8),
                                        headers: ["Content-Type": "application/x-www-form-urlencoded"])
            }
            status = r.status
            if !r.body.isEmpty {
                guard let obj = try JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
                    throw IGPubError("Instagram 回應格式不符（HTTP \(status)）")
                }
                payload = obj
            }
        } catch let e as IGPubError {
            throw e
        } catch is DecodingError {
            throw IGPubError("Instagram 回應格式不符（HTTP \(status)）")
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain {
                throw IGPubError("Instagram 回應不是有效的 JSON（HTTP \(status)）")
            }
            throw IGPubError(redact("連線失敗：\(error.localizedDescription)", token))
        }
        if status >= 400 || payload["error"] != nil {
            throw Self.apiError(payload["error"] as? [String: Any] ?? [:], status: status, token: token)
        }
        return payload
    }

    private static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue ?? (v as? String).flatMap { Int($0) } }

    /// Graph API error -> plain-language message + the setup step that fixes it. The original code and
    /// (redacted) message are always kept. Codes verified against developers.facebook.com (2026-10):
    /// graph-api/guides/error-handling (102, 190, 3, 10, 200-299, 4, 17, 341, 368), graph-api/overview/rate-limiting
    /// (4, 17, 32, 613, 80002), instagram-graph-api/reference/error-codes (subcodes 2207xxx, 9, 24, 25, 36000-36004,
    /// 9004, 9007, -1, -2). Assumed, not in those tables: 100 without a known subcode usually means a wrong user id.
    static func apiError(_ err: [String: Any], status: Int, token: String, prefix: String = "Instagram 錯誤") -> IGPubError {
        let code = int(err["code"])
        let sub = int(err["error_subcode"])
        let raw = redact(String(describing: err["message"] ?? "request rejected"), token)
        let label = "\(prefix) \(code.map(String.init) ?? String(status))\(sub.map { "/\($0)" } ?? "")"
        let (text, fix, hint): (String?, SetupStep?, String?) = {
            switch (code, sub) {
            case (_, 2207052?), (9004?, _):
                return ("Instagram 抓不到照片，通常是儲存空間或簽名網址的問題，請到步驟 4 檢查儲存空間設定", .storage, "檢查儲存空間")
            case (_, 2207003?):
                return ("Instagram 下載照片逾時，請稍後再試；一直發生請到步驟 4 檢查儲存空間", .storage, "稍後再試")
            case (_, 2207042?), (9?, _):
                return ("已達 Instagram 的發文上限（每 24 小時有限額），請明天再試", nil, "明天再試")
            case (_, 2207051?):
                return ("Instagram 把這次發佈判定為疑似垃圾內容，請稍後再試，或到 Instagram App 查看帳號通知", nil, "稍後再試")
            case (4?, _), (17?, _), (32?, _), (613?, _), (341?, _), (80002?, _):
                return ("呼叫 Instagram 太頻繁，請等一段時間（約一小時）再試", nil, "稍後再試")
            case (190?, _), (102?, _):
                return ("token 無效或已過期，請到步驟 3 重新產生並存入", .meta, "重新產生 token")
            case (let c?, _) where c == 3 || c == 10 || (200...299).contains(c):
                return ("權限不足（例如沒有授權 instagram_business_content_publish），請到步驟 3 重新產生 token，產生時勾選所有發文權限",
                        .meta, "重新授權")
            case (25?, _), (_, 2207050?):
                return ("Instagram 帳號被限制或需要驗證，請用手機打開 Instagram App 完成畫面上的要求", .account, "開啟 Instagram App")
            case (_, 2207004?), (36000?, _):
                return ("照片超過 8 MB，請縮小後再發", nil, "縮小照片")
            case (_, 2207005?), (36001?, _):
                return ("Instagram 不接受這個圖片格式，請改用 JPEG", nil, nil)
            case (_, 2207009?), (36003?, _):
                return ("照片長寬比不符合 Instagram 規定（需在 4:5 到 1.91:1 之間），請裁切後再發", nil, "裁切照片")
            case (_, 2207010?), (36004?, _):
                return ("文案太長（最多 2200 字、30 個 hashtag、20 個 @）", nil, "縮短文案")
            case (_, 2207028?):
                return ("輪播需要 2～10 張", nil, nil)
            case (_, 2207020?), (_, 2207008?), (24?, _):
                return ("上傳的暫存項目已過期，請重新發佈一次", nil, "重新發佈")
            case (_, 2207001?), (_, 2207032?), (.some(-1), _), (1?, _), (2?, _):
                return ("Instagram 暫時出錯，請稍後再試", nil, "稍後再試")
            case (100?, _):
                return ("參數不正確，最常見是 Instagram user id 填錯，請到步驟 3 確認", .meta, "檢查 user id")
            default:
                return (nil, nil, nil)
            }
        }()
        guard let text else { return IGPubError("\(label)：\(raw)") }
        return IGPubError("\(label)：\(text)（原始訊息：\(raw)）", fix: fix, hint: hint)
    }

    private func id(_ payload: [String: Any]) throws -> String {
        guard let v = payload["id"] else { throw IGPubError("Instagram 回應缺少 id") }
        let s = "\(v)"
        guard s.wholeMatch(of: #/\d{1,30}/#) != nil else { throw IGPubError("Instagram 回應的 id 格式不符") }
        return s
    }

    public func account() async throws -> [String: Any] {
        try await call("GET", config.userId, [("fields", "username")])
    }

    /// The professional account's Instagram user id. `id` in this response is app-scoped; `user_id` is the one
    /// the publishing endpoints need.
    public func me() async throws -> (userId: String, username: String?) {
        let r = try await call("GET", "me", [("fields", "user_id,username")])
        let uid = r["user_id"].map { "\($0)" } ?? ""
        guard uid.wholeMatch(of: #/\d{5,25}/#) != nil else {
            throw IGPubError("Instagram 沒有回傳有效的 user id，請到步驟 3 確認 token 是用專業帳號產生的", fix: .meta,
                             hint: "檢查 token")
        }
        return (uid, r["username"] as? String)
    }

    public static let minTokenAgeForRefresh: TimeInterval = 24 * 3600

    /// Instagram only refreshes tokens at least 24 hours old.
    public static func canRefresh(savedAt: Date?, now: Date = Date()) -> Bool {
        guard let savedAt else { return true }
        return now.timeIntervalSince(savedAt) >= minTokenAgeForRefresh
    }

    public func publishingLimit() async throws -> [String: Any] {
        try await call("GET", "\(config.userId)/content_publishing_limit", [("fields", "quota_usage,config")])
    }

    public func createContainer(imageURL: String, caption: String = "", carouselItem: Bool = false,
                                options: ItemOptions = .init(), extras: PostExtras = .init()) async throws -> String {
        try options.validate()
        try extras.validate()
        var p: [(String, String)] = [("image_url", imageURL)]
        if carouselItem {
            p.append(("is_carousel_item", "true"))   // caption, collaborators and AI flag belong on the carousel itself
        } else {
            if !caption.isEmpty { p.append(("caption", caption)) }
            if let c = extras.collaboratorsJSON { p.append(("collaborators", c)) }
            if extras.aiGenerated { p.append(("is_ai_generated", "true")) }
        }
        if !options.altText.isEmpty { p.append(("alt_text", options.altText)) }
        if let t = options.userTagsJSON { p.append(("user_tags", t)) }
        return try id(await call("POST", "\(config.userId)/media", p))
    }

    public func createCarousel(children: [String], caption: String = "", extras: PostExtras = .init()) async throws -> String {
        try extras.validate()
        var p: [(String, String)] = [("media_type", "CAROUSEL"), ("children", children.joined(separator: ","))]
        if !caption.isEmpty { p.append(("caption", caption)) }
        if let c = extras.collaboratorsJSON { p.append(("collaborators", c)) }
        if extras.aiGenerated { p.append(("is_ai_generated", "true")) }
        return try id(await call("POST", "\(config.userId)/media", p))
    }

    /// Polls the container (docs suggest once a minute, at most five minutes).
    public func waitFinished(_ containerId: String) async throws {
        for attempt in 0..<pollTries {
            let r = try await call("GET", containerId, [("fields", "status_code")])
            let status = r["status_code"] as? String
            if status == "FINISHED" || status == "PUBLISHED" { return }
            if status == "ERROR" || status == "EXPIRED" { throw IGPubError("容器狀態：\(status!)") }
            if attempt + 1 < pollTries { await sleep(pollSeconds) }
        }
        throw IGPubError("容器在時限內沒有就緒")
    }

    public func publish(_ containerId: String) async throws -> String {
        try id(await call("POST", "\(config.userId)/media_publish", [("creation_id", containerId)]))
    }

    /// Instagram Login long-lived token refresh (not verified against a real account yet).
    public func refreshToken() async throws -> RefreshedToken {
        guard let u = URL(string: "https://graph.instagram.com/refresh_access_token?"
                          + Self.formEncode([("grant_type", "ig_refresh_token"), ("access_token", token)])) else {
            throw IGPubError("bad url")
        }
        let r = try await http.send("GET", u, body: nil, headers: [:])
        guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
            throw IGPubError("換發 token 的回應格式不符（HTTP \(r.status)）")
        }
        if r.status >= 400 || obj["error"] != nil {
            throw Self.apiError(obj["error"] as? [String: Any] ?? [:], status: r.status, token: token, prefix: "換發 token 失敗")
        }
        guard let t = obj["access_token"] as? String, t.count >= 6 else { throw IGPubError("回應沒有新的 token") }
        let exp = (obj["expires_in"] as? NSNumber)?.intValue ?? (obj["expires_in"] as? String).flatMap { Int($0) }
        return RefreshedToken(token: t, expiresIn: exp.flatMap { $0 > 0 ? $0 : nil })
    }
}
