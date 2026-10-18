import SwiftUI
import IGPubCore

/// Usernames as chips: type an account and press Enter, space or a comma to add it; ✕ removes one, and
/// Delete in an empty field removes the last. Frequently used accounts are offered underneath.
/// `text` keeps the committed usernames space-separated, the same format the rest of the app parses.
struct UsernameChipsField: View {
    @Binding var text: String
    let max: Int
    let frequent: FrequentUsernames
    var label = "合作夥伴"

    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var names: [String] { Usernames.parseList(text) ?? [] }
    private static func isSeparator(_ c: Character) -> Bool { c == "," || c == "，" || c == "、" || c.isWhitespace }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            FlowLayout(spacing: Theme.Space.xs) {
                ForEach(names, id: \.self) { n in chip(n) }
                TextField(names.isEmpty ? "@帳號，按 Enter 或空白鍵加入（選填）" : "", text: $draft)
                    .textFieldStyle(.plain).font(Theme.Font.mono).foregroundStyle(Theme.ink)
                    .frame(minWidth: Theme.chipFieldMinWidth, minHeight: Theme.chipHeight)
                    .focused($focused)
                    .disabled(names.count >= max)
                    .onSubmit { commit(draft, keepLast: false) }
                    .onChange(of: draft) { _, v in if v.contains(where: Self.isSeparator) { commit(v, keepLast: !Self.isSeparator(v.last!)) } }
                    .onChange(of: focused) { _, f in if !f, !draft.isEmpty { commit(draft, keepLast: false) } }
                    .onKeyPress(.delete) {
                        guard draft.isEmpty, let last = names.last else { return .ignored }
                        remove(last); return .handled
                    }
                    .accessibilityLabel(label)
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
            .frame(maxWidth: .infinity, minHeight: Theme.controlHeight, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .strokeBorder(error != nil ? Theme.danger : focused ? Theme.accent : Theme.lineStrong, lineWidth: error != nil ? 1.5 : 1))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            if let error {
                Text(error).font(Theme.Font.caption).foregroundStyle(Theme.danger)
            }
            let offers = names.count < max ? frequent.suggestions(matching: draft, excluding: names) : []
            if !offers.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text("常用").font(Theme.Font.caption).foregroundStyle(Theme.ink3)
                    FlowLayout(spacing: Theme.Space.xs) {
                        ForEach(offers, id: \.self) { n in
                            Button { add([n]); draft = "" } label: {
                                Text("@" + n).font(Theme.Font.mono).foregroundStyle(Theme.ink2)
                                    .padding(.horizontal, Theme.Space.s).frame(height: Theme.chipHeight)
                                    .overlay(Capsule().strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("加入常用帳號 @\(n)")
                        }
                    }
                }
            }
        }
        .onAppear(perform: salvage)
    }

    /// A value saved before the current rules (e.g. a draft with "a..b") would show no chips yet still block
    /// publishing: keep the valid names as chips and move the rest into the field, flagged, so it can be fixed.
    private func salvage() {
        guard Usernames.parseList(text) == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let parts = text.split(whereSeparator: Self.isSeparator).map(String.init)
        text = ""
        draft = add(parts).joined(separator: " ")
    }

    private func chip(_ n: String) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Text("@" + n).font(Theme.Font.mono).foregroundStyle(Theme.ink)
            Button { remove(n) } label: {
                Image(systemName: "xmark").font(Theme.Font.chipGlyph).foregroundStyle(Theme.ink3)
                    .frame(width: Theme.chipHeight - Theme.Space.s, height: Theme.chipHeight - Theme.Space.s)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除 @\(n)")
        }
        .padding(.leading, Theme.Space.s).padding(.trailing, Theme.Space.xs)
        .frame(height: Theme.chipHeight)
        .background(Theme.surfaceMuted, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.lineStrong, lineWidth: 1))
    }

    /// Adds every complete name in `raw`; with `keepLast`, the part after the last separator stays in the field.
    private func commit(_ raw: String, keepLast: Bool) {
        var parts = raw.split(whereSeparator: Self.isSeparator).map(String.init)
        let rest = keepLast ? (parts.popLast() ?? "") : ""
        let bad = add(parts)
        draft = (bad + (rest.isEmpty ? [] : [rest])).joined(separator: " ")
    }

    /// Returns the entries that could not be added (left in the field so they can be fixed).
    @discardableResult
    private func add(_ parts: [String]) -> [String] {
        error = nil
        var list = names, bad: [String] = []
        for p in parts {
            guard let n = Usernames.normalize(p) else {
                bad.append(p); error = "帳號只能有英文字母、數字、句點和底線（最多 30 字），句點不能在頭尾或連續出現"; continue
            }
            if list.contains(where: { $0.lowercased() == n.lowercased() }) { continue }
            guard list.count < max else { bad.append(p); error = "最多 \(max) 個帳號"; continue }
            list.append(n)
        }
        text = list.joined(separator: " ")
        return bad
    }

    private func remove(_ n: String) {
        text = names.filter { $0 != n }.joined(separator: " ")
        error = nil
    }
}

/// Lays children out left to right and wraps to a new row when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { y += rowHeight + spacing; x = 0; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = Swift.max(rowHeight, size.height)
            width = Swift.max(width, x - spacing)
        }
        return CGSize(width: proposal.width ?? width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        let rows = subviews.map { $0.sizeThatFits(.unspecified) }
        for (s, size) in zip(subviews, rows) {
            if x > bounds.minX, x + size.width > bounds.maxX { y += rowHeight + spacing; x = bounds.minX; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = Swift.max(rowHeight, size.height)
        }
    }
}
