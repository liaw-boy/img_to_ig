import Foundation
import CryptoKit

/// Which files may be published: real JPEG files only, size-capped, no symlinks.
public enum Files {
    static let suffixes: Set<String> = ["jpg", "jpeg"]

    public static func check(_ url: URL, maxBytes: Int) -> String? {
        if !suffixes.contains(url.pathExtension.lowercased()) { return "不是 .jpg / .jpeg 檔" }
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return "讀不到檔案" }
        if attrs[.type] as? FileAttributeType == .typeSymbolicLink { return "符號連結" }
        if attrs[.type] as? FileAttributeType != .typeRegular { return "不是一般檔案" }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if size == 0 { return "空檔案" }
        if size > maxBytes { return "超過 \(maxBytes / (1024 * 1024)) MB 上限" }
        guard let h = try? FileHandle(forReadingFrom: url) else { return "讀不到檔案" }
        defer { try? h.close() }
        if (try? h.read(upToCount: 3)) != Data([0xFF, 0xD8, 0xFF]) { return "不是 JPEG（檔頭不符）" }
        return nil
    }

    /// Expands folders (not recursive, hidden files ignored).
    public static func collect(_ urls: [URL], maxBytes: Int) -> (ok: [URL], bad: [(URL, String)]) {
        let fm = FileManager.default
        var found: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            let isLink = (try? fm.attributesOfItem(atPath: u.path))?[.type] as? FileAttributeType == .typeSymbolicLink
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue, !isLink {
                let kids = (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
                found += kids.filter { !$0.lastPathComponent.hasPrefix(".") && suffixes.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                found.append(u)
            }
        }
        var ok: [URL] = [], bad: [(URL, String)] = []
        for u in found {
            if let why = check(u, maxBytes: maxBytes) { bad.append((u, why)) } else { ok.append(u) }
        }
        return (ok, bad)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// An explicit caption wins, then <name>.txt next to the photo, then the default.
    public static func caption(for url: URL, explicit: String?, defaultCaption: String) throws -> String {
        var text = defaultCaption
        if let explicit {
            text = explicit
        } else {
            let side = url.deletingPathExtension().appendingPathExtension("txt")
            if let a = try? FileManager.default.attributesOfItem(atPath: side.path),
               a[.type] as? FileAttributeType == .typeRegular,
               (a[.size] as? NSNumber)?.intValue ?? Int.max <= 20_000,
               let data = try? Data(contentsOf: side) {
                text = String(decoding: data, as: UTF8.self)
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > AppConfig.maxCaption {
            throw IGPubError("\(url.lastPathComponent) 的文案超過 \(AppConfig.maxCaption) 字")
        }
        return text
    }
}
