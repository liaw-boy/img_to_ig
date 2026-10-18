import Foundation
import AppKit
import ImageIO
import IGPubCore

struct PhotoItem: Identifiable {
    let id = UUID()
    let url: URL
    let digest: String
    var caption: String
    var selected: Bool
    var alreadyPublished: Bool
    let thumbnail: NSImage?
    var bytes: Int = 0
    var captionFile: String?   // name of the sibling .txt the caption came from
    var options = ItemOptions()          // alt text and tagged people
    var collaboratorsText = ""           // singles only; a carousel has its own
    var aiGenerated = false              // singles only

    /// Width / height of the photo as displayed (thumbnails keep the orientation).
    var aspect: Double {
        guard let s = thumbnail?.size, s.width > 0, s.height > 0 else { return 1 }
        return Double(s.width / s.height)
    }

    var extras: PostExtras? {
        Usernames.parseList(collaboratorsText).map { PostExtras(collaborators: $0, aiGenerated: aiGenerated) }
    }
}

private let stagedKeysDefaultsKey = "stagedKeys"

/// The three pages of publishing, shown in the sidebar.
enum FlowStep: Int, CaseIterable, Identifiable {
    case select, edit, send
    var id: Int { rawValue }
    var title: String { ["選擇圖片", "編輯內容", "發佈"][rawValue] }
}

enum UpdateState: Equatable {
    case idle, checking
    case upToDate
    case available(ReleaseInfo)
    case downloading, installing
    case failed(String, ReleaseInfo?)
}

/// One row of the connection test.
struct StepLine: Identifiable {
    let id = UUID()
    let ok: Bool?          // nil = running
    let title: String
    var detail: String?
    var account: String?   // shown monospaced after the detail
    var fix: SetupStep?
}

/// Stages of publishing one photo, as shown by the progress panel's chips.
enum PublishStage: Int, CaseIterable, Comparable {
    case upload, create, wait, publish, cleanup
    var label: String {
        switch self {
        case .upload: return "上傳"
        case .create: return "建立貼文"
        case .wait: return "等待處理"
        case .publish: return "發佈"
        case .cleanup: return "清除暫存"
        }
    }
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

enum ItemProgress: Equatable {
    case pending
    case running(PublishStage)
    case ready      // carousel child uploaded and processed, waiting for the others
    case done
    case failed
    case notPublished
}

struct ProgressRow: Identifiable {
    let id = UUID()
    let name: String
    var state: ItemProgress = .pending
}

enum PublishMode: String, CaseIterable, Identifiable {
    case singles = "單張"
    case carousel = "多張"
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    static let tokenLifetimeDays = 60
    static let remindDays = 10
    static let maxPerRunRange = 1...25
    static let maxMB = 8   // Instagram's JPEG limit

    private let secrets: SecretStore = KeychainStore()
    private let store = ConfigStore()
    private let ledger = Ledger()
    private let defaults = UserDefaults.standard

    // setup
    @Published var draft: AppConfig { didSet { persistDraft() } }
    @Published var step = 0
    @Published var doneSteps: Set<Int> { didSet { defaults.set(Array(doneSteps), forKey: "doneSteps") } }
    @Published var secretPresent: [String: Bool] = [:]
    @Published var testLines: [StepLine] = []
    @Published var testing = false
    @Published var showSetup: Bool

    // publish
    @Published var config: AppConfig?
    @Published var items: [PhotoItem] = []
    @Published var mode: PublishMode = .singles
    @Published var flow: FlowStep = .select
    /// Upload state of each selected photo's temporary copy, by content digest (uploaded while editing).
    @Published var stagedState: [String: UploadStager.State] = [:]
    private var stager: UploadStager?
    private var stagerFingerprint = ""
    private var stagingGeneration = 0
    @Published var carouselCaption = ""
    @Published var carouselCollaboratorsText = ""
    @Published var carouselAI = false
    @Published var busy = false
    @Published var log: [String] = []
    @Published var skipped: [String] = []
    @Published var quota: String?
    @Published var errorText: String?
    /// The last core error (carries `fix` / `hint` for the "回到步驟 N 修正" button).
    @Published var lastError: IGPubError?
    @Published var progress: [ProgressRow] = []
    @Published var progressFinished = false
    @Published var history: [LedgerEntry] = []

    // preferences (UserDefaults)
    @Published var showKeychainNotice = false
    private var keychainNoticeContinuation: CheckedContinuation<Void, Never>?
    @Published var updateState: UpdateState = .idle
    /// The update window over the main window (opened when a check finds a newer version, or from the notification).
    @Published var showUpdateSheet = false
    /// Photos over the size limit: false = upload the original untouched (best quality; Instagram may refuse it).
    @Published var autoShrink: Bool {
        didSet {
            defaults.set(autoShrink, forKey: "autoShrink")
            Task { await dropStaging() }          // the staged copies were made under the old setting
        }
    }
    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    @Published var remindExpiry: Bool { didSet { defaults.set(remindExpiry, forKey: "remindExpiry") } }
    @Published var defaultMode: PublishMode { didSet { defaults.set(defaultMode.rawValue, forKey: "defaultMode") } }
    @Published var maxPerRun: Int {
        didSet {
            let c = min(max(maxPerRun, Self.maxPerRunRange.lowerBound), Self.maxPerRunRange.upperBound)
            if c != maxPerRun { maxPerRun = c; return }
            defaults.set(maxPerRun, forKey: "maxPerRun")
        }
    }

    init() {
        let saved = store.load()
        config = saved
        if let d = defaults.data(forKey: "draft"), let dd = try? JSONDecoder().decode(AppConfig.self, from: d) {
            draft = Self.sanitized(dd)
        } else {
            draft = saved ?? AppConfig()
        }
        doneSteps = Set((defaults.array(forKey: "doneSteps") as? [Int]) ?? [])
        remindExpiry = defaults.object(forKey: "remindExpiry") as? Bool ?? true
        autoCheckUpdates = defaults.object(forKey: "autoCheckUpdates") as? Bool ?? true
        autoShrink = defaults.object(forKey: "autoShrink") as? Bool ?? false
        let dm = defaults.string(forKey: "defaultMode").flatMap(PublishMode.init(rawValue:)) ?? .singles
        defaultMode = dm
        let mpr = defaults.integer(forKey: "maxPerRun")
        maxPerRun = Self.maxPerRunRange.contains(mpr) ? mpr : 10
        mode = dm
        showSetup = true
        refreshSecrets()
        showSetup = !isReady
    }

    var isReady: Bool {
        config != nil && SecretNames.all.allSatisfy { secretPresent[$0] == true }
    }

    var tokenAgeDays: Int? {
        guard let d = config?.tokenSavedAt else { return nil }
        return Calendar.current.dateComponents([.day], from: d, to: Date()).day
    }

    /// Days until the token expires: from Instagram's `expires_in` when known, else 60 minus its age.
    var tokenDaysLeft: Int? {
        if let e = config?.tokenExpiresAt {
            return max(0, Int((e.timeIntervalSinceNow / 86_400).rounded(.down)))
        }
        return tokenAgeDays.map { max(0, Self.tokenLifetimeDays - $0) }
    }

    /// Show the expiry warning (only when the user asked to be reminded).
    var tokenWarn: Bool { remindExpiry && (tokenDaysLeft ?? Int.max) <= Self.remindDays }

    /// Instagram refuses to refresh tokens younger than 24 hours.
    var canRefreshToken: Bool {
        config != nil && secretPresent[SecretName.accessToken] == true
            && InstagramClient.canRefresh(savedAt: config?.tokenSavedAt)
    }

    var refreshHelp: String {
        if config == nil || secretPresent[SecretName.accessToken] != true { return "要先完成設定並存入 token" }
        return canRefreshToken ? "向 Instagram 換一個新的 token，有效期重新計算"
                               : "token 存入未滿 24 小時，Instagram 還不允許換發"
    }

    private func persistDraft() {
        if let d = try? JSONEncoder().encode(draft) { defaults.set(d, forKey: "draft") }
    }

    func refreshSecrets() {
        for n in SecretNames.all { secretPresent[n] = secrets.exists(n) }
    }

    // MARK: setup

    private func setError(_ error: Error?) {
        errorText = error?.localizedDescription
        lastError = error as? IGPubError
    }

    /// Opens the wizard at the step that fixes an error.
    func goFix(_ step: SetupStep) {
        self.step = step.rawValue
        errorText = nil
        lastError = nil
        showSetup = true
    }

    /// True when the API host is whitelisted and the version is empty or vNN.N (the token is only sent there).
    static func apiTargetValid(_ c: AppConfig) -> Bool {
        AppConfig.apiHosts.contains(c.apiHost) && (c.apiVersion.isEmpty || c.apiVersion.wholeMatch(of: #/v\d{1,2}\.\d/#) != nil)
    }

    /// A draft read back from UserDefaults is untrusted: reset the API target if it was tampered with.
    static func sanitized(_ d: AppConfig) -> AppConfig {
        guard !apiTargetValid(d) else { return d }
        var c = d
        let def = AppConfig()
        c.apiHost = def.apiHost
        c.apiVersion = def.apiVersion
        return c
    }

    /// Inline validation for one field, using the core's own rules: every other field is set to a known-valid
    /// value, so an error that names `fix` can only come from the field under test.
    static func fieldError(_ fix: SetupStep, _ apply: (inout AppConfig) -> Void) -> String? {
        var c = AppConfig()
        c.userId = "17841400000000000"
        c.endpoint = "https://example.r2.cloudflarestorage.com"
        c.bucket = "my-igpub-bucket"
        apply(&c)
        do {
            try c.validate()
            return nil
        } catch let e as IGPubError {
            return e.fix == fix ? e.message : nil
        } catch {
            return error.localizedDescription
        }
    }

    func saveSecret(_ name: String, _ value: String) {
        do {
            try secrets.set(name, value)
            if name == SecretName.accessToken {
                let now = Date()
                draft.tokenSavedAt = now
                draft.tokenExpiresAt = nil
                if var c = config {
                    c.tokenSavedAt = now
                    c.tokenExpiresAt = nil
                    try store.save(c)
                    config = c
                }
            }
            setError(nil)
        } catch {
            setError(error)
        }
        refreshSecrets()
    }

    func removeSecret(_ name: String) {
        secrets.delete(name)
        refreshSecrets()
    }

    func runTest() async {
        await prepareKeychainAccess()
        guard !testing else { return }
        testing = true
        testLines = []
        lastError = nil
        defer { testing = false }
        func pass(_ title: String, _ detail: String? = nil, account: String? = nil) {
            testLines.append(StepLine(ok: true, title: title, detail: detail, account: account))
        }
        func fail(_ title: String, _ error: Error? = nil, fix: SetupStep? = nil) {
            let e = error as? IGPubError
            lastError = e
            testLines.append(StepLine(ok: false, title: title, detail: e?.hint, fix: e?.fix ?? fix))
        }
        guard let token = secrets.get(SecretName.accessToken) else {
            fail("尚未存入 Instagram token", fix: .meta); return
        }
        guard let ak = secrets.get(SecretName.s3AccessKey), let sk = secrets.get(SecretName.s3SecretKey) else {
            fail("尚未存入儲存空間金鑰", fix: .storage); return
        }
        guard Self.apiTargetValid(draft) else {
            fail("API 主機或版本設定不合法，已停止測試", fix: .meta); return
        }
        let http = URLSessionHTTP()
        do {
            // user_id from /me is the id the publishing endpoints need; fill it in instead of asking the user.
            let me = try await InstagramClient(config: draft, token: token, http: http).me()
            draft.userId = me.userId
            draft.username = me.username
            pass("Instagram 帳號", "已連上", account: "@\(me.username ?? "?") · \(me.userId)")
        } catch {
            fail("Instagram：\(error.localizedDescription)", error)
            return
        }
        do {
            try draft.validate()
            pass("設定格式", "所有欄位都正確")
        } catch {
            fail("設定格式：\(error.localizedDescription)", error)
            return
        }
        let cfg = draft
        do {
            try await TempStorage(config: draft, accessKey: ak, secretKey: sk, http: http).selfTest()
            pass("儲存空間", "上傳、讀回、刪除測試檔成功")
        } catch {
            fail("儲存空間：\(error.localizedDescription)", error)
            return
        }
        do {
            try store.save(cfg)
            config = cfg
            pass("設定已儲存", "可以開始發佈")
        } catch {
            fail(error.localizedDescription, error)
        }
    }

    func finishSetup() {
        showSetup = false
        Task { await refreshQuota() }
    }

    // MARK: publish

    func refreshQuota() async {
        guard !Self.smokeTest else { return }
        await prepareKeychainAccess()
        guard let cfg = config, let token = secrets.get(SecretName.accessToken) else { return }
        let ig = InstagramClient(config: cfg, token: token, http: URLSessionHTTP())
        guard let r = try? await ig.publishingLimit(), let first = (r["data"] as? [[String: Any]])?.first else {
            quota = nil
            return
        }
        let used = first["quota_usage"].map { "\($0)" } ?? "?"
        let total = ((first["config"] as? [String: Any])?["quota_total"]).map { "\($0)" } ?? "?"
        quota = "24 小時內已發佈 \(used) / \(total)"
    }

    func add(urls: [URL]) {
        guard let cfg = config else { return }
        let (ok, bad) = Files.collect(urls, maxBytes: max(cfg.maxBytes, AppConfig.maxSourceBytes))
        skipped = bad.map { "\($0.0.lastPathComponent)：\($0.1)" }
        for u in ok where !items.contains(where: { $0.url == u }) {
            guard let digest = try? Files.sha256(u) else { continue }
            let cap = (try? Files.caption(for: u, explicit: nil, defaultCaption: cfg.defaultCaption)) ?? ""
            let done = ledger.has(digest)
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let txt = u.deletingPathExtension().appendingPathExtension("txt")
            let fromFile = !cap.isEmpty && FileManager.default.fileExists(atPath: txt.path) ? txt.lastPathComponent : nil
            items.append(PhotoItem(url: u, digest: digest, caption: cap, selected: !done,
                                   alreadyPublished: done, thumbnail: Self.thumbnail(u), bytes: size,
                                   captionFile: fromFile))
        }
    }

    nonisolated static func thumbnail(_ url: URL, maxPixel: Int = 240) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    private var lastTapped: UUID?

    /// Click toggles one photo; Shift-click selects every photo between the last click and this one.
    func tapItem(_ id: UUID, extend: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if extend, let last = lastTapped, let j = items.firstIndex(where: { $0.id == last }) {
            for k in min(i, j)...max(i, j) { items[k].selected = true }
        } else {
            items[i].selected.toggle()
        }
        lastTapped = id
    }

    func moveItem(_ id: UUID, before target: UUID?) { items = Reorder.move(items, id, before: target) }
    func shiftItem(_ id: UUID, by offset: Int) { items = Reorder.shift(items, id, by: offset) }

    var chosen: [PhotoItem] { items.filter { $0.selected } }

    var publishProblem: String? {
        let n = chosen.count
        if n == 0 { return "請至少勾選一張照片" }
        if mode == .carousel, !(2...10).contains(n) { return "Instagram API 限制：一則多張貼文只能放 2～10 張，目前勾選 \(n) 張" }
        if mode == .singles, n > maxPerRun { return "單次最多 \(maxPerRun) 則，目前勾選 \(n) 張" }
        if mode == .carousel, carouselCaption.count > AppConfig.maxCaption { return "文案超過 2200 字" }
        if mode == .singles, chosen.contains(where: { $0.caption.count > AppConfig.maxCaption }) {
            return "有文案超過 2200 字"
        }
        for p in chosen {
            do { try p.options.validate() } catch { return "\(p.url.lastPathComponent)：\(error.localizedDescription)" }
        }
        if mode == .carousel {
            guard let c = Usernames.parseList(carouselCollaboratorsText) else { return "合作夥伴的帳號格式不對" }
            do { try PostExtras(collaborators: c).validate() } catch { return error.localizedDescription }
        } else {
            for p in chosen {
                guard let e = p.extras else { return "\(p.url.lastPathComponent)：合作夥伴的帳號格式不對" }
                do { try e.validate() } catch { return "\(p.url.lastPathComponent)：\(error.localizedDescription)" }
            }
        }
        return nil
    }

    func publish() async {
        await prepareKeychainAccess()
        guard !busy, publishProblem == nil, let cfg = config,
              let token = secrets.get(SecretName.accessToken),
              let ak = secrets.get(SecretName.s3AccessKey), let sk = secrets.get(SecretName.s3SecretKey) else { return }
        busy = true
        setError(nil)
        log = []
        defer { busy = false }
        let http = URLSessionHTTP()
        let pub = Publisher(ig: InstagramClient(config: cfg, token: token, http: http),
                            storage: TempStorage(config: cfg, accessKey: ak, secretKey: sk, http: http),
                            ledger: ledger, shrinkOversize: autoShrink, stager: await validStager())
        let picked = chosen
        let carousel = mode == .carousel
        progress = picked.map { ProgressRow(name: $0.url.lastPathComponent) }
        progressFinished = false
        // The publisher's log callback may run off the main actor; an AsyncStream keeps the lines in order.
        let (stream, cont) = AsyncStream<String>.makeStream()
        let consumer = Task { @MainActor in
            var lines: [String] = []
            for await line in stream {
                lines.append(line)
                self.track(line, carousel: carousel)
            }
            return lines
        }
        let sink: (String) -> Void = { cont.yield($0) }
        var failure: Error?
        do {
            let pubItems = picked.map {
                PublishItem(url: $0.url, digest: $0.digest, caption: $0.caption.trimmingCharacters(in: .whitespacesAndNewlines),
                            options: $0.options, extras: carousel ? PostExtras() : ($0.extras ?? PostExtras()))
            }
            if carousel {
                let extras = PostExtras(collaborators: Usernames.parseList(carouselCollaboratorsText) ?? [], aiGenerated: carouselAI)
                _ = try await pub.publishCarousel(pubItems, caption: carouselCaption.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  extras: extras, log: sink)
            } else {
                _ = try await pub.publishSingles(pubItems, log: sink)
            }
        } catch {
            failure = error
        }
        cont.finish()
        log = await consumer.value
        if let failure {
            for i in progress.indices {
                switch progress[i].state {
                case .running, .ready: progress[i].state = .failed
                case .pending: progress[i].state = .notPublished
                default: break
                }
            }
            setError(failure)
            // Singles: photos that already went out must not be posted again by pressing Publish once more.
            ledger.reload()
            var already = 0
            for i in items.indices where ledger.has(items[i].digest) && !items[i].alreadyPublished {
                items[i].alreadyPublished = true
                items[i].selected = false
                already += 1
            }
            if already > 0 {
                errorText = (errorText ?? "") + "\n已有 \(already) 張成功發佈，已自動取消勾選，再按發佈不會重複發這幾張。"
            }
        } else {
            for i in progress.indices { progress[i].state = .done }
            let digests = Set(picked.map { $0.digest })
            items.removeAll { digests.contains($0.digest) }
            for d in digests { stagedState[d] = nil }
        }
        progressFinished = true
        await refreshQuota()
    }

    /// Maps the publisher's log lines onto per-photo progress. Each "上傳 …" line starts the next photo.
    private func track(_ line: String, carousel: Bool) {
        if carousel {
            // Photos are prepared a few at a time, so rows are matched by file name rather than by order.
            func row(_ name: String, _ state: ItemProgress) {
                if let i = progress.firstIndex(where: { $0.name == name && $0.state != .done }) { progress[i].state = state }
            }
            if line.hasPrefix("上傳 "), line.hasSuffix("…") { row(String(line.dropFirst(3).dropLast()), .running(.upload)) }
            else if line.hasPrefix("就緒 ") { row(String(line.dropFirst(3)), .ready) }
            else if line.hasPrefix("已發佈") { for i in progress.indices { progress[i].state = .done } }
            return
        }
        let current = progress.firstIndex { if case .running = $0.state { return true }; return false }
        if line.hasPrefix("上傳") {
            if let c = current { progress[c].state = .done }
            if let next = progress.firstIndex(where: { $0.state == .pending }) { progress[next].state = .running(.upload) }
        } else if line.hasPrefix("等待"), let c = current {
            progress[c].state = .running(.wait)
        } else if line.hasPrefix("已發佈"), let c = current {
            progress[c].state = .done
        }
    }

    func clearProgress() {
        progress = []
        progressFinished = false
    }

    func refreshToken() async {
        await prepareKeychainAccess()
        guard canRefreshToken, let cfg = config, let token = secrets.get(SecretName.accessToken) else { return }
        do {
            let new = try await InstagramClient(config: cfg, token: token, http: URLSessionHTTP()).refreshToken()
            try secrets.set(SecretName.accessToken, new.token)
            let now = Date()
            var c = cfg
            c.tokenSavedAt = now
            c.tokenExpiresAt = new.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
            try store.save(c)
            config = c
            draft.tokenSavedAt = c.tokenSavedAt
            draft.tokenExpiresAt = c.tokenExpiresAt
            log = ["已換發 token，有效期重新計算"]
            setError(nil)
        } catch {
            setError(error)
        }
    }

    // MARK: settings

    /// Saves publishing defaults (validated by ConfigStore).
    func saveConfig(_ c: AppConfig) -> String? {
        do {
            try store.save(c)
            config = c
            draft.defaultCaption = c.defaultCaption
            draft.maxBytes = c.maxBytes
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func reloadHistory() {
        ledger.reload()
        history = ledger.entries()
    }

    func clearHistory() -> String? {
        do {
            try ledger.clear()
            reloadHistory()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Deletes Keychain items, config.json and app preferences (and optionally the shared ledger), then returns to
    /// the wizard. Returns an error message if something could not be removed.
    func removeAllData(clearLedger: Bool) -> String? {
        Task { await dropStaging() }          // best effort: delete the temporary copies while the keys are still in memory
        var problems: [String] = []
        var stillThere: [String] = []
        for n in SecretNames.all where !secrets.delete(n) && secrets.get(n) != nil { stillThere.append(n) }
        do { try store.delete() } catch { problems.append("設定檔：\(error.localizedDescription)") }
        if clearLedger, let e = clearHistory() { problems.append("發佈紀錄：\(e)") }
        config = nil
        draft = AppConfig()
        doneSteps = []
        step = 0
        items = []
        testLines = []
        quota = nil
        clearProgress()
        for k in ["draft", "doneSteps", IconStyle.key, "remindExpiry", "defaultMode", "maxPerRun", "autoCheckUpdates", "lastUpdateCheck", "keychainNoticeSeen", "autoShrink"] {
            defaults.removeObject(forKey: k)
        }
        remindExpiry = true
        defaultMode = .singles
        mode = .singles
        refreshSecrets()
        for n in SecretNames.all where secretPresent[n] == true && !stillThere.contains(n) { stillThere.append(n) }
        if !stillThere.isEmpty { problems.append("鑰匙圈項目沒有刪除成功：\(stillThere.joined(separator: "、"))") }
        setError(nil)
        showSetup = true
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    // MARK: flow + staging

    func canGo(_ s: FlowStep) -> Bool {
        guard !busy else { return false }
        switch s {
        case .select: return true
        case .edit: return !chosen.isEmpty
        case .send: return !chosen.isEmpty && publishProblem == nil
        }
    }

    func go(_ s: FlowStep) {
        guard canGo(s) else { return }
        flow = s
        if s != .select { Task { await syncStaging() } }
    }

    var stagedReady: Int { chosen.filter { stagedState[$0.digest] == .ready }.count }
    var stagedFailed: Int { chosen.filter { if case .failed = stagedState[$0.digest] { return true }; return false }.count }

    func clearItems() {
        let digests = Set(items.map(\.digest))
        items = []
        Task { await discardStaged(digests) }
    }


    /// Objects of a previous session that never got used (the app quit in between) are deleted first.
    /// Only keys of the exact shape this app creates are touched, whatever is stored.
    private func removeLeftovers(_ storage: TempStorage, config: AppConfig) async {
        let old = defaults.stringArray(forKey: stagedKeysDefaultsKey) ?? []
        defaults.removeObject(forKey: stagedKeysDefaultsKey)
        for k in old where StagingKeys.isOwn(k, prefix: config.prefix) { await storage.delete(k) }
    }

    /// Identifies the storage the staged copies live in; any change (bucket, endpoint, prefix, keys, size limit) invalidates them.
    private func fingerprint(_ cfg: AppConfig, _ ak: String) -> String {
        [cfg.endpoint, cfg.bucket, cfg.prefix, cfg.region, String(cfg.maxBytes), ak].joined(separator: "\u{1}")
    }

    /// The stager, only if it still matches the current storage settings (otherwise it is dropped).
    private func validStager() async -> UploadStager? {
        guard let s = stager else { return nil }
        guard let cfg = config, let ak = secrets.get(SecretName.s3AccessKey), fingerprint(cfg, ak) == stagerFingerprint else {
            await dropStaging(); return nil
        }
        return s
    }

    private func makeStager() async -> UploadStager? {
        if let s = await validStager() { return s }
        guard !Self.smokeTest, let cfg = config,
              let ak = secrets.get(SecretName.s3AccessKey), let sk = secrets.get(SecretName.s3SecretKey) else { return nil }
        let storage = TempStorage(config: cfg, accessKey: ak, secretKey: sk, http: URLSessionHTTP())
        await removeLeftovers(storage, config: cfg)
        let shrink = autoShrink, limit = cfg.maxBytes
        nonisolated(unsafe) let d = defaults        // UserDefaults is thread-safe
        let s = UploadStager(storage: storage,
                             prepare: { try Publisher.prepareBytes($0, maxBytes: limit, shrinkOversize: shrink) },
                             onChange: { keys in d.set(keys, forKey: stagedKeysDefaultsKey) })
        stager = s
        stagerFingerprint = fingerprint(cfg, ak)
        return s
    }

    /// Uploads the selected photos (a few at a time) and removes copies of photos that are no longer selected.
    func syncStaging() async {
        await prepareKeychainAccess()
        guard let s = await makeStager() else { return }
        stagingGeneration += 1
        let generation = stagingGeneration
        let items = chosen.map { PublishItem(url: $0.url, digest: $0.digest, caption: "") }
        let want = Set(items.map(\.digest))
        await discardStaged(await s.staged.subtracting(want))
        for it in items where stagedState[it.digest] != .ready { stagedState[it.digest] = .uploading }
        await withTaskGroup(of: Void.self) { group in
            var started = 0
            func next() {
                guard started < items.count else { return }
                let it = items[started]; started += 1
                group.addTask {
                    await s.stage(it)
                    let st = await s.state(of: it.digest)
                    await MainActor.run { if let st { self.stagedState[it.digest] = st } }
                }
            }
            for _ in 0..<min(Publisher.parallelPhotos, items.count) { next() }
            while await group.next() != nil {
                if generation != self.stagingGeneration { group.cancelAll() }
                next()
            }
        }
    }

    private func discardStaged(_ digests: Set<String>) async {
        guard !digests.isEmpty else { return }
        for d in digests { stagedState[d] = nil }
        await stager?.discard(digests)
    }

    private func dropStaging() async {
        stagingGeneration += 1
        await stager?.discardAll()
        stager = nil
        stagerFingerprint = ""
        stagedState = [:]
    }

    // MARK: keychain notice

    /// Before the first read of the stored secrets, tell the user which Keychain item macOS is about to ask about.
    /// Shown once (and from Settings any time); the system prompts follow right after.
    /// Set by scripts/verify.sh so the launch test never touches the Keychain or the network.
    static let smokeTest = ProcessInfo.processInfo.environment["IMG_TO_IG_SMOKE_TEST"] == "1"

    func prepareKeychainAccess() async {
        guard !Self.smokeTest else { return }
        guard !defaults.bool(forKey: "keychainNoticeSeen"),
              SecretNames.all.contains(where: { secretPresent[$0] == true }) else { return }
        showKeychainNotice = true
        await withCheckedContinuation { keychainNoticeContinuation = $0 }
    }

    func acknowledgeKeychainNotice() {
        defaults.set(true, forKey: "keychainNoticeSeen")
        showKeychainNotice = false
        keychainNoticeContinuation?.resume()
        keychainNoticeContinuation = nil
    }

    // MARK: updates

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }

    /// Checks at most once a day, and only when the user left automatic checks on.
    func autoCheckIfDue() async {
        guard !Self.smokeTest else { return }
        guard autoCheckUpdates, updateState == .idle else { return }
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        await checkForUpdates(manual: false)
    }

    func checkForUpdates(manual: Bool) async {
        switch updateState { case .checking, .downloading, .installing: return; default: break }
        updateState = .checking
        defaults.set(Date(), forKey: "lastUpdateCheck")
        do {
            if let r = try await UpdateChecker(http: URLSessionHTTP()).newerRelease(than: currentVersion) {
                updateState = .available(r)
                showUpdateSheet = true
                if !manual { await UpdateNotifier.shared.post(version: r.version, current: currentVersion) }
            } else {
                updateState = manual ? .upToDate : .idle
            }
        } catch {
            updateState = manual ? .failed(error.localizedDescription, nil) : .idle   // a silent check never nags
        }
    }

    func installUpdate() async {
        guard case .available(let release) = updateState, !busy else { return }
        let running = Bundle.main.bundleURL
        guard running.pathExtension == "app" else {
            updateState = .failed("只有打包好的 App 能自動更新", release); return
        }
        let current = currentVersion
        updateState = .downloading
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("img_to_ig-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let zip = try await UpdateDownloader.download(release, into: work)
            updateState = .installing
            try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.checkDigest(zip, expected: release.sha256)
                let app = try UpdateInstaller.unpack(zip, into: work)
                try UpdateInstaller.verifyCandidate(app, running: running, expectedVersion: release.version, currentVersion: current)
                try UpdateInstaller.install(app, over: running, expectedVersion: release.version, currentVersion: current)
            }.value
        } catch {
            updateState = .failed(error.localizedDescription, release)
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: running, configuration: cfg) { _, error in
            DispatchQueue.main.async {
                if error == nil {
                    // An open sheet keeps NSApp.terminate from quitting, which would leave the old version running.
                    self.showUpdateSheet = false
                    NSApp.windows.forEach { w in w.attachedSheet.map { w.endSheet($0) } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }   // already installed; never linger
                } else { self.updateState = .failed("已更新到 \(release.version)，但自動重新開啟失敗，請手動重新開啟 img_to_ig", nil) }
            }
        }
    }

    /// Removes identifying data from an error message before it leaves the app.
    static func scrub(_ text: String, _ c: AppConfig) -> String {
        let text = text.replacing(#/https?:\/\/[^\s"')]+/#, with: "<網址>")
        var t = redact(text, c.userId, c.bucket, c.endpointHost)
        t = t.replacing(#/\d{8,}/#, with: "…")
        t = t.replacing(#/[^\s/\\:：；，。、！？「」（）()"']+\.(?i:jpe?g)/#, with: "<file>.jpg")
        return t
    }

    /// Plain-text diagnostics. Never includes tokens, keys, the endpoint or bucket.
    func diagnostics() -> String {
        let info = Bundle.main.infoDictionary
        var lines = ["img_to_ig 診斷資訊",
                     "產生時間：\(ISO8601DateFormatter().string(from: Date()))",
                     "App 版本：\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
                     "macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)"]
        if let c = config {
            lines.append("已儲存設定：有")
            lines.append("設定檢查：" + ((try? c.validate()) != nil ? "通過" : "未通過"))
            lines.append("API 主機：\(c.apiHost)")
            lines.append("API 版本：\(c.apiVersion.isEmpty ? "（未指定）" : c.apiVersion)")
            lines.append("檔案大小上限：\(c.maxBytes / 1024 / 1024) MB")
            lines.append("token 已使用天數：\(tokenAgeDays.map(String.init) ?? "未知")")
            lines.append("token 剩餘天數：\(tokenDaysLeft.map(String.init) ?? "未知")")
        } else {
            lines.append("已儲存設定：無")
            var e = "通過"
            do { try draft.validate() } catch { e = "未通過：\(error.localizedDescription)" }
            lines.append("草稿設定檢查：\(e)")
        }
        for n in SecretNames.all { lines.append("鑰匙圈 \(n)：\(secretPresent[n] == true ? "有" : "無")") }
        lines.append("最近的錯誤：\(Self.scrub(lastError?.message ?? errorText ?? "無", config ?? draft))")
        return lines.joined(separator: "\n") + "\n"
    }

}

enum SecretNames {
    static let all = [SecretName.accessToken, SecretName.s3AccessKey, SecretName.s3SecretKey]
}
