import Foundation

/// Uploads photos to the temporary storage ahead of time (while the user edits), so pressing Publish only has to
/// ask Instagram to fetch them. Everything it uploads is either handed to the publisher (`take`, which then deletes
/// it after use) or deleted here (`discard`). Keys are reported through `onChange` so leftovers can be removed
/// if the app quits in between.
public actor UploadStager {
    public enum State: Equatable, Sendable { case uploading, ready, failed(String) }

    private let storage: TempStorage
    private let prepare: @Sendable (PublishItem) throws -> Data
    private let onChange: @Sendable ([String]) -> Void
    private var keys: [String: String] = [:]                  // content digest -> object key
    private var inflight: [String: Task<String, Error>] = [:]
    private var states: [String: State] = [:]
    /// Set by `discardAll`: a stager being thrown away never starts another upload.
    private var closed = false

    /// - prepare: returns the exact bytes to upload (the verified original, or a shrunk copy when that is on).
    public init(storage: TempStorage, prepare: @escaping @Sendable (PublishItem) throws -> Data,
                onChange: @escaping @Sendable ([String]) -> Void = { _ in }) {
        self.storage = storage
        self.prepare = prepare
        self.onChange = onChange
    }

    public func state(of digest: String) -> State? { states[digest] }

    /// Uploads one photo (idempotent: a photo already staged or being staged is not uploaded again).
    public func stage(_ item: PublishItem) async {
        guard !closed else { return }
        let digest = item.digest
        if keys[digest] != nil { return }
        if let t = inflight[digest] { _ = try? await t.value; return }
        states[digest] = .uploading
        let storage = self.storage, prepare = self.prepare
        // The task records the key itself, so anyone waiting on it (take/discard) always finds it afterwards.
        let task = Task.detached { () throws -> String in
            let key = try await storage.put(data: try prepare(item))
            await self.record(digest, key)
            return key
        }
        inflight[digest] = task
        do { _ = try await task.value }
        catch { states[digest] = .failed((error as? IGPubError)?.message ?? error.localizedDescription) }
        inflight[digest] = nil
        onChange(Array(keys.values))
    }

    private func record(_ digest: String, _ key: String) {
        keys[digest] = key
        states[digest] = .ready
    }

    /// Hands the staged object over (waiting for an upload in progress). nil if it is not staged.
    /// From here on the caller owns the object and must delete it.
    public func take(_ digest: String) async -> String? {
        if let t = inflight[digest] { _ = try? await t.value }
        guard let k = keys.removeValue(forKey: digest) else { return nil }
        states[digest] = nil
        onChange(Array(keys.values))
        return k
    }

    /// Deletes the staged objects of these photos (waits for uploads in progress so nothing is left behind).
    public func discard(_ digests: Set<String>) async {
        for d in digests {
            if let t = inflight[d] { _ = try? await t.value }
            if let k = keys.removeValue(forKey: d) { await storage.delete(k) }
            states[d] = nil
        }
        onChange(Array(keys.values))
    }

    /// Deletes everything and closes the stager: later `stage` calls do nothing.
    public func discardAll() async {
        closed = true
        await discard(Set(keys.keys).union(inflight.keys))
    }

    /// Digests that are staged or being staged.
    public var staged: Set<String> { Set(keys.keys).union(inflight.keys) }
}

public enum StagingKeys {
    /// True only for object names exactly like the ones this app creates ("<prefix><32 hex>.jpg"), so a tampered
    /// list of leftovers can never make the app delete anything else in the user's bucket.
    public static func isOwn(_ key: String, prefix: String) -> Bool {
        guard key.hasPrefix(prefix) else { return false }
        let rest = key.dropFirst(prefix.count)
        return rest.count == 36 && rest.hasSuffix(".jpg") && rest.dropLast(4).allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
