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

/// Orchestrates upload -> container -> wait -> publish -> ledger -> cleanup. Stops at the first error and always
/// deletes whatever is still in the bucket.
public struct Publisher {
    let ig: InstagramClient
    let storage: TempStorage
    let ledger: Ledger

    public init(ig: InstagramClient, storage: TempStorage, ledger: Ledger) {
        self.ig = ig
        self.storage = storage
        self.ledger = ledger
    }

    /// Re-checks the file and returns exactly the bytes whose hash matches what the user added.
    public func verifiedData(_ item: PublishItem) throws -> Data {
        if let why = Files.check(item.url, maxBytes: storage.config.maxBytes) {
            throw IGPubError("\(item.url.lastPathComponent)：\(why)")
        }
        let data = try Data(contentsOf: item.url)
        guard data.count <= storage.config.maxBytes, data.starts(with: [0xFF, 0xD8, 0xFF]),
              Files.sha256(data) == item.digest else { throw IGPubError("檔案在加入後被更改，請重新加入") }
        return data
    }

    /// Returns the media ids, in order.
    public func publishSingles(_ items: [PublishItem], log: (String) -> Void) async throws -> [String] {
        var done: [String] = []
        for item in items { try item.options.validate(); try item.extras.validate() }   // fail before any upload
        for item in items {
            var key: String?
            do {
                log("上傳 \(item.url.lastPathComponent)…")
                let up = try await storage.upload(data: verifiedData(item))
                key = up.key
                let cid = try await ig.createContainer(imageURL: up.url, caption: item.caption, options: item.options, extras: item.extras)
                log("等待 Instagram 處理…")
                try await ig.waitFinished(cid)
                let media = try await ig.publish(cid)
                try ledger.add(digest: item.digest, mediaId: media, name: item.url.lastPathComponent)
                log("已發佈 \(item.url.lastPathComponent)：\(media)")
                done.append(media)
            } catch {
                if let key { await storage.delete(key) }
                throw error
            }
            if let key { await storage.delete(key) }
        }
        return done
    }

    public func publishCarousel(_ items: [PublishItem], caption: String, extras: PostExtras = .init(), log: (String) -> Void) async throws -> String {
        guard (2...10).contains(items.count) else { throw IGPubError("輪播需要 2～10 張，目前 \(items.count) 張") }
        for item in items { try item.options.validate() }
        try extras.validate()
        var keys: [String] = []
        do {
            var children: [String] = []
            for item in items {
                log("上傳 \(item.url.lastPathComponent)…")
                let up = try await storage.upload(data: verifiedData(item))
                keys.append(up.key)
                let cid = try await ig.createContainer(imageURL: up.url, carouselItem: true, options: item.options)
                try await ig.waitFinished(cid)
                children.append(cid)
            }
            let parent = try await ig.createCarousel(children: children, caption: caption, extras: extras)
            try await ig.waitFinished(parent)
            let media = try await ig.publish(parent)
            for item in items {
                try ledger.add(digest: item.digest, mediaId: media, name: "carousel")
            }
            log("已發佈輪播（\(items.count) 張）：\(media)")
            for k in keys { await storage.delete(k) }
            return media
        } catch {
            for k in keys { await storage.delete(k) }
            throw error
        }
    }
}
