import Foundation

/// The photos picked for a post, in the order they were picked: that order is the post order.
/// Unpicking closes the gap; picking again puts the photo at the end.
public struct PickOrder<ID: Hashable>: Equatable {
    public private(set) var ids: [ID] = []

    public init(_ ids: [ID] = []) {
        var seen = Set<ID>()
        self.ids = ids.filter { seen.insert($0).inserted }
    }

    public var isEmpty: Bool { ids.isEmpty }
    public func contains(_ id: ID) -> Bool { ids.contains(id) }
    /// 1-based place in the post, nil when not picked.
    public func position(of id: ID) -> Int? { ids.firstIndex(of: id).map { $0 + 1 } }

    public mutating func toggle(_ id: ID) {
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
    }

    /// Picks every id not picked yet, appended in the given order (Shift-click passes them in screen order).
    public mutating func add(_ more: [ID]) {
        for id in more where !ids.contains(id) { ids.append(id) }
    }

    /// Moves a picked id by `offset` places (negative = earlier), stopping at the ends. Unpicked id: unchanged.
    public mutating func move(_ id: ID, by offset: Int) {
        guard let from = ids.firstIndex(of: id) else { return }
        let to = min(max(from + offset, 0), ids.count - 1)
        guard to != from else { return }
        ids.insert(ids.remove(at: from), at: to)
    }

    /// Moves a picked id to sit just before `target`; nil (or an unpicked target) means "to the end".
    public mutating func move(_ id: ID, before target: ID?) {
        guard target != id, let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        if let target, let to = ids.firstIndex(of: target) { ids.insert(id, at: to) } else { ids.append(id) }
    }

    public mutating func remove(_ gone: Set<ID>) { ids.removeAll { gone.contains($0) } }
    public mutating func removeAll() { ids = [] }

    /// The picked items in post order; ids without an item are skipped.
    public func ordered<T: Identifiable>(_ items: [T]) -> [T] where T.ID == ID {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }
}
