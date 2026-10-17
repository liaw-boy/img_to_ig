import Foundation

/// Pure list reordering for the photo grid (the order is the order of a multi-photo post).
public enum Reorder {
    /// Moves `id` to sit just before `target`; a nil or unknown target means "to the end". Unknown id: unchanged.
    public static func move<T: Identifiable>(_ items: [T], _ id: T.ID, before target: T.ID?) -> [T] {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return items }
        if let target, target == id { return items }
        var out = items
        let moved = out.remove(at: from)
        if let target, let to = out.firstIndex(where: { $0.id == target }) { out.insert(moved, at: to) } else { out.append(moved) }
        return out
    }

    /// Moves `id` by `offset` places (negative = earlier), stopping at the ends.
    public static func shift<T: Identifiable>(_ items: [T], _ id: T.ID, by offset: Int) -> [T] {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return items }
        let to = min(max(from + offset, 0), items.count - 1)
        guard to != from else { return items }
        var out = items
        out.insert(out.remove(at: from), at: to)
        return out
    }
}
