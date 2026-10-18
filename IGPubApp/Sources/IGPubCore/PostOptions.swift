import Foundation

/// A person tagged in a photo. x/y are fractions of the width/height measured from the top-left corner.
public struct UserTag: Equatable, Hashable, Identifiable {
    public var username: String
    public var x: Double
    public var y: Double
    public var id: String { username }
    public init(username: String, x: Double, y: Double) {
        self.username = username
        self.x = x
        self.y = y
    }
}

/// Optional Instagram fields for one photo (documented for POST /<IG_ID>/media: alt_text, user_tags).
public struct ItemOptions: Equatable {
    public static let maxAltText = 1000
    public static let maxTags = 20
    public var altText = ""
    public var tags: [UserTag] = []
    public init(altText: String = "", tags: [UserTag] = []) {
        self.altText = altText
        self.tags = tags
    }

    /// Throws a user-facing error for anything Instagram would refuse or that is not a plain value.
    public func validate() throws {
        if altText.count > Self.maxAltText { throw IGPubError("替代文字超過 \(Self.maxAltText) 字") }
        if tags.count > Self.maxTags { throw IGPubError("一張照片最多標記 \(Self.maxTags) 人") }
        var seen = Set<String>()
        for t in tags {
            guard Usernames.normalize(t.username) == t.username else { throw IGPubError("標記的帳號格式不對：\(t.username)") }
            guard (0.0...1.0).contains(t.x), (0.0...1.0).contains(t.y) else { throw IGPubError("標記位置超出照片範圍") }
            guard seen.insert(t.username.lowercased()).inserted else { throw IGPubError("同一張照片重複標記 \(t.username)") }
        }
    }

    /// `user_tags` parameter value (a JSON array), or nil when there is nothing to send.
    var userTagsJSON: String? {
        guard !tags.isEmpty else { return nil }
        let arr = tags.map { ["username": $0.username, "x": Self.clamp($0.x), "y": Self.clamp($0.y)] as [String: Any] }
        guard let d = try? JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func clamp(_ v: Double) -> Double { (min(max(v, 0), 1) * 1000).rounded() / 1000 }
}

/// Per-post fields: collaborators and the AI-generated disclosure.
public struct PostExtras: Equatable {
    public static let maxCollaborators = 3
    public var collaborators: [String] = []
    public var aiGenerated = false
    public init(collaborators: [String] = [], aiGenerated: Bool = false) {
        self.collaborators = collaborators
        self.aiGenerated = aiGenerated
    }

    public func validate() throws {
        if collaborators.count > Self.maxCollaborators { throw IGPubError("合作夥伴最多 \(Self.maxCollaborators) 個帳號") }
        var seen = Set<String>()
        for c in collaborators {
            guard Usernames.normalize(c) == c else { throw IGPubError("合作夥伴的帳號格式不對：\(c)") }
            guard seen.insert(c.lowercased()).inserted else { throw IGPubError("重複的合作夥伴 \(c)") }
        }
    }

    var collaboratorsJSON: String? {
        guard !collaborators.isEmpty,
              let d = try? JSONSerialization.data(withJSONObject: collaborators) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

public enum Usernames {
    /// Instagram usernames: letters, digits, periods, underscores, up to 30; no period at either end and never
    /// two in a row. Accepts a leading "@".
    public static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("@") { s.removeFirst() }
        guard (1...30).contains(s.count),
              s.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_") }),
              !s.hasPrefix("."), !s.hasSuffix("."), !s.contains("..")
        else { return nil }
        return s
    }

    /// "a, @b  c" -> ["a", "b", "c"]; nil if any entry is not a valid username.
    public static func parseList(_ text: String) -> [String]? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" || $0.isWhitespace }).map(String.init)
        var out: [String] = []
        for p in parts {
            guard let n = normalize(p) else { return nil }
            out.append(n)
        }
        return out
    }
}

/// Accounts used as collaborators in posts that went out, most used first. Local only (editor suggestions).
public struct FrequentUsernames: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var name: String
        public var count: Int
        public var last: Date
    }
    public private(set) var entries: [Entry] = []
    public static let cap = 50
    static let maxCount = 1_000_000      // a count beyond this only comes from a tampered store

    public init() {}

    /// Drops anything that is not a valid username (the stored copy is outside input).
    public func sanitized() -> FrequentUsernames {
        var f = FrequentUsernames()
        f.entries = Array(entries.filter { Usernames.normalize($0.name) == $0.name && (1...Self.maxCount).contains($0.count) }.prefix(Self.cap))
        return f
    }

    public mutating func record(_ names: [String], at now: Date = Date()) {
        for raw in names {
            guard let n = Usernames.normalize(raw) else { continue }
            if let i = entries.firstIndex(where: { $0.name.lowercased() == n.lowercased() }) {
                if entries[i].count < Self.maxCount { entries[i].count += 1 }; entries[i].last = now; entries[i].name = n
            } else {
                entries.append(Entry(name: n, count: 1, last: now))
            }
        }
        entries.sort { ($0.count, $0.last) > ($1.count, $1.last) }
        if entries.count > Self.cap { entries.removeLast(entries.count - Self.cap) }
    }

    /// Most used first, starting with what has been typed so far, without the accounts already added.
    public func suggestions(matching typed: String, excluding: [String], limit: Int = 8) -> [String] {
        var p = typed.trimmingCharacters(in: .whitespaces).lowercased()
        if p.hasPrefix("@") { p.removeFirst() }
        let ex = Set(excluding.map { $0.lowercased() })
        return Array(entries.map(\.name).filter { !ex.contains($0.lowercased()) && (p.isEmpty || $0.lowercased().hasPrefix(p)) }.prefix(limit))
    }
}
