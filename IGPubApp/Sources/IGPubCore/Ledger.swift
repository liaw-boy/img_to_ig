import Foundation

public struct LedgerEntry: Identifiable, Equatable {
    public let id: String   // file digest
    public let mediaId: String
    public let name: String
    public let at: Date?
    public init(id: String, mediaId: String, name: String, at: Date?) {
        self.id = id
        self.mediaId = mediaId
        self.name = name
        self.at = at
    }
}

/// One Instagram post: a single photo, or every photo of a carousel (its rows share the media id).
/// Display only; the ledger itself stays one row per file, as the CLI expects.
public struct PostRecord: Identifiable, Equatable {
    public let mediaId: String
    public let photoCount: Int
    /// Recorded file names (carousel rows are stored as "carousel" and carry none).
    public let names: [String]
    public let at: Date?
    /// A carousel, even when only some of its rows are left: the ledger is keyed by photo, so a photo posted
    /// again later moves its row to the newer post.
    public let isCarousel: Bool
    public var id: String { mediaId }

    /// Newest post first.
    public static func group(_ entries: [LedgerEntry]) -> [PostRecord] {
        Dictionary(grouping: entries, by: \.mediaId).map { media, rows in
            PostRecord(mediaId: media, photoCount: rows.count,
                       names: rows.map(\.name).filter { !$0.isEmpty && $0 != "carousel" }.sorted(),
                       at: rows.compactMap(\.at).max(),
                       isCarousel: rows.count > 1 || rows.contains { $0.name == "carousel" })
        }.sorted { ($0.at ?? .distantPast, $0.mediaId) > ($1.at ?? .distantPast, $1.mediaId) }
    }
}

/// Ledger of what has been published, by file hash. Same file and format as the Python CLI
/// (~/.img_to_ig/published.json) so both tools skip what the other already posted.
public final class Ledger: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".img_to_ig/published.json")
    }
    static var legacyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".igpub/published.json")
    }

    /// One-time move of the ledger from the old location. Does nothing if the new file exists
    /// or the old one is missing; the old file is removed only after the copy succeeded.
    public static func migrateLegacy(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path),
              (try? fm.attributesOfItem(atPath: old.path)[.type] as? FileAttributeType) == .typeRegular else { return }
        let dir = new.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".ledger-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try fm.copyItem(at: old, to: tmp)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            try fm.moveItem(at: tmp, to: new)   // fails if new appeared meanwhile; never overwrites
            try fm.removeItem(at: old)
        } catch {
            try? fm.removeItem(at: tmp)
        }
    }

    private let url: URL
    private var data: [String: Any] = ["published": [String: Any]()]
    private let lock = NSLock()

    public init(url: URL = Ledger.defaultURL) {
        self.url = url
        if url == Ledger.defaultURL { Self.migrateLegacy(from: Self.legacyURL, to: url) }
        data = Self.read(url)
    }

    private static func read(_ url: URL) -> [String: Any] {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue ?? 0
        if size > 0, size <= 5_000_000, let raw = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           obj["published"] is [String: Any] {
            return obj
        }
        return ["published": [String: Any]()]
    }

    /// Re-reads the file (picks up writes from another instance or the Python CLI).
    public func reload() {
        let d = Self.read(url)
        lock.lock(); defer { lock.unlock() }
        data = d
    }

    /// Newest first; malformed rows are skipped.
    public func entries() -> [LedgerEntry] {
        lock.lock(); defer { lock.unlock() }
        let fmt = ISO8601DateFormatter()
        let fmtFrac = ISO8601DateFormatter()
        fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return published.compactMap { digest, v -> LedgerEntry? in
            guard let row = v as? [String: Any], let media = row["media_id"].map({ "\($0)" }) else { return nil }
            let at = (row["at"] as? String).flatMap { fmt.date(from: $0) ?? fmtFrac.date(from: $0) }
            return LedgerEntry(id: digest, mediaId: media, name: row["file"] as? String ?? "", at: at)
        }.sorted { ($0.at ?? .distantPast, $0.id) > ($1.at ?? .distantPast, $1.id) }
    }

    /// Forgets everything published; keeps other top-level keys and the file format.
    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        data["published"] = [String: Any]()
        try write()
        if url == Ledger.defaultURL { try? FileManager.default.removeItem(at: Self.legacyURL) }   // never resurrect old rows
    }

    private var published: [String: Any] { data["published"] as? [String: Any] ?? [:] }

    public func has(_ digest: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return published[digest] != nil
    }

    public func add(digest: String, mediaId: String, name: String) throws {
        lock.lock(); defer { lock.unlock() }
        var p = published
        p[digest] = ["media_id": mediaId, "file": name,
                     "at": ISO8601DateFormatter().string(from: Date())]
        data["published"] = p
        try write()
    }

    private func write() throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let raw = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
        try raw.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
