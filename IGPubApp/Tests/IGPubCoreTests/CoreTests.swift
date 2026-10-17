import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import IGPubCore

final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var calls: [(method: String, url: String, body: String)] = []
    var handler: (String, URL, Data?) -> (Int, Data)
    init(_ handler: @escaping (String, URL, Data?) -> (Int, Data)) { self.handler = handler }
    func send(_ method: String, _ url: URL, body: Data?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        calls.append((method, url.absoluteString, body.map { String(decoding: $0, as: UTF8.self) } ?? ""))
        return handler(method, url, body)
    }
}

private func cfg() -> AppConfig {
    var c = AppConfig()
    c.userId = "17841400000000000"
    c.endpoint = "https://acct.r2.cloudflarestorage.com"
    c.bucket = "my-igpub-bucket"
    return c
}

private func tempJPEG(_ name: String = "a.jpg", bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let u = dir.appendingPathComponent(name)
    try Data(bytes).write(to: u)
    return u
}

final class SigV4Tests: XCTestCase {
    func testAWSDocumentationVector() throws {
        let fmt = ISO8601DateFormatter()
        let date = fmt.date(from: "2013-05-24T00:00:00Z")!
        let url = try SigV4.presign(method: "GET", host: "examplebucket.s3.amazonaws.com", path: "/test.txt",
                                    accessKey: "AKIAIOSFODNN7EXAMPLE",
                                    secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                                    region: "us-east-1", expires: 86400, now: date)
        XCTAssertTrue(url.hasSuffix("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"), url)
    }
}

final class ConfigTests: XCTestCase {
    func testValidPasses() throws { try cfg().validate() }
    func testRejectsHttpEndpoint() {
        var c = cfg(); c.endpoint = "http://x.example.com"
        XCTAssertThrowsError(try c.validate())
    }
    func testRejectsEndpointWithPathOrUser() {
        var c = cfg(); c.endpoint = "https://x.example.com/evil"
        XCTAssertThrowsError(try c.validate())
        c.endpoint = "https://u:p@x.example.com"
        XCTAssertThrowsError(try c.validate())
    }
    func testRejectsBadUserIdHostBucketPrefix() {
        var c = cfg(); c.userId = "abc"; XCTAssertThrowsError(try c.validate())
        c = cfg(); c.apiHost = "evil.example.com"; XCTAssertThrowsError(try c.validate())
        c = cfg(); c.bucket = "Bad_Bucket"; XCTAssertThrowsError(try c.validate())
        c = cfg(); c.prefix = "../x/"; XCTAssertThrowsError(try c.validate())
    }
    func testStoreRoundTripHasNoSecrets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        try store.save(cfg())
        XCTAssertEqual(store.load(), cfg())
        let text = try String(contentsOf: store.url)
        XCTAssertFalse(text.lowercased().contains("token"))
    }
}

final class FilesTests: XCTestCase {
    func testAcceptsJPEG() throws { XCTAssertNil(Files.check(try tempJPEG(), maxBytes: 1024 * 1024)) }
    func testRejectsNonJPEGContent() throws {
        XCTAssertNotNil(Files.check(try tempJPEG(bytes: [0x89, 0x50, 0x4E, 0x47]), maxBytes: 1024))
    }
    func testRejectsTooBigAndWrongSuffix() throws {
        XCTAssertNotNil(Files.check(try tempJPEG(bytes: [0xFF, 0xD8, 0xFF] + [UInt8](repeating: 0, count: 5000)), maxBytes: 1024))
        XCTAssertNotNil(Files.check(try tempJPEG("a.png"), maxBytes: 1024))
    }
    func testRejectsSymlink() throws {
        let real = try tempJPEG()
        let link = real.deletingLastPathComponent().appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertNotNil(Files.check(link, maxBytes: 1024))
    }
    func testCollectSkipsHiddenAndSorts() throws {
        let a = try tempJPEG("b.jpg")
        let dir = a.deletingLastPathComponent()
        try Data([0xFF, 0xD8, 0xFF, 1]).write(to: dir.appendingPathComponent("a.jpg"))
        try Data([0xFF, 0xD8, 0xFF, 1]).write(to: dir.appendingPathComponent(".hidden.jpg"))
        let r = Files.collect([dir], maxBytes: 1024)
        XCTAssertEqual(r.ok.map { $0.lastPathComponent }, ["a.jpg", "b.jpg"])
    }
    func testCaptionPrecedenceAndLimit() throws {
        let p = try tempJPEG()
        XCTAssertEqual(try Files.caption(for: p, explicit: nil, defaultCaption: "dflt"), "dflt")
        try "side".write(to: p.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try Files.caption(for: p, explicit: nil, defaultCaption: "dflt"), "side")
        XCTAssertEqual(try Files.caption(for: p, explicit: "x", defaultCaption: "dflt"), "x")
        XCTAssertThrowsError(try Files.caption(for: p, explicit: String(repeating: "a", count: 2201), defaultCaption: ""))
    }
}

final class LedgerTests: XCTestCase {
    func testPersistsAndReloads() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/p.json")
        let l = Ledger(url: u)
        XCTAssertFalse(l.has("abc"))
        try l.add(digest: "abc", mediaId: "M1", name: "a.jpg")
        XCTAssertTrue(Ledger(url: u).has("abc"))
        let perm = try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perm?.intValue, 0o600)
    }
}

final class ClientTests: XCTestCase {
    func okJSON(_ s: String) -> (Int, Data) { (200, Data(s.utf8)) }

    func testErrorRedactsToken() async {
        let http = FakeHTTP { _, _, _ in (400, Data(#"{"error":{"code":190,"message":"bad SECRETTOKEN123"}}"#.utf8)) }
        let ig = InstagramClient(config: cfg(), token: "SECRETTOKEN123", http: http)
        do { _ = try await ig.account(); XCTFail() } catch {
            XCTAssertFalse(error.localizedDescription.contains("SECRETTOKEN123"))
            XCTAssertTrue(error.localizedDescription.contains("190"))
        }
    }

    func testWaitFinishedPollsThenSucceeds() async throws {
        var n = 0
        let http = FakeHTTP { _, _, _ in n += 1; return self.okJSON(n < 3 ? #"{"status_code":"IN_PROGRESS"}"# : #"{"status_code":"FINISHED"}"#) }
        let ig = InstagramClient(config: cfg(), token: "tok-123456", http: http, sleep: { _ in })
        try await ig.waitFinished("C1")
        XCTAssertEqual(n, 3)
    }

    func testWaitFinishedErrorAndTimeout() async {
        let e = FakeHTTP { _, _, _ in (200, Data(#"{"status_code":"ERROR"}"#.utf8)) }
        do { try await InstagramClient(config: cfg(), token: "tok-123456", http: e, sleep: { _ in }).waitFinished("C"); XCTFail() } catch {}
        let t = FakeHTTP { _, _, _ in (200, Data(#"{"status_code":"IN_PROGRESS"}"#.utf8)) }
        do { try await InstagramClient(config: cfg(), token: "tok-123456", http: t, pollTries: 2, sleep: { _ in }).waitFinished("C"); XCTFail() } catch {}
    }
}

final class PublisherTests: XCTestCase {
    func makeHTTP() -> FakeHTTP {
        FakeHTTP { method, url, _ in
            let u = url.absoluteString
            if method == "PUT" { return (200, Data()) }
            if method == "DELETE" { return (204, Data()) }
            if u.contains("/media_publish") { return (200, Data(#"{"id":"17900000000000001"}"#.utf8)) }
            if u.contains("/media") { return (200, Data(#"{"id":"17800000000000001"}"#.utf8)) }
            return (200, Data(#"{"status_code":"FINISHED"}"#.utf8))
        }
    }

    func testSingleFlowRecordsLedgerAndDeletesObject() async throws {
        let http = makeHTTP()
        let ledgerURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/p.json")
        let ledger = Ledger(url: ledgerURL)
        let p = Publisher(ig: InstagramClient(config: cfg(), token: "tok-123456", http: http, sleep: { _ in }),
                          storage: TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http), ledger: ledger)
        let file = try tempJPEG()
        let d1 = try Files.sha256(file)
        let ids = try await p.publishSingles([PublishItem(url: file, digest: d1, caption: "hi")], log: { _ in })
        XCTAssertEqual(ids, ["17900000000000001"])
        XCTAssertTrue(ledger.has(d1))
        XCTAssertEqual(http.calls.filter { $0.method == "DELETE" }.count, 1)
        XCTAssertTrue(http.calls.contains { $0.body.contains("caption=hi") })
    }

    func testFailureStillDeletesUploadedObject() async throws {
        let http = FakeHTTP { method, url, _ in
            if method == "PUT" { return (200, Data()) }
            if method == "DELETE" { return (204, Data()) }
            return (400, Data(#"{"error":{"code":9,"message":"nope"}}"#.utf8))
        }
        let ledger = Ledger(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/p.json"))
        let p = Publisher(ig: InstagramClient(config: cfg(), token: "tok-123456", http: http, sleep: { _ in }),
                          storage: TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http), ledger: ledger)
        let f = try tempJPEG()
        let d2 = try Files.sha256(f)
        do { _ = try await p.publishSingles([PublishItem(url: f, digest: d2, caption: "")], log: { _ in }); XCTFail() } catch {}
        XCTAssertFalse(ledger.has(d2))
        XCTAssertEqual(http.calls.filter { $0.method == "DELETE" }.count, 1)
    }

    func testCarouselNeedsTwoToTen() async throws {
        let http = makeHTTP()
        let p = Publisher(ig: InstagramClient(config: cfg(), token: "tok-123456", http: http, sleep: { _ in }),
                          storage: TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http),
                          ledger: Ledger(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/p.json")))
        do { _ = try await p.publishCarousel([PublishItem(url: try tempJPEG(), digest: "x", caption: "")], caption: "", log: { _ in }); XCTFail() } catch {}
    }
}

struct ThrowingHTTP: HTTPClient {
    let error: Error
    func send(_ method: String, _ url: URL, body: Data?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        throw error
    }
}

final class ErrorMappingTests: XCTestCase {
    func igError(_ json: String, status: Int = 400) async -> IGPubError? {
        let http = FakeHTTP { _, _, _ in (status, Data(json.utf8)) }
        do { _ = try await InstagramClient(config: cfg(), token: "SECRETTOKEN123", http: http).account(); return nil } catch {
            return error as? IGPubError
        }
    }

    func testInstagramCodesMapToSteps() async {
        let cases: [(String, SetupStep?, String)] = [
            (#"{"error":{"code":190,"message":"expired SECRETTOKEN123"}}"#, .meta, "token 無效或已過期"),
            (#"{"error":{"code":10,"message":"x"}}"#, .meta, "權限不足"),
            (#"{"error":{"code":200,"message":"x"}}"#, .meta, "權限不足"),
            (#"{"error":{"code":299,"message":"x"}}"#, .meta, "權限不足"),
            (#"{"error":{"code":100,"message":"x"}}"#, .meta, "user id"),
            (#"{"error":{"code":4,"message":"x"}}"#, nil, "太頻繁"),
            (#"{"error":{"code":17,"message":"x"}}"#, nil, "太頻繁"),
            (#"{"error":{"code":32,"message":"x"}}"#, nil, "太頻繁"),
            (#"{"error":{"code":613,"message":"x"}}"#, nil, "太頻繁"),
            (#"{"error":{"code":9,"error_subcode":2207042,"message":"x"}}"#, nil, "發文上限"),
            (#"{"error":{"code":9004,"error_subcode":2207052,"message":"x"}}"#, .storage, "抓不到照片"),
            (#"{"error":{"code":"9004","message":"x"}}"#, .storage, "抓不到照片"),
            (#"{"error":{"code":-2,"error_subcode":2207003,"message":"x"}}"#, .storage, "逾時"),
            (#"{"error":{"code":100,"error_subcode":2207028,"message":"x"}}"#, nil, "2～10"),
            (#"{"error":{"code":36003,"error_subcode":2207009,"message":"x"}}"#, nil, "長寬比"),
        ]
        for (json, fix, text) in cases {
            guard let e = await igError(json) else { XCTFail(json); continue }
            XCTAssertEqual(e.fix, fix, json)
            XCTAssertTrue(e.message.contains(text), e.message)
            XCTAssertFalse(e.message.contains("SECRETTOKEN123"))
        }
        let e = await igError(#"{"error":{"code":9004,"error_subcode":2207052,"message":"orig"}}"#)
        XCTAssertTrue(e?.message.contains("9004/2207052") == true && e?.message.contains("orig") == true, e?.message ?? "")
        XCTAssertEqual(e?.hint, "檢查儲存空間")
    }

    func testUnknownCodeKeepsOriginalMessage() async {
        let e = await igError(#"{"error":{"code":12345,"message":"weird SECRETTOKEN123"}}"#)
        XCTAssertEqual(e, IGPubError("Instagram 錯誤 12345：weird ***"))
        let s = await igError("", status: 500)
        XCTAssertEqual(s?.message, "Instagram 錯誤 500：request rejected")
    }

    func testRefreshTokenUsesMapping() async {
        let http = FakeHTTP { _, _, _ in (400, Data(#"{"error":{"code":190,"message":"bad SECRETTOKEN123"}}"#.utf8)) }
        do { _ = try await InstagramClient(config: cfg(), token: "SECRETTOKEN123", http: http).refreshToken(); XCTFail() } catch {
            let e = error as? IGPubError
            XCTAssertEqual(e?.fix, .meta)
            XCTAssertTrue(e?.message.hasPrefix("換發 token 失敗 190") == true, e?.message ?? "")
            XCTAssertFalse(e?.message.contains("SECRETTOKEN123") ?? true)
        }
    }

    func storageError(_ http: HTTPClient) async -> IGPubError? {
        do { _ = try await TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http).upload(data: Data([1])); return nil } catch {
            return error as? IGPubError
        }
    }

    func testStorageStatusAndNetworkMapping() async {
        let e403 = await storageError(FakeHTTP { _, _, _ in (403, Data()) })
        XCTAssertEqual(e403?.fix, .storage)
        XCTAssertTrue(e403?.message.contains("金鑰無效或沒有這個 bucket 的權限") == true)
        let e404 = await storageError(FakeHTTP { _, _, _ in (404, Data()) })
        XCTAssertEqual(e404?.fix, .storage)
        XCTAssertTrue(e404?.message.contains("bucket") == true)
        let down = await storageError(ThrowingHTTP(error: URLError(.cannotFindHost)))
        XCTAssertEqual(down?.fix, .storage)
        XCTAssertTrue(down?.message.contains("endpoint") == true)
        XCTAssertFalse(down?.message.contains("X-Amz") ?? true)
        let offline = await storageError(ThrowingHTTP(error: URLError(.notConnectedToInternet)))
        XCTAssertNil(offline?.fix)
        XCTAssertNotNil(offline)
    }

    func testSelfTestReadBack403() async {
        let http = FakeHTTP { m, _, _ in m == "GET" ? (403, Data()) : (200, Data()) }
        do { try await TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http).selfTest(); XCTFail() } catch {
            XCTAssertEqual((error as? IGPubError)?.fix, .storage)
        }
    }

    func testValidationFixSteps() {
        func fix(_ f: (inout AppConfig) -> Void) -> SetupStep? {
            var c = cfg(); f(&c)
            do { try c.validate(); return nil } catch { return (error as? IGPubError)?.fix }
        }
        XCTAssertEqual(fix { $0.userId = "abc" }, .meta)
        XCTAssertEqual(fix { $0.apiHost = "evil.example.com" }, .meta)
        XCTAssertEqual(fix { $0.apiVersion = "23" }, .meta)
        XCTAssertEqual(fix { $0.endpoint = "http://x" }, .storage)
        XCTAssertEqual(fix { $0.bucket = "Bad_Bucket" }, .storage)
        XCTAssertEqual(fix { $0.prefix = "../x" }, .storage)
        XCTAssertEqual(fix { $0.region = "A" }, .storage)
        XCTAssertEqual(fix { $0.urlExpiry = 5 }, .storage)
    }

    func testErrorIsSourceCompatibleAndEquatable() {
        XCTAssertEqual(IGPubError("x"), IGPubError("x", fix: nil, hint: nil))
        XCTAssertNotEqual(IGPubError("x"), IGPubError("x", fix: .meta))
        XCTAssertEqual(SetupStep.storage.rawValue, 3)
    }
}

final class HardeningTests: XCTestCase {
    func testLoadRejectsTamperedConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(url: dir.appendingPathComponent("config.json"))
        try store.save(cfg())
        let perm = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perm?.intValue, 0o700)
        let text = try String(contentsOf: store.url).replacingOccurrences(of: "graph.instagram.com", with: "evil.example.com")
        try text.write(to: store.url, atomically: true, encoding: .utf8)
        XCTAssertNil(store.load())
    }

    func testRejectsNonNumericIds() async {
        for body in [#"{"id":"../evil"}"#, #"{"id":"C1"}"#, #"{"id":""}"#] {
            let http = FakeHTTP { _, _, _ in (200, Data(body.utf8)) }
            let ig = InstagramClient(config: cfg(), token: "tok-123456", http: http)
            do { _ = try await ig.publish("1"); XCTFail(body) } catch {}
        }
        let ok = FakeHTTP { _, _, _ in (200, Data(#"{"id":17841400000000001}"#.utf8)) }
        let id = try? await InstagramClient(config: cfg(), token: "tok-123456", http: ok).publish("1")
        XCTAssertEqual(id, "17841400000000001")
    }

    func testChangedFileIsNotUploaded() async throws {
        let http = PublisherTests().makeHTTP()
        let p = Publisher(ig: InstagramClient(config: cfg(), token: "tok-123456", http: http, sleep: { _ in }),
                          storage: TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http),
                          ledger: Ledger(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/p.json")))
        let f = try tempJPEG()
        let digest = try Files.sha256(f)
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 9, 9, 9]).write(to: f)
        do { _ = try await p.publishSingles([PublishItem(url: f, digest: digest, caption: "")], log: { _ in }); XCTFail() } catch {
            XCTAssertEqual((error as? IGPubError)?.message, "上傳 a.jpg 失敗：檔案在加入後被更改，請重新加入")   // says which step failed
        }
        let g = try tempJPEG()
        let items = [PublishItem(url: f, digest: digest, caption: ""), PublishItem(url: g, digest: try Files.sha256(g), caption: "")]
        do { _ = try await p.publishCarousel(items, caption: "", log: { _ in }); XCTFail() } catch {}
        XCTAssertTrue(http.calls.allSatisfy { $0.method != "PUT" })
    }
}

final class TokenAndMeTests: XCTestCase {
    func testMeUsesUserIdNotAppScopedId() async throws {
        let http = FakeHTTP { _, _, _ in (200, Data(#"{"id":"999","user_id":"17841400000000001","username":"cat"}"#.utf8)) }
        let r = try await InstagramClient(config: cfg(), token: "tok-123456", http: http).me()
        XCTAssertEqual(r.userId, "17841400000000001")
        XCTAssertEqual(r.username, "cat")
        XCTAssertTrue(http.calls[0].url.contains("/v25.0/me?fields=user_id%2Cusername"), http.calls[0].url)
        let n = FakeHTTP { _, _, _ in (200, Data(#"{"user_id":17841400000000002}"#.utf8)) }
        let r2 = try await InstagramClient(config: cfg(), token: "tok-123456", http: n).me()
        XCTAssertEqual(r2.userId, "17841400000000002")
        XCTAssertNil(r2.username)
    }

    func testMeRejectsMissingOrBadUserId() async {
        for body in [#"{"id":"17841400000000001"}"#, #"{"user_id":"abc"}"#, #"{"user_id":"123"}"#] {
            let http = FakeHTTP { _, _, _ in (200, Data(body.utf8)) }
            do { _ = try await InstagramClient(config: cfg(), token: "tok-123456", http: http).me(); XCTFail(body) } catch {
                XCTAssertEqual((error as? IGPubError)?.fix, .meta)
            }
        }
    }

    func testRefreshParsesExpiresIn() async throws {
        let http = FakeHTTP { _, _, _ in (200, Data(#"{"access_token":"NEWTOKEN123","token_type":"bearer","expires_in":5183944}"#.utf8)) }
        let r = try await InstagramClient(config: cfg(), token: "tok-123456", http: http).refreshToken()
        XCTAssertEqual(r, RefreshedToken(token: "NEWTOKEN123", expiresIn: 5183944))
        let noExp = FakeHTTP { _, _, _ in (200, Data(#"{"access_token":"NEWTOKEN123"}"#.utf8)) }
        let r2 = try await InstagramClient(config: cfg(), token: "tok-123456", http: noExp).refreshToken()
        XCTAssertNil(r2.expiresIn)
    }

    func testCanRefreshNeeds24Hours() {
        let now = Date()
        XCTAssertTrue(InstagramClient.canRefresh(savedAt: nil, now: now))
        XCTAssertFalse(InstagramClient.canRefresh(savedAt: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(InstagramClient.canRefresh(savedAt: now.addingTimeInterval(-24 * 3600), now: now))
        XCTAssertEqual(InstagramClient.minTokenAgeForRefresh, 86400)
    }

    func testDefaultsAndOldConfigDecoding() throws {
        XCTAssertEqual(AppConfig().apiVersion, "v25.0")
        var c = cfg(); c.apiVersion = ""
        XCTAssertNoThrow(try c.validate())
        let old = #"{"userId":"17841400000000000","apiHost":"graph.instagram.com","apiVersion":"","endpoint":"https://a.example.com","#
            + #""region":"auto","bucket":"my-bucket","prefix":"igpub/","urlExpiry":900,"defaultCaption":"","maxBytes":8388608,"#
            + #""tokenSavedAt":"2026-01-01T00:00:00Z"}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let a = try dec.decode(AppConfig.self, from: Data(old.utf8))
        XCTAssertEqual(a.apiVersion, "")
        XCTAssertNil(a.tokenExpiresAt)
        XCTAssertNil(a.username)
        XCTAssertNotNil(a.tokenSavedAt)
        let minimal = try dec.decode(AppConfig.self, from: Data(#"{"userId":"17841400000000000"}"#.utf8))
        XCTAssertEqual(minimal.apiVersion, "v25.0")
        XCTAssertEqual(minimal.prefix, "igpub/")
        var b = cfg(); b.tokenExpiresAt = Date(timeIntervalSince1970: 1_800_000_000)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(AppConfig.self, from: enc.encode(b)), b)
    }

    func testStoreRefreshedTokenViaSecretStore() throws {
        final class Mem: SecretStore {
            var d: [String: String] = [:]
            func get(_ a: String) -> String? { d[a] }
            func set(_ a: String, _ v: String) throws { d[a] = v }
            func delete(_ a: String) -> Bool { d[a] = nil; return true }
        }
        let m = Mem()
        try m.set(SecretName.accessToken, RefreshedToken(token: "NEWTOKEN123", expiresIn: 10))
        XCTAssertEqual(m.get(SecretName.accessToken), "NEWTOKEN123")
    }
}

final class LedgerSettingsTests: XCTestCase {
    func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/p.json") }

    func testEntriesNewestFirstAndToleratesBadRows() throws {
        let u = url()
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"published":{"a":{"media_id":"1","file":"a.jpg","at":"2026-01-01T00:00:00+00:00"},"#
            + #""b":{"media_id":"2","file":"b.jpg","at":"2026-03-01T00:00:00Z"},"c":{"media_id":3,"at":"garbage"},"#
            + #""d":"broken","e":{"file":"no-media.jpg"}},"other":1}"#
        try json.write(to: u, atomically: true, encoding: .utf8)
        let e = Ledger(url: u).entries()
        XCTAssertEqual(e.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(e[0], LedgerEntry(id: "b", mediaId: "2", name: "b.jpg", at: ISO8601DateFormatter().date(from: "2026-03-01T00:00:00Z")))
        XCTAssertNil(e[2].at)
        XCTAssertEqual(e[2].mediaId, "3")
        XCTAssertEqual(e[2].name, "")
    }

    func testClearKeepsFormatAndOtherKeys() throws {
        let u = url()
        let l = Ledger(url: u)
        try l.add(digest: "x", mediaId: "1", name: "x.jpg")
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: u)) as! [String: Any]
        obj["version"] = 1
        try JSONSerialization.data(withJSONObject: obj).write(to: u)
        l.reload()
        try l.clear()
        XCTAssertFalse(l.has("x"))
        XCTAssertTrue(l.entries().isEmpty)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: u)) as! [String: Any]
        XCTAssertEqual((after["published"] as? [String: Any])?.count, 0)
        XCTAssertEqual(after["version"] as? Int, 1)
        let perm = try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perm?.intValue, 0o600)
    }

    func testReloadSeesOtherWriters() throws {
        let u = url()
        let a = Ledger(url: u), b = Ledger(url: u)
        try a.add(digest: "d", mediaId: "1", name: "d.jpg")
        XCTAssertFalse(b.has("d"))
        b.reload()
        XCTAssertTrue(b.has("d"))
        XCTAssertEqual(b.entries().first?.name, "d.jpg")
    }

    func testConfigStoreDelete() throws {
        let store = ConfigStore(url: url().deletingLastPathComponent().appendingPathComponent("config.json"))
        XCTAssertNoThrow(try store.delete())
        try store.save(cfg())
        XCTAssertNotNil(store.load())
        try store.delete()
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }
}

final class TransportGuardTests: XCTestCase {
    func testTamperedAPIHostOrVersionSendsNothing() async {
        for tamper in [{ (c: inout AppConfig) in c.apiHost = "evil.example.com" },
                       { (c: inout AppConfig) in c.apiVersion = "../x" }] {
            var c = cfg(); tamper(&c)
            let http = FakeHTTP { _, _, _ in (200, Data(#"{"id":"1"}"#.utf8)) }
            let ig = InstagramClient(config: c, token: "tok-123456", http: http)
            do { _ = try await ig.me(); XCTFail() } catch { XCTAssertEqual((error as? IGPubError)?.fix, .meta) }
            do { _ = try await ig.createContainer(imageURL: "https://x.example.com/a.jpg"); XCTFail() } catch {}
            do { _ = try await ig.publish("1"); XCTFail() } catch {}
            XCTAssertTrue(http.calls.isEmpty)
        }
    }

    func testTamperedEndpointSendsNothing() async {
        for ep in ["http://x.example.com", "https://x.example.com/evil", "https://u:p@x.example.com", "https://x.example.com:8443"] {
            var c = cfg(); c.endpoint = ep
            let http = FakeHTTP { _, _, _ in (200, Data()) }
            let s = TempStorage(config: c, accessKey: "AK", secretKey: "SK", http: http)
            do { _ = try await s.upload(data: Data([1])); XCTFail(ep) } catch { XCTAssertEqual((error as? IGPubError)?.fix, .storage) }
            await s.delete("igpub/x.jpg")
            do { try await s.selfTest(); XCTFail(ep) } catch {}
            XCTAssertTrue(http.calls.isEmpty, ep)
        }
    }

    func testAPICheckDoesNotNeedStorage() async throws {
        var c = cfg(); c.endpoint = ""
        let http = FakeHTTP { _, _, _ in (200, Data(#"{"user_id":"17841400000000001"}"#.utf8)) }
        _ = try await InstagramClient(config: c, token: "tok-123456", http: http).me()
        XCTAssertEqual(http.calls.count, 1)
        XCTAssertNoThrow(try cfg().checkAPITransport())
        XCTAssertNoThrow(try cfg().checkStorageTransport())
    }

    func testLegacyLedgerMovesOnce() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = dir.appendingPathComponent("old/p.json"), new = dir.appendingPathComponent("new/p.json")
        try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"published":{"abc":{"media_id":"1","file":"a.jpg"}}}"#.utf8).write(to: old)
        Ledger.migrateLegacy(from: old, to: new)
        XCTAssertTrue(Ledger(url: new).has("abc"))
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        try Data(#"{"published":{"other":{}}}"#.utf8).write(to: old)
        Ledger.migrateLegacy(from: old, to: new)   // new exists: untouched
        XCTAssertFalse(Ledger(url: new).has("other"))
        XCTAssertTrue(fm.fileExists(atPath: old.path))
    }

    func testR2AccountIdToEndpointAndBack() {
        let id = String(repeating: "a1", count: 16)
        XCTAssertEqual(AppConfig.r2Endpoint(accountId: " \(id.uppercased()) "), "https://\(id).r2.cloudflarestorage.com")
        XCTAssertNil(AppConfig.r2Endpoint(accountId: "short"))
        XCTAssertNil(AppConfig.r2Endpoint(accountId: id + "x"))
        XCTAssertEqual(AppConfig.r2AccountId(endpoint: "https://\(id).r2.cloudflarestorage.com"), id)
        XCTAssertNil(AppConfig.r2AccountId(endpoint: "https://\(id).r2.cloudflarestorage.com/evil"))
        XCTAssertNil(AppConfig.r2AccountId(endpoint: "https://\(id).evil.com"))
    }

    class MemBackend: BundleBackend {
        var bundle: [String: String]?, legacy: [String: String] = [:]
        var denied = false, failWrite = false, corrupt = false, bundleReads = 0
        func bundleExists() -> Bool { bundle != nil || corrupt }
        func readBundle() -> BundleRead {
            bundleReads += 1
            if denied { return .denied }
            if corrupt { return .corrupt }
            return bundle.map { .found($0) } ?? .missing
        }
        func bundleNames() -> Set<String>? { bundle.map { Set($0.keys) } }
        func writeBundle(_ v: [String: String]) throws {
            if failWrite { throw IGPubError("write failed") }
            bundle = v
        }
        func deleteBundle() -> Bool { bundle = nil; return true }
        func readLegacy(_ a: String) -> String? { legacy[a] }
        func legacyExists(_ a: String) -> Bool { legacy[a] != nil }
        func deleteLegacy(_ a: String) -> Bool { legacy[a] = nil; return true }
    }

    func testBundleIsReadOnceForAllSecrets() throws {
        let m = MemBackend(); m.bundle = ["access_token": "t", "s3_access_key": "a", "s3_secret_key": "s"]
        let s = BundleSecretStore(m)
        XCTAssertEqual(s.get("access_token"), "t"); XCTAssertEqual(s.get("s3_access_key"), "a")
        XCTAssertEqual(s.get("s3_secret_key"), "s"); XCTAssertEqual(s.get("access_token"), "t")
        XCTAssertEqual(m.bundleReads, 1)
    }

    func testExistsDoesNotReadTheSecret() {
        let m = MemBackend(); m.bundle = ["access_token": "t"]
        let s = BundleSecretStore(m)
        XCTAssertTrue(s.exists("access_token")); XCTAssertFalse(s.exists("s3_secret_key"))
        XCTAssertEqual(m.bundleReads, 0)
    }

    func testSetKeepsOtherSecretsAndOldValueOnFailedWrite() throws {
        let m = MemBackend(); m.bundle = ["access_token": "old", "s3_access_key": "a"]
        let s = BundleSecretStore(m)
        try s.set("s3_secret_key", " new ")
        XCTAssertEqual(m.bundle?["s3_secret_key"], "new"); XCTAssertEqual(m.bundle?["access_token"], "old")
        m.failWrite = true
        XCTAssertThrowsError(try s.set("access_token", "x"))
        XCTAssertEqual(s.get("access_token"), "old")
        XCTAssertThrowsError(try s.set("access_token", "  "))
    }

    func testLegacyItemsAreMergedThenDeleted() {
        let m = MemBackend(); m.legacy = ["access_token": "t", "s3_access_key": "a"]
        let s = BundleSecretStore(m)
        XCTAssertTrue(s.exists("access_token"))          // legacy visible without reading
        XCTAssertEqual(s.get("s3_access_key"), "a")
        XCTAssertEqual(m.bundle, ["access_token": "t", "s3_access_key": "a"])
        XCTAssertTrue(m.legacy.isEmpty)
    }

    func testLegacyKeptIfBundleWriteFails() {
        let m = MemBackend(); m.legacy = ["access_token": "t"]; m.failWrite = true
        let s = BundleSecretStore(m)
        XCTAssertEqual(s.get("access_token"), "t")
        XCTAssertEqual(m.legacy["access_token"], "t")
    }

    func testDeniedIsNotTreatedAsMissingAndNotCached() throws {
        let m = MemBackend(); m.bundle = ["access_token": "t"]; m.legacy = ["access_token": "other"]; m.denied = true
        let s = BundleSecretStore(m)
        XCTAssertNil(s.get("access_token"))
        XCTAssertThrowsError(try s.set("s3_access_key", "a"))     // must not overwrite what it could not read
        XCTAssertEqual(m.bundle, ["access_token": "t"])
        m.denied = false
        XCTAssertEqual(s.get("access_token"), "t")                // asks again; legacy not used
    }

    func testUnreadableLegacyItemIsNotDeleted() {
        final class Partial: MemBackend { override func readLegacy(_ a: String) -> String? { a == "s3_access_key" ? nil : super.readLegacy(a) } }
        let m = Partial(); m.legacy = ["access_token": "t", "s3_access_key": "a"]
        let s = BundleSecretStore(m)
        XCTAssertEqual(s.get("access_token"), "t")
        XCTAssertEqual(m.bundle, ["access_token": "t"])
        XCTAssertEqual(m.legacy, ["s3_access_key": "a"])      // kept for a later attempt
    }

    func testCorruptBundleCanBeReplaced() throws {
        let m = MemBackend(); m.corrupt = true
        let s = BundleSecretStore(m)
        XCTAssertNil(s.get("access_token"))
        try s.set("access_token", "t")
        XCTAssertEqual(m.bundle, ["access_token": "t"])
    }

    func testDeleteRemovesValueAndEmptyBundle() {
        let m = MemBackend(); m.bundle = ["access_token": "t", "s3_access_key": "a"]
        let s = BundleSecretStore(m)
        XCTAssertTrue(s.delete("access_token")); XCTAssertEqual(m.bundle, ["s3_access_key": "a"])
        XCTAssertTrue(s.delete("s3_access_key")); XCTAssertNil(m.bundle)
        XCTAssertTrue(s.delete("s3_access_key"))
        XCTAssertNil(s.get("access_token"))
    }

    private func igClient(_ http: FakeHTTP) -> InstagramClient {
        InstagramClient(config: cfg(), token: "tok-123456", http: http, sleep: { _ in })
    }

    private func decodedBody(_ http: FakeHTTP) -> [String: String] {
        var out: [String: String] = [:]
        for pair in (http.calls.last?.body ?? "").split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1].removingPercentEncoding }
        }
        return out
    }

    func testCaptionKeepsHashtagsMentionsAndNewlines() async throws {
        let http = FakeHTTP { _, _, _ in (200, Data(#"{"id":"9"}"#.utf8)) }
        let caption = "木瓜山 #aviation #桃園機場\n@some.user & 50% = ok +1"
        _ = try await igClient(http).createContainer(imageURL: "https://x.example.com/a.jpg", caption: caption)
        XCTAssertEqual(decodedBody(http)["caption"], caption)
        XCTAssertFalse(http.calls.last!.body.contains("#"))      // sent percent-encoded, never as a URL fragment
    }

    func testSingleContainerCarriesAltTextTagsCollaboratorsAndAIFlag() async throws {
        let http = FakeHTTP { _, _, _ in (200, Data(#"{"id":"9"}"#.utf8)) }
        let opts = ItemOptions(altText: "一架飛機", tags: [UserTag(username: "a.b", x: 0.25, y: 0.5)])
        _ = try await igClient(http).createContainer(imageURL: "https://x.example.com/a.jpg", caption: "c", options: opts,
                                                    extras: PostExtras(collaborators: ["pal_1"], aiGenerated: true))
        let b = decodedBody(http)
        XCTAssertEqual(b["alt_text"], "一架飛機")
        XCTAssertEqual(b["user_tags"], #"[{"username":"a.b","x":0.25,"y":0.5}]"#)
        XCTAssertEqual(b["collaborators"], #"["pal_1"]"#)
        XCTAssertEqual(b["is_ai_generated"], "true")
    }

    func testCarouselChildGetsOnlyAltTextAndTags() async throws {
        let http = FakeHTTP { _, _, _ in (200, Data(#"{"id":"9"}"#.utf8)) }
        _ = try await igClient(http).createContainer(imageURL: "https://x.example.com/a.jpg", caption: "ignored", carouselItem: true,
                                                    options: ItemOptions(altText: "alt"),
                                                    extras: PostExtras(collaborators: ["x"], aiGenerated: true))
        let b = decodedBody(http)
        XCTAssertEqual(b["is_carousel_item"], "true"); XCTAssertEqual(b["alt_text"], "alt")
        XCTAssertNil(b["caption"]); XCTAssertNil(b["collaborators"]); XCTAssertNil(b["is_ai_generated"])
    }

    func testCarouselParentGetsCollaboratorsAndAIFlag() async throws {
        let http = FakeHTTP { _, _, _ in (200, Data(#"{"id":"9"}"#.utf8)) }
        _ = try await igClient(http).createCarousel(children: ["1", "2"], caption: "c",
                                                   extras: PostExtras(collaborators: ["x", "y"], aiGenerated: true))
        let b = decodedBody(http)
        XCTAssertEqual(b["collaborators"], #"["x","y"]"#); XCTAssertEqual(b["is_ai_generated"], "true")
    }

    func testInvalidOptionsAreRejectedBeforeAnyRequest() async {
        let http = FakeHTTP { _, _, _ in (200, Data(#"{"id":"9"}"#.utf8)) }
        let ig = igClient(http)
        let bad: [ItemOptions] = [
            ItemOptions(altText: String(repeating: "a", count: 1001)),
            ItemOptions(tags: [UserTag(username: "bad name", x: 0.5, y: 0.5)]),
            ItemOptions(tags: [UserTag(username: "ok", x: 1.5, y: 0.5)]),
            ItemOptions(tags: [UserTag(username: "ok", x: 0.1, y: 0.1), UserTag(username: "OK", x: 0.2, y: 0.2)]),
        ]
        for o in bad {
            do { _ = try await ig.createContainer(imageURL: "https://x.example.com/a.jpg", options: o); XCTFail() } catch {}
        }
        do { _ = try await ig.createContainer(imageURL: "https://x.example.com/a.jpg",
                                              extras: PostExtras(collaborators: ["a", "b", "c", "d"])); XCTFail() } catch {}
        XCTAssertTrue(http.calls.isEmpty)
    }

    func testUsernameParsing() {
        XCTAssertEqual(Usernames.normalize(" @some.user_1 "), "some.user_1")
        XCTAssertNil(Usernames.normalize("a b")); XCTAssertNil(Usernames.normalize("")); XCTAssertNil(Usernames.normalize("名字"))
        XCTAssertNil(Usernames.normalize(String(repeating: "a", count: 31)))
        XCTAssertEqual(Usernames.parseList("a, @b，c d"), ["a", "b", "c", "d"])
        XCTAssertNil(Usernames.parseList("a, b/c"))
    }
}

final class UpdaterTests: XCTestCase {
    private func releaseJSON(tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false,
                             assetName: String? = nil, size: Int = 1000, digest: String? = nil,
                             url: String? = nil, page: String = "https://github.com/liaw-boy/img_to_ig/releases/tag/v0.2.0") -> [String: Any] {
        let v = Version.normalized(tag) ?? "0.2.0"
        var asset: [String: Any] = ["name": assetName ?? "img_to_ig-\(v).zip", "size": size,
            "browser_download_url": url ?? "https://github.com/liaw-boy/img_to_ig/releases/download/\(tag)/img_to_ig-\(v).zip"]
        asset["digest"] = digest ?? "sha256:" + String(repeating: "ab", count: 32)
        return ["tag_name": tag, "draft": draft, "prerelease": prerelease, "html_url": page, "body": "notes", "assets": [asset]]
    }

    private func parse(_ o: [String: Any], current: String = "0.1.0") throws -> ReleaseInfo? {
        try UpdateChecker.parse(o, repo: "liaw-boy/img_to_ig", current: current)
    }

    func testVersionCompare() {
        XCTAssertTrue(Version.isNewer("0.2.0", than: "0.1.9")); XCTAssertTrue(Version.isNewer("v1.0.0", than: "0.99.99"))
        XCTAssertTrue(Version.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertFalse(Version.isNewer("0.1.0", than: "0.1.0")); XCTAssertFalse(Version.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(Version.isNewer("1.2", than: "0.1.0")); XCTAssertFalse(Version.isNewer("1.2.x", than: "0.1.0"))
        XCTAssertNil(Version.parse("1.2.3.4")); XCTAssertNil(Version.parse("a.b.c")); XCTAssertNil(Version.parse("1..3"))
    }

    func testAcceptsAValidNewerRelease() throws {
        let r = try XCTUnwrap(parse(releaseJSON()))
        XCTAssertEqual(r.version, "0.2.0"); XCTAssertEqual(r.sha256, String(repeating: "ab", count: 32))
    }

    func testIgnoresOlderSameDraftAndPrerelease() throws {
        XCTAssertNil(try parse(releaseJSON(tag: "v0.1.0")))
        XCTAssertNil(try parse(releaseJSON(tag: "v0.0.9")))
        XCTAssertNil(try parse(releaseJSON(draft: true)))
        XCTAssertNil(try parse(releaseJSON(prerelease: true)))
    }

    func testRejectsUnsafeOrIncompleteReleases() {
        let bad: [[String: Any]] = [
            releaseJSON(tag: "latest"),
            releaseJSON(assetName: "evil.zip"),
            releaseJSON(size: 0), releaseJSON(size: UpdateChecker.maxAssetBytes + 1),
            releaseJSON(digest: "md5:abc"), releaseJSON(digest: "sha256:zz"),
            releaseJSON(url: "http://github.com/liaw-boy/img_to_ig/releases/download/v0.2.0/img_to_ig-0.2.0.zip"),
            releaseJSON(url: "https://evil.example.com/liaw-boy/img_to_ig/releases/download/v0.2.0/img_to_ig-0.2.0.zip"),
            releaseJSON(url: "https://github.com/other/repo/releases/download/v0.2.0/img_to_ig-0.2.0.zip"),
            releaseJSON(url: "https://github.com/liaw-boy/img_to_ig/releases/download/../../x.zip"),
            releaseJSON(url: "https://github.com/liaw-boy/img_to_ig/releases/download/v0.2.0/img_to_ig-0.2.0.zip?x=1"),
            releaseJSON(page: "https://evil.example.com/liaw-boy/img_to_ig/"),
        ]
        for o in bad { XCTAssertThrowsError(try parse(o)) }
    }

    func testRedirectPolicy() {
        XCTAssertTrue(UpdateDownloader.isAllowedRedirect(URL(string: "https://objects.githubusercontent.com/x")))
        XCTAssertTrue(UpdateDownloader.isAllowedRedirect(URL(string: "https://release-assets.githubusercontent.com/x")))
        XCTAssertFalse(UpdateDownloader.isAllowedRedirect(URL(string: "http://objects.githubusercontent.com/x")))
        XCTAssertFalse(UpdateDownloader.isAllowedRedirect(URL(string: "https://evil.githubusercontent.com.attacker.io/x")))
        XCTAssertFalse(UpdateDownloader.isAllowedRedirect(URL(string: "https://user@github.com/x")))
        XCTAssertFalse(UpdateDownloader.isAllowedRedirect(nil))
    }

    func testCheckerOnlyAsksTheGitHubAPIAndMapsErrors() async throws {
        let ok = FakeHTTP { _, _, _ in (200, try! JSONSerialization.data(withJSONObject: self.releaseJSON())) }
        let r = try await UpdateChecker(http: ok).newerRelease(than: "0.1.0")
        XCTAssertEqual(r?.version, "0.2.0")
        XCTAssertEqual(ok.calls.first?.url, "https://api.github.com/repos/liaw-boy/img_to_ig/releases/latest")
        let none = FakeHTTP { _, _, _ in (404, Data()) }
        do { _ = try await UpdateChecker(http: none).newerRelease(than: "0.1.0"); XCTFail() } catch {}
        do { _ = try await UpdateChecker(http: ok, repo: "../evil").newerRelease(than: "0.1.0"); XCTFail() } catch {}
        XCTAssertEqual(ok.calls.count, 1)      // the bad repo name never reached the network
    }

    func testDigestMismatchIsRejected() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: u)
        let good = try Files.sha256(u)
        XCTAssertNoThrow(try UpdateInstaller.checkDigest(u, expected: good.uppercased()))
        XCTAssertThrowsError(try UpdateInstaller.checkDigest(u, expected: String(repeating: "0", count: 64)))
    }

    func testUnpackRequiresExactlyOneRealApp() throws {
        let fm = FileManager.default
        func zip(_ build: (URL) throws -> Void) throws -> URL {
            let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let src = dir.appendingPathComponent("src"); try fm.createDirectory(at: src, withIntermediateDirectories: true)
            try build(src)
            let z = dir.appendingPathComponent("a.zip")
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-c", "-k", src.path, z.path]
            try p.run(); p.waitUntilExit()
            return z
        }
        let good = try zip { try fm.createDirectory(at: $0.appendingPathComponent("img_to_ig.app/Contents"), withIntermediateDirectories: true) }
        XCTAssertNoThrow(try UpdateInstaller.unpack(good, into: good.deletingLastPathComponent().appendingPathComponent("w1")))
        let extra = try zip {
            try fm.createDirectory(at: $0.appendingPathComponent("img_to_ig.app"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: $0.appendingPathComponent("other.txt"))
        }
        XCTAssertThrowsError(try UpdateInstaller.unpack(extra, into: extra.deletingLastPathComponent().appendingPathComponent("w2")))
        let wrong = try zip { try fm.createDirectory(at: $0.appendingPathComponent("Evil.app"), withIntermediateDirectories: true) }
        XCTAssertThrowsError(try UpdateInstaller.unpack(wrong, into: wrong.deletingLastPathComponent().appendingPathComponent("w3")))
        let link = try zip { try fm.createSymbolicLink(at: $0.appendingPathComponent("img_to_ig.app"), withDestinationURL: URL(fileURLWithPath: "/Applications")) }
        XCTAssertThrowsError(try UpdateInstaller.unpack(link, into: link.deletingLastPathComponent().appendingPathComponent("w4")))
    }

    func testSignatureMustMatchTheRunningAppsRequirement() throws {
        let calc = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let notes = URL(fileURLWithPath: "/System/Applications/Notes.app")
        guard FileManager.default.fileExists(atPath: calc.path), FileManager.default.fileExists(atPath: notes.path) else {
            throw XCTSkip("system apps not available")
        }
        XCTAssertNoThrow(try UpdateInstaller.verifySignature(of: calc, matching: calc))
        XCTAssertThrowsError(try UpdateInstaller.verifySignature(of: notes, matching: calc))
        XCTAssertTrue(UpdateInstaller.isAdHocRequirement("identifier \"x\" and cdhash H\"abc\""))
        XCTAssertFalse(UpdateInstaller.isAdHocRequirement("identifier \"x\" and certificate leaf = H\"abc\""))
    }
}


final class ConfigMigrationTests: XCTestCase {
    func testConfigMovesFromOldFolderOnce() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = base.appendingPathComponent("IGPub/config.json"), new = base.appendingPathComponent("img_to_ig/config.json")
        try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: old)
        ConfigStore.migrateLegacy(from: old, to: new)
        XCTAssertTrue(fm.fileExists(atPath: new.path)); XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertFalse(fm.fileExists(atPath: old.deletingLastPathComponent().path))      // empty old folder removed
    }

    func testExistingNewConfigIsNeverOverwritten() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = base.appendingPathComponent("IGPub/config.json"), new = base.appendingPathComponent("img_to_ig/config.json")
        for u in [old, new] { try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try Data("OLD".utf8).write(to: old); try Data("NEW".utf8).write(to: new)
        ConfigStore.migrateLegacy(from: old, to: new)
        XCTAssertEqual(try String(contentsOf: new, encoding: .utf8), "NEW")
        XCTAssertTrue(fm.fileExists(atPath: old.path))
    }
}


final class ReorderTests: XCTestCase {
    struct Item: Identifiable, Equatable { let id: Int }
    private let a = (1...5).map(Item.init)
    private func ids(_ x: [Item]) -> [Int] { x.map(\.id) }

    func testMoveBeforeTarget() {
        XCTAssertEqual(ids(Reorder.move(a, 4, before: 2)), [1, 4, 2, 3, 5])
        XCTAssertEqual(ids(Reorder.move(a, 1, before: 4)), [2, 3, 1, 4, 5])
        XCTAssertEqual(ids(Reorder.move(a, 2, before: 3)), [1, 2, 3, 4, 5])      // already right before it
    }

    func testMoveToEndAndNoOps() {
        XCTAssertEqual(ids(Reorder.move(a, 2, before: nil)), [1, 3, 4, 5, 2])
        XCTAssertEqual(ids(Reorder.move(a, 3, before: 3)), [1, 2, 3, 4, 5])
        XCTAssertEqual(ids(Reorder.move(a, 99, before: 2)), [1, 2, 3, 4, 5])
        XCTAssertEqual(ids(Reorder.move(a, 2, before: 99)), [1, 3, 4, 5, 2])     // unknown target = end
    }

    func testShiftStopsAtTheEnds() {
        XCTAssertEqual(ids(Reorder.shift(a, 3, by: -1)), [1, 3, 2, 4, 5])
        XCTAssertEqual(ids(Reorder.shift(a, 3, by: 1)), [1, 2, 4, 3, 5])
        XCTAssertEqual(ids(Reorder.shift(a, 1, by: -1)), [1, 2, 3, 4, 5])
        XCTAssertEqual(ids(Reorder.shift(a, 5, by: 3)), [1, 2, 3, 4, 5])
        XCTAssertEqual(ids(Reorder.shift(a, 2, by: 10)), [1, 3, 4, 5, 2])
        XCTAssertEqual(ids(Reorder.shift([], 1, by: 1)), [])
    }
}


final class ShrinkTests: XCTestCase {
    /// A noisy JPEG (noise does not compress, so it is big): `side` x `side`, quality 1.0.
    private func noisyJPEG(side: Int) -> Data {
        var px = [UInt8](repeating: 0, count: side * side * 4)
        var g = SystemRandomNumberGenerator()
        for i in 0..<px.count { px[i] = i % 4 == 3 ? 255 : UInt8.random(in: 0...255, using: &g) }
        let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let out = NSMutableData()
        let d = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        CGImageDestinationFinalize(d)
        return out as Data
    }

    private func pixelSize(_ d: Data) -> (Int, Int) {
        let src = CGImageSourceCreateWithData(d as CFData, nil)!
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        return ((p[kCGImagePropertyPixelWidth] as! NSNumber).intValue, (p[kCGImagePropertyPixelHeight] as! NSNumber).intValue)
    }

    func testShrinksToTheLimitAndKeepsAValidJPEG() throws {
        let big = noisyJPEG(side: 1800)
        let limit = big.count / 3
        XCTAssertGreaterThan(big.count, limit)
        let small = try ImageShrinker.shrink(big, toAtMost: limit)
        XCTAssertLessThanOrEqual(small.count, limit)
        XCTAssertTrue(small.starts(with: [0xFF, 0xD8, 0xFF]))
        let (w, h) = pixelSize(small)
        XCTAssertLessThanOrEqual(max(w, h), 1800)           // never enlarged
        XCTAssertEqual(Double(w) / Double(h), 1.0, accuracy: 0.01)
    }

    func testGentleStepKeepsTheFullSizeWhenQualityIsEnough() throws {
        let big = noisyJPEG(side: 1200)
        let small = try ImageShrinker.shrink(big, toAtMost: Int(Double(big.count) * 0.9))
        XCTAssertEqual(pixelSize(small).0, 1200)
    }

    func testImpossibleLimitAndGarbageThrow() {
        XCTAssertThrowsError(try ImageShrinker.shrink(noisyJPEG(side: 600), toAtMost: 500))
        XCTAssertThrowsError(try ImageShrinker.shrink(Data("not an image".utf8), toAtMost: 1000))
    }

    func testPublisherUploadsAShrunkCopyAndLeavesTheOriginalAlone() async throws {
        let big = noisyJPEG(side: 1500)
        let url = try tempJPEG(bytes: [UInt8](big))
        var c = cfg(); c.maxBytes = max(1024, big.count / 3)
        let http = FakeHTTP { _, _, _ in (200, Data()) }
        let p = Publisher(ig: InstagramClient(config: c, token: "tok-123456", http: http, sleep: { _ in }),
                          storage: TempStorage(config: c, accessKey: "AK", secretKey: "SK", http: http),
                          ledger: Ledger(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/p.json")),
                          shrinkOversize: true)
        let item = PublishItem(url: url, digest: Files.sha256(big), caption: "")
        let data = try p.verifiedData(item)
        XCTAssertLessThanOrEqual(data.count, c.maxBytes)
        XCTAssertEqual(try Data(contentsOf: url).count, big.count)        // original untouched
        let tampered = PublishItem(url: url, digest: String(repeating: "0", count: 64), caption: "")
        XCTAssertThrowsError(try p.verifiedData(tampered))                // hash of the ORIGINAL is still enforced
    }

    func testOversizePhotoIsUploadedUntouchedByDefault() throws {
        let big = noisyJPEG(side: 1500)
        let url = try tempJPEG(bytes: [UInt8](big))
        var c = cfg(); c.maxBytes = max(1024, big.count / 3)
        let http = FakeHTTP { _, _, _ in (200, Data()) }
        let p = Publisher(ig: InstagramClient(config: c, token: "tok-123456", http: http, sleep: { _ in }),
                          storage: TempStorage(config: c, accessKey: "AK", secretKey: "SK", http: http),
                          ledger: Ledger(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/p.json")))
        XCTAssertEqual(try p.verifiedData(PublishItem(url: url, digest: Files.sha256(big), caption: "")), big)   // best quality: not re-encoded
    }
}

final class FailureReportingTests: XCTestCase {
    func testMetaExplanationAndTraceIdAreKept() {
        let e = InstagramClient.apiError(["code": 110, "error_subcode": 2207018, "message": "Invalid user id",
                                          "error_user_title": "標題", "error_user_msg": "說明文字", "fbtrace_id": "AbC123"],
                                         status: 400, token: "tok-123456")
        XCTAssertTrue(e.message.contains("Invalid user id"))
        XCTAssertTrue(e.message.contains("標題：說明文字"))
        XCTAssertTrue(e.message.contains("追蹤碼 AbC123"))
        XCTAssertTrue(e.message.contains("110/2207018"))
    }

    func testPollingStartsFastAndBacksOffToTheCap() async throws {
        var slept: [TimeInterval] = []
        let http = FakeHTTP { _, _, _ in (200, Data(#"{"status_code":"IN_PROGRESS"}"#.utf8)) }
        let ig = InstagramClient(config: cfg(), token: "tok-123456", http: http, pollSeconds: 60, pollTries: 12,
                                 sleep: { slept.append($0) })
        do { try await ig.waitFinished("123"); XCTFail() } catch {}
        XCTAssertEqual(slept.first!, 2, accuracy: 0.001)
        XCTAssertEqual(slept[1], 3, accuracy: 0.001)
        XCTAssertEqual(slept.last!, 60, accuracy: 0.001)             // never above the documented once-a-minute
        XCTAssertTrue(zip(slept, slept.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertLessThan(slept.reduce(0, +), 600)
    }

    func testMultiPhotoPostKeepsOrderUploadsInParallelAndCleansUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var items: [PublishItem] = []
        for n in 1...5 {
            let u = dir.appendingPathComponent("p\(n).jpg")
            let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, UInt8(n), 2, 3]
            try Data(bytes).write(to: u)
            items.append(PublishItem(url: u, digest: Files.sha256(Data(bytes)), caption: ""))
        }
        let lock = NSLock(); var childForUpload: [String: String] = [:]; var next = 0; var puts = 0, deletes = 0
        var childrenParam = ""
        let http = FakeHTTP { method, url, body in
            lock.lock(); defer { lock.unlock() }
            let u = url.absoluteString, b = body.map { String(decoding: $0, as: UTF8.self) } ?? ""
            if method == "PUT" { puts += 1; return (200, Data()) }
            if method == "DELETE" { deletes += 1; return (204, Data()) }
            if u.hasSuffix("/media_publish") { return (200, Data(#"{"id":"900"}"#.utf8)) }
            if u.contains("/media") {
                if b.contains("is_carousel_item") {
                    next += 1
                    let image = b.components(separatedBy: "&").first { $0.hasPrefix("image_url=") } ?? ""
                    childForUpload[image] = "\(100 + next)"
                    return (200, Data("{\"id\":\"\(100 + next)\"}".utf8))
                }
                childrenParam = b.components(separatedBy: "&").first { $0.hasPrefix("children=") } ?? ""
                return (200, Data(#"{"id":"500"}"#.utf8))
            }
            return (200, Data(#"{"status_code":"FINISHED"}"#.utf8))
        }
        let p = Publisher(ig: InstagramClient(config: cfg(), token: "tok-123456", http: http, sleep: { _ in }),
                          storage: TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http),
                          ledger: Ledger(url: dir.appendingPathComponent("l.json")))
        let media = try await p.publishCarousel(items, caption: "c", log: { _ in })
        XCTAssertEqual(media, "900")
        XCTAssertEqual(puts, 5); XCTAssertEqual(deletes, 5)                  // every temporary file removed
        let ids = childrenParam.dropFirst("children=".count).removingPercentEncoding!.split(separator: ",").map(String.init)
        XCTAssertEqual(ids.count, 5); XCTAssertEqual(Set(ids).count, 5)
        XCTAssertTrue(Ledger(url: dir.appendingPathComponent("l.json")).has(items[0].digest))
    }

    func testFailureNamesTheStepAndStillDeletesUploads() async throws {
        let f = try tempJPEG(); let g = try tempJPEG("b.jpg")
        let items = [PublishItem(url: f, digest: try Files.sha256(f), caption: ""), PublishItem(url: g, digest: try Files.sha256(g), caption: "")]
        let lock = NSLock(); var deletes = 0
        let http = FakeHTTP { method, url, _ in
            lock.lock(); defer { lock.unlock() }
            if method == "PUT" { return (200, Data()) }
            if method == "DELETE" { deletes += 1; return (204, Data()) }
            if url.absoluteString.contains("/media") {
                return (400, Data(#"{"error":{"message":"Invalid user id","code":110,"error_subcode":2207018}}"#.utf8))
            }
            return (200, Data())
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let p = Publisher(ig: InstagramClient(config: cfg(), token: "tok-123456", http: http, sleep: { _ in }),
                          storage: TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http),
                          ledger: Ledger(url: dir.appendingPathComponent("l.json")))
        do { _ = try await p.publishCarousel(items, caption: "", log: { _ in }); XCTFail() } catch {
            let m = (error as? IGPubError)?.message ?? ""
            XCTAssertTrue(m.hasPrefix("建立 "), m); XCTAssertTrue(m.contains("失敗：Instagram 錯誤 110/2207018"), m)
        }
        XCTAssertGreaterThan(deletes, 0)
        XCTAssertFalse(Ledger(url: dir.appendingPathComponent("l.json")).has(items[0].digest))
    }
}


final class StagingTests: XCTestCase {
    private func photo(_ n: UInt8) throws -> PublishItem {
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, n, 2, 3]
        let u = try tempJPEG("s\(n).jpg", bytes: bytes)
        return PublishItem(url: u, digest: Files.sha256(Data(bytes)), caption: "")
    }

    private final class Counter: @unchecked Sendable {
        let lock = NSLock(); var puts = 0, deletes = 0, gets = 0
        func bump(_ k: String) { lock.lock(); if k == "PUT" { puts += 1 } else if k == "DELETE" { deletes += 1 } else { gets += 1 }; lock.unlock() }
    }

    func testStagedPhotoIsUploadedOnceAndReusedByThePublisher() async throws {
        let c = Counter()
        let http = FakeHTTP { method, url, _ in
            c.bump(method)
            if method == "PUT" { return (200, Data()) }
            if method == "DELETE" { return (204, Data()) }
            if url.absoluteString.hasSuffix("/media_publish") { return (200, Data(#"{"id":"900"}"#.utf8)) }
            if url.absoluteString.contains("/media") { return (200, Data(#"{"id":"500"}"#.utf8)) }
            return (200, Data(#"{"status_code":"FINISHED"}"#.utf8))
        }
        let storage = TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http)
        let item = try photo(1)
        let stager = UploadStager(storage: storage, prepare: { try Publisher.prepareBytes($0, maxBytes: 8 << 20, shrinkOversize: false) })
        await stager.stage(item); await stager.stage(item)                      // second call is a no-op
        XCTAssertEqual(c.puts, 1)
        let st = await stager.state(of: item.digest); XCTAssertEqual(st, .ready)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let p = Publisher(ig: InstagramClient(config: cfg(), token: "tok-123456", http: http, sleep: { _ in }), storage: storage,
                          ledger: Ledger(url: dir.appendingPathComponent("l.json")), stager: stager)
        _ = try await p.publishSingles([item], log: { _ in })
        XCTAssertEqual(c.puts, 1)                    // publishing did not upload again
        XCTAssertEqual(c.deletes, 1)                 // and the staged copy was removed afterwards
        let left = await stager.staged; XCTAssertTrue(left.isEmpty)
    }

    func testUnstagedPhotoIsStillUploadedAtPublishTime() async throws {
        let c = Counter()
        let http = FakeHTTP { method, url, _ in
            c.bump(method)
            if method == "PUT" { return (200, Data()) }
            if method == "DELETE" { return (204, Data()) }
            if url.absoluteString.hasSuffix("/media_publish") { return (200, Data(#"{"id":"900"}"#.utf8)) }
            if url.absoluteString.contains("/media") { return (200, Data(#"{"id":"500"}"#.utf8)) }
            return (200, Data(#"{"status_code":"FINISHED"}"#.utf8))
        }
        let storage = TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http)
        let stager = UploadStager(storage: storage, prepare: { try Publisher.prepareBytes($0, maxBytes: 8 << 20, shrinkOversize: false) })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let p = Publisher(ig: InstagramClient(config: cfg(), token: "tok-123456", http: http, sleep: { _ in }), storage: storage,
                          ledger: Ledger(url: dir.appendingPathComponent("l.json")), stager: stager)
        _ = try await p.publishSingles([try photo(2)], log: { _ in })
        XCTAssertEqual(c.puts, 1); XCTAssertEqual(c.deletes, 1)
    }

    func testDiscardDeletesTheStagedObject() async throws {
        let c = Counter()
        let http = FakeHTTP { method, _, _ in c.bump(method); return (200, Data()) }
        let storage = TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http)
        let a = try photo(3), b = try photo(4)
        let stager = UploadStager(storage: storage, prepare: { try Publisher.prepareBytes($0, maxBytes: 8 << 20, shrinkOversize: false) })
        await stager.stage(a); await stager.stage(b)
        await stager.discard([a.digest])
        XCTAssertEqual(c.deletes, 1)
        let left = await stager.staged; XCTAssertEqual(left, [b.digest])
        await stager.discardAll(); XCTAssertEqual(c.deletes, 2)
    }

    func testFailedUploadIsReportedAndNotKept() async throws {
        let http = FakeHTTP { method, _, _ in method == "PUT" ? (403, Data()) : (200, Data()) }
        let storage = TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http)
        let a = try photo(5)
        let stager = UploadStager(storage: storage, prepare: { try Publisher.prepareBytes($0, maxBytes: 8 << 20, shrinkOversize: false) })
        await stager.stage(a)
        if case .failed = await stager.state(of: a.digest) {} else { XCTFail("expected a failure") }
        let taken = await stager.take(a.digest); XCTAssertNil(taken)
    }

    func testKeysChangedAreReportedForLeftoverCleanup() async throws {
        let http = FakeHTTP { _, _, _ in (200, Data()) }
        let storage = TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http)
        final class Seen: @unchecked Sendable { var last: [String] = []; let l = NSLock() }
        let seen = Seen()
        let stager = UploadStager(storage: storage, prepare: { try Publisher.prepareBytes($0, maxBytes: 8 << 20, shrinkOversize: false) },
                                  onChange: { seen.l.lock(); seen.last = $0; seen.l.unlock() })
        let a = try photo(6)
        await stager.stage(a)
        XCTAssertEqual(seen.last.count, 1)
        _ = await stager.take(a.digest)
        XCTAssertTrue(seen.last.isEmpty)
    }

    func testOnlyKeysShapedLikeOursAreEverDeleted() {
        let prefix = "igpub/"
        let good = prefix + String(repeating: "ab12", count: 8) + ".jpg"
        XCTAssertTrue(StagingKeys.isOwn(good, prefix: prefix))
        for bad in ["", "other/" + String(repeating: "a", count: 32) + ".jpg", prefix + "../secret.jpg", prefix + "photo.jpg",
                    prefix + String(repeating: "g", count: 32) + ".jpg", prefix + String(repeating: "a", count: 31) + ".jpg",
                    prefix + String(repeating: "a", count: 32) + ".png", good + "/x"] {
            XCTAssertFalse(StagingKeys.isOwn(bad, prefix: prefix), bad)
        }
    }

    func testPrivateAccountErrorIsExplainedInPlainLanguage() {
        let e = InstagramClient.apiError(["code": 110, "error_subcode": 2207018, "message": "Invalid user id",
                                          "error_user_msg": "無法存取以下用戶：someone"], status: 400, token: "tok-123456")
        XCTAssertTrue(e.message.contains("私人帳號"))
        XCTAssertTrue(e.message.contains("someone"))      // Instagram's own text with the account name is kept
    }
}


final class AuditFollowUpTests: XCTestCase {
    func testSignedUrlsNeverAppearInErrorText() {
        let signed = "https://acct.r2.cloudflarestorage.com/b/igpub/abc.jpg?X-Amz-Credential=AKIAEXAMPLE%2F20261017&X-Amz-Signature=deadbeef"
        let e = InstagramClient.apiError(["code": 9004, "message": "Could not fetch \(signed)", "error_user_msg": "bad: \(signed)"],
                                         status: 400, token: "tok-123456")
        XCTAssertFalse(e.message.contains("X-Amz"), e.message)
        XCTAssertFalse(e.message.contains("AKIAEXAMPLE"), e.message)
        XCTAssertTrue(e.message.contains("<網址>"))
    }

    func testAPublishedPostIsNeverReportedAsFailedBecauseTheLedgerCouldNotBeWritten() async throws {
        let f = try tempJPEG()
        let http = FakeHTTP { method, url, _ in
            if method == "PUT" { return (200, Data()) }
            if method == "DELETE" { return (204, Data()) }
            if url.absoluteString.hasSuffix("/media_publish") { return (200, Data(#"{"id":"900"}"#.utf8)) }
            if url.absoluteString.contains("/media") { return (200, Data(#"{"id":"500"}"#.utf8)) }
            return (200, Data(#"{"status_code":"FINISHED"}"#.utf8))
        }
        // The ledger lives under a regular FILE, so writing it must fail.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: blocker)
        let p = Publisher(ig: InstagramClient(config: cfg(), token: "tok-123456", http: http, sleep: { _ in }),
                          storage: TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http),
                          ledger: Ledger(url: blocker.appendingPathComponent("p.json")))
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        var lines: [String] = []
        let ids = try await p.publishSingles([PublishItem(url: f, digest: try Files.sha256(f), caption: "")], log: { lines.append($0) })
        XCTAssertEqual(ids, ["900"])                                       // success is reported
        XCTAssertTrue(lines.contains { $0.hasPrefix("警告") })              // with a warning, so nobody posts it twice
    }

    func testDiscardRightAfterStageNeverLeavesAnObjectBehind() async throws {
        let lock = NSLock(); var puts = 0, deletes = 0
        let http = FakeHTTP { method, _, _ in
            lock.lock(); defer { lock.unlock() }
            if method == "PUT" { puts += 1 } else if method == "DELETE" { deletes += 1 }
            return (200, Data())
        }
        let storage = TempStorage(config: cfg(), accessKey: "AK", secretKey: "SK", http: http)
        let f = try tempJPEG()
        let item = PublishItem(url: f, digest: try Files.sha256(f), caption: "")
        for _ in 0..<20 {
            let stager = UploadStager(storage: storage, prepare: { try Publisher.prepareBytes($0, maxBytes: 8 << 20, shrinkOversize: false) })
            async let staging: Void = stager.stage(item)
            await stager.discard([item.digest])
            await staging
            await stager.discardAll()
            let left = await stager.staged
            XCTAssertTrue(left.isEmpty)
        }
        XCTAssertEqual(puts, deletes, "every uploaded object must have been deleted")
    }
}
