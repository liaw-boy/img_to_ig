import Foundation
import Security

/// Secrets live in the macOS Keychain only. All three share one item (service "img_to_ig",
/// account "bundle") so macOS asks the user once. Older installs kept one item per secret
/// (service "img_to_ig" or "igpub"); those are merged into the bundle the first time they are read.
public protocol SecretStore {
    func get(_ account: String) -> String?
    /// Whether a value is stored. Must not read the secret (the Keychain asks the user before releasing one).
    func exists(_ account: String) -> Bool
    func set(_ account: String, _ value: String) throws
    /// True when the value is gone (deleted or was never there).
    @discardableResult func delete(_ account: String) -> Bool
}

public extension SecretStore {
    func exists(_ account: String) -> Bool { get(account) != nil }
}

public enum SecretName {
    public static let accessToken = "access_token"
    public static let s3AccessKey = "s3_access_key"
    public static let s3SecretKey = "s3_secret_key"
    public static let all = [accessToken, s3AccessKey, s3SecretKey]
}

public enum BundleRead {
    case found([String: String])
    case missing
    case corrupt     // an item exists but its content is not our JSON; nothing to lose by replacing it
    case denied      // the user pressed "Deny" or the Keychain failed; not the same as missing
}

/// Storage behind `BundleSecretStore`; the real one is the Keychain, tests use memory.
public protocol BundleBackend {
    func readBundle() -> BundleRead
    /// Names stored in the bundle, from non-secret attributes only (no password prompt). nil if no bundle.
    func bundleNames() -> Set<String>?
    /// Whether the bundle item exists at all (attribute-only, no prompt), even if its names are unreadable.
    func bundleExists() -> Bool
    func writeBundle(_ values: [String: String]) throws
    func deleteBundle() -> Bool
    /// Pre-bundle items, one per secret.
    func readLegacy(_ account: String) -> String?
    func legacyExists(_ account: String) -> Bool
    func deleteLegacy(_ account: String) -> Bool
}

/// One process keeps the bundle in memory after the first read. If another process (not the CLI, which only
/// reads) changes the same item while the App is open, the App's next write replaces it.
public final class BundleSecretStore: SecretStore, @unchecked Sendable {
    private let backend: BundleBackend
    private var cache: [String: String]?
    private let lock = NSLock()
    public init(_ backend: BundleBackend) { self.backend = backend }

    /// Reads the bundle once per run. Must be called with the lock held.
    private func load() -> [String: String]? {
        if let c = cache { return c }
        switch backend.readBundle() {
        case .found(let b):
            cache = b
        case .denied:
            return nil
        case .corrupt:
            cache = [:]
        case .missing:
            var merged: [String: String] = [:]
            for a in SecretName.all { if let v = backend.readLegacy(a) { merged[a] = v } }
            // Copy first; delete only the old items that really made it into the bundle.
            if !merged.isEmpty {
                guard (try? backend.writeBundle(merged)) != nil else { cache = merged; return merged }
                for a in merged.keys { _ = backend.deleteLegacy(a) }
            }
            cache = merged
        }
        return cache
    }

    public func get(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return load()?[account]
    }

    public func exists(_ account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c[account] != nil }
        if let names = backend.bundleNames() { return names.contains(account) }
        if backend.bundleExists() { return load()?[account] != nil }   // names unreadable: fall back to reading
        return backend.legacyExists(account)
    }

    public func set(_ account: String, _ value: String) throws {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { throw IGPubError("值不可為空") }
        lock.lock(); defer { lock.unlock() }
        guard var current = load() else { throw IGPubError("無法讀取鑰匙圈，請允許 img_to_ig 存取後再試") }
        let old = current
        current[account] = v
        do { try backend.writeBundle(current) } catch { cache = old; throw error }   // a failed write keeps the old value
        cache = current
    }

    @discardableResult
    public func delete(_ account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let legacyGone = backend.deleteLegacy(account)
        if cache == nil, !backend.bundleExists() { return legacyGone }   // nothing bundled
        guard var current = load() else { return false }
        current[account] = nil
        if current.isEmpty {
            guard backend.deleteBundle() else { return false }
        } else {
            guard (try? backend.writeBundle(current)) != nil else { return false }
        }
        cache = current
        return legacyGone
    }
}

public struct KeychainBackend: BundleBackend {
    public static let service = "img_to_ig"
    public static let legacyService = "igpub"
    static let bundleAccount = "bundle"
    public init() {}

    private func query(_ account: String, service: String = KeychainBackend.service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func readData(_ q: [String: Any]) -> (OSStatus, Data?) {
        var q = q
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        return (st, out as? Data)
    }

    public func readBundle() -> BundleRead {
        let (st, data) = readData(query(Self.bundleAccount))
        if st == errSecItemNotFound { return .missing }
        guard st == errSecSuccess, let data else { return .denied }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return .corrupt }
        return .found(obj)
    }

    private static let namesKey = "keychainBundleNames"

    private func rememberNames(_ names: Set<String>?) {
        if let names { UserDefaults.standard.set(names.sorted(), forKey: Self.namesKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.namesKey) }
    }

    /// Which secrets are stored. Answered from the App's own preferences (names only), so starting the App
    /// does not touch the Keychain; the Keychain attributes are read once if that list is missing.
    public func bundleNames() -> Set<String>? {
        if let cached = UserDefaults.standard.array(forKey: Self.namesKey) as? [String] { return Set(cached) }
        let fromKeychain = bundleNamesFromKeychain()
        if let fromKeychain { rememberNames(fromKeychain) }
        return fromKeychain
    }

    private func bundleNamesFromKeychain() -> Set<String>? {
        var q = query(Self.bundleAccount)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let attrs = out as? [String: Any], let g = attrs[kSecAttrGeneric as String] as? Data,
              let names = try? JSONSerialization.jsonObject(with: g) as? [String] else { return nil }
        return Set(names)
    }

    public func bundleExists() -> Bool {
        if UserDefaults.standard.array(forKey: Self.namesKey) != nil { return true }
        return SecItemCopyMatching(query(Self.bundleAccount) as CFDictionary, nil) == errSecSuccess
    }

    public func writeBundle(_ values: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: values)
        let names = try JSONSerialization.data(withJSONObject: values.keys.sorted())   // not secret; lets us answer "is it stored" without a prompt
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrGeneric as String: names,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        // Update in place; never delete first, so a failed write keeps the old value.
        var st = SecItemUpdate(query(Self.bundleAccount) as CFDictionary, attrs as CFDictionary)
        if st == errSecItemNotFound {
            st = SecItemAdd(query(Self.bundleAccount).merging(attrs) { $1 } as CFDictionary, nil)
        }
        guard st == errSecSuccess else { throw IGPubError("寫入鑰匙圈失敗（\(st)）") }
        rememberNames(Set(values.keys))
    }

    public func deleteBundle() -> Bool {
        let st = SecItemDelete(query(Self.bundleAccount) as CFDictionary)
        let ok = st == errSecSuccess || st == errSecItemNotFound
        if ok { rememberNames(nil) }
        return ok
    }

    public func readLegacy(_ account: String) -> String? {
        for s in [Self.service, Self.legacyService] {
            let (st, d) = readData(query(account, service: s))
            if st == errSecSuccess, let d, let t = String(data: d, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        }
        return nil
    }

    public func legacyExists(_ account: String) -> Bool {
        return [Self.service, Self.legacyService].contains {
            SecItemCopyMatching(query(account, service: $0) as CFDictionary, nil) == errSecSuccess
        }
    }

    public func deleteLegacy(_ account: String) -> Bool {
        return [Self.service, Self.legacyService].allSatisfy {
            let st = SecItemDelete(query(account, service: $0) as CFDictionary)
            return st == errSecSuccess || st == errSecItemNotFound
        }
    }
}

public func KeychainStore() -> SecretStore { BundleSecretStore(KeychainBackend()) }
