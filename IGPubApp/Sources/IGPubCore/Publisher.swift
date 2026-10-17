import Foundation

public struct PublishItem {
    public let url: URL
    public let digest: String
    public let caption: String
    public let options: ItemOptions
    public let extras: PostExtras      // singles: this post's collaborators/AI flag (ignored in a carousel)
    public init(url: URL, digest: String, caption: String, options: ItemOptions = .init(), extras: PostExtras = .init()) {
        self.url = url
        self.digest = digest
        self.caption = caption
        self.options = options
        self.extras = extras
    }
}

/// Collects the storage keys uploaded by concurrent tasks so they can all be deleted afterwards.
final class KeyBox: @unchecked Sendable {
    private var keys: [String] = []
    private let lock = NSLock()
    func add(_ k: String) { lock.lock(); keys.append(k); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return keys }
}

/// Orchestrates upload -> container -> wait -> publish -> ledger -> cleanup. Stops at the first error and always
/// deletes whatever is still in the bucket. Every error says which step of which photo failed.
public struct Publisher {
    /// How many photos of a multi-photo post are uploaded and processed at the same time.
    public static let parallelPhotos = 3

    let ig: InstagramClient
    let storage: TempStorage
    let ledger: Ledger
    /// Over the size limit: false = upload the original untouched (Instagram may refuse it), true = upload a shrunk copy.
    let shrinkOversize: Bool
    /// Photos uploaded ahead of time while the user was editing; used instead of uploading again.
    let stager: UploadStager?

    public init(ig: InstagramClient, storage: TempStorage, ledger: Ledger, shrinkOversize: Bool = false, stager: UploadStager? = nil) {
        self.ig = ig
        self.storage = storage
        self.ledger = ledger
        self.shrinkOversize = shrinkOversize
        self.stager = stager
    }

    /// The photo as an object in the storage with a fresh signed URL: the one staged earlier, or uploaded now.
    private func objectFor(_ item: PublishItem) async throws -> (key: String, url: String) {
        if let stager, let key = await stager.take(item.digest) {
            do { return (key, try storage.signedGetURL(forKey: key)) }
            catch { await storage.delete(key); throw error }      // we own it now: never leave it behind
        }
        return try await storage.upload(data: verifiedData(item))
    }

    /// Re-checks the file (it must still be the one the user added), and returns the bytes to upload: the original,
    /// or a shrunk copy when it is over the limit and shrinking is on. The original file is never modified.
    public func verifiedData(_ item: PublishItem) throws -> Data {
        try Self.prepareBytes(item, maxBytes: storage.config.maxBytes, shrinkOversize: shrinkOversize)
    }

    public static func prepareBytes(_ item: PublishItem, maxBytes: Int, shrinkOversize: Bool) throws -> Data {
        if let why = Files.check(item.url, maxBytes: AppConfig.maxSourceBytes) {
            throw IGPubError("\(item.url.lastPathComponent)：\(why)")
        }
        let data = try Data(contentsOf: item.url)
        guard data.count <= AppConfig.maxSourceBytes, data.starts(with: [0xFF, 0xD8, 0xFF]),
              Files.sha256(data) == item.digest else { throw IGPubError("檔案在加入後被更改，請重新加入") }
        if data.count <= maxBytes || !shrinkOversize { return data }
        do { return try ImageShrinker.shrink(data, toAtMost: maxBytes) }
        catch { throw IGPubError("\(item.url.lastPathComponent)：\(error.localizedDescription)") }
    }

    /// Cheap check of every photo before anything is uploaded or published: still the same file the user added.
    private func preflight(_ items: [PublishItem]) throws {
        for item in items {
            let name = item.url.lastPathComponent
            if let why = Files.check(item.url, maxBytes: AppConfig.maxSourceBytes) { throw IGPubError("\(name)：\(why)") }
            guard (try? Files.sha256(item.url)) == item.digest else {
                throw IGPubError("上傳 \(name) 失敗：檔案在加入後被更改，請重新加入")
            }
        }
    }

    /// Runs one step and, if it fails, says which one ("上傳 a.jpg 失敗：…").
    private func step<T>(_ what: String, _ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch is CancellationError { throw CancellationError() }
        catch let e as IGPubError { throw e.prefixed("\(what) 失敗：") }
        catch { throw IGPubError("\(what) 失敗：\(error.localizedDescription)") }
    }

    /// Returns the media ids, in order.
    public func publishSingles(_ items: [PublishItem], log: (String) -> Void) async throws -> [String] {
        var done: [String] = []
        for item in items { try item.options.validate(); try item.extras.validate() }   // fail before any upload
        try preflight(items)                                                           // ...or any post goes out
        for item in items {
            let name = item.url.lastPathComponent
            var key: String?
            do {
                log("上傳 \(name)…")
                let up = try await step("上傳 \(name)") { try await objectFor(item) }
                key = up.key
                let cid = try await step("建立貼文 \(name)") {
                    try await ig.createContainer(imageURL: up.url, caption: item.caption, options: item.options, extras: item.extras)
                }
                log("等待 Instagram 處理…")
                try await step("等待 Instagram 處理 \(name)") { try await ig.waitFinished(cid) }
                let media = try await step("發佈 \(name)") { try await ig.publish(cid) }
                do { try ledger.add(digest: item.digest, mediaId: media, name: name) }
                catch { log("警告：\(name) 已發佈，但沒能寫入已發佈紀錄，請不要重複發佈這一張") }
                log("已發佈 \(name)：\(media)")
                done.append(media)
            } catch {
                if let key { await storage.delete(key) }
                throw error
            }
            if let key { await storage.delete(key) }
        }
        return done
    }

    /// Uploads one photo of a multi-photo post, creates its child container and waits until Instagram has it.
    private func prepareChild(_ item: PublishItem, keys: KeyBox, log: @Sendable (String) -> Void) async throws -> String {
        let name = item.url.lastPathComponent
        log("上傳 \(name)…")
        let up = try await step("上傳 \(name)") { try await objectFor(item) }
        keys.add(up.key)
        let cid = try await step("建立 \(name)") {
            try await ig.createContainer(imageURL: up.url, carouselItem: true, options: item.options)
        }
        try await step("等待 Instagram 處理 \(name)") { try await ig.waitFinished(cid) }
        log("就緒 \(name)")
        return cid
    }

    public func publishCarousel(_ items: [PublishItem], caption: String, extras: PostExtras = .init(),
                                log: @escaping @Sendable (String) -> Void) async throws -> String {
        guard (2...10).contains(items.count) else {
            throw IGPubError("Instagram API 限制：一則多張貼文只能放 2～10 張，目前 \(items.count) 張")
        }
        for item in items { try item.options.validate() }
        try extras.validate()
        try preflight(items)
        let keys = KeyBox()
        do {
            // Photos are prepared a few at a time; the order of the post is the order of `items`.
            var children = [String?](repeating: nil, count: items.count)
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var started = 0
                func startNext() {
                    guard started < items.count else { return }
                    let i = started; started += 1
                    group.addTask { (i, try await self.prepareChild(items[i], keys: keys, log: log)) }
                }
                for _ in 0..<min(Self.parallelPhotos, items.count) { startNext() }
                while let (i, cid) = try await group.next() {
                    children[i] = cid
                    startNext()
                }
            }
            let ids = children.compactMap { $0 }
            guard ids.count == items.count else { throw IGPubError("有照片沒有處理完成，已停止") }
            let parent = try await step("合成多張貼文") { try await ig.createCarousel(children: ids, caption: caption, extras: extras) }
            try await step("等待多張貼文處理") { try await ig.waitFinished(parent) }
            let media = try await step("發佈多張貼文") { try await ig.publish(parent) }
            for item in items {
                do { try ledger.add(digest: item.digest, mediaId: media, name: "carousel") }
                catch { log("警告：貼文已發佈，但沒能寫入已發佈紀錄，請不要重複發佈"); break }
            }
            log("已發佈多張貼文（\(items.count) 張）：\(media)")
            for k in keys.all { await storage.delete(k) }
            return media
        } catch {
            for k in keys.all { await storage.delete(k) }
            throw error
        }
    }
}
