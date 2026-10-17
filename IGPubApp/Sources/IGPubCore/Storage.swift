import Foundation

/// Temporary public URL for a photo: upload to an S3-compatible bucket, hand Instagram a short-lived signed GET
/// URL, delete the object afterwards.
public struct TempStorage {
    let config: AppConfig
    let accessKey: String
    let secretKey: String
    let http: HTTPClient

    public init(config: AppConfig, accessKey: String, secretKey: String, http: HTTPClient) {
        self.config = config
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.http = http
    }

    private func signed(_ method: String, _ key: String) throws -> URL {
        try config.checkStorageTransport()
        let s = try SigV4.presign(method: method, host: config.endpointHost, path: "/\(config.bucket)/\(key)",
                                  accessKey: accessKey, secretKey: secretKey, region: config.region,
                                  expires: config.urlExpiry)
        guard let u = URL(string: s) else { throw IGPubError("簽名網址無效") }
        return u
    }

    func newKey() -> String { "\(config.prefix)\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")).jpg" }

    /// Uploads without handing out a URL yet (the URL is signed later, when Instagram is about to fetch it).
    public func put(data: Data) async throws -> String {
        let key = newKey()
        let r = try await send("PUT", signed("PUT", key), body: data, headers: ["Content-Type": "image/jpeg"])
        guard [200, 201, 204].contains(r.status) else { throw Self.statusError("上傳失敗", r.status) }
        return key
    }

    /// A fresh short-lived signed GET URL for an object that is already uploaded.
    public func signedGetURL(forKey key: String) throws -> String { try signed("GET", key).absoluteString }

    /// Returns (key, signed GET url).
    public func upload(data: Data) async throws -> (key: String, url: String) {
        let key = try await put(data: data)
        return (key, try signedGetURL(forKey: key))
    }

    static func statusError(_ what: String, _ status: Int) -> IGPubError {
        switch status {
        case 401, 403:
            return IGPubError("\(what)（HTTP \(status)）：金鑰無效或沒有這個 bucket 的權限，請到步驟 4 重新存入金鑰並確認權限",
                              fix: .storage, hint: "檢查儲存空間金鑰")
        case 404:
            return IGPubError("\(what)（HTTP 404）：找不到這個 bucket，請到步驟 4 確認 bucket 名稱與 endpoint",
                              fix: .storage, hint: "檢查 bucket 名稱")
        default:
            return IGPubError("\(what)（HTTP \(status)），請到步驟 4 檢查儲存空間設定", fix: .storage, hint: "檢查儲存空間")
        }
    }

    /// Network failures never include the (signed) URL in the message.
    private func send(_ method: String, _ url: URL, body: Data?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        do { return try await http.send(method, url, body: body, headers: headers) } catch let e as IGPubError { throw e } catch {
            if (error as? URLError)?.code == .notConnectedToInternet {
                throw IGPubError("沒有網路連線，請確認網路後再試", hint: "檢查網路")
            }
            throw IGPubError("連不上儲存空間，請到步驟 4 確認 endpoint 是否正確", fix: .storage, hint: "檢查 endpoint")
        }
    }

    public func delete(_ key: String) async {
        guard let u = try? signed("DELETE", key) else { return }
        _ = try? await http.send("DELETE", u, body: nil, headers: [:])   // cleanup must not hide the real result
    }

    /// Setup check: upload a tiny object, read it back through its signed URL, delete it.
    public func selfTest() async throws {
        let payload = Data("igpub-selftest".utf8)
        let (key, url) = try await upload(data: payload)
        defer { Task { await delete(key) } }
        guard let u = URL(string: url) else { throw IGPubError("簽名網址無效") }
        let r = try await send("GET", u, body: nil, headers: [:])
        guard r.status == 200 else { throw Self.statusError("讀回測試檔失敗", r.status) }
        guard r.body == payload else { throw IGPubError("讀回測試檔內容不符，請到步驟 4 檢查儲存空間設定", fix: .storage) }
    }
}
