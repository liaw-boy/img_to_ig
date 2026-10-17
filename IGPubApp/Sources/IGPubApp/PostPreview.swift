import SwiftUI
import IGPubCore

/// Instagram feed shows 4:5 (tall) to 1.91:1 (wide); anything outside is cropped. A carousel uses the first photo's ratio.
enum FeedCrop {
    static let tallest = 0.8, widest = 1.91
    static func ratio(for aspect: Double) -> Double { min(max(aspect, tallest), widest) }
}

/// A mock-up of how the post looks in the Instagram feed, drawn by us: author row, the cropped photo (with
/// carousel counter and dots), action row, caption, tagged people, collaborators. Layout follows the phone feed.
/// With `onPlaceTag`, a click on the photo reports where (0...1) so the editor can tag someone there.
struct PostPreview: View {
    let items: [PhotoItem]
    let caption: String
    var collaborators: [String] = []
    var aiGenerated = false
    var username: String?
    var width: CGFloat = 375
    @Binding var index: Int
    var onPlaceTag: ((Int, CGPoint) -> Void)?

    @Environment(\.colorScheme) private var scheme
    @State private var big: [UUID: NSImage] = [:]
    @State private var expanded = false

    // Instagram's own light/dark feed colors, kept apart from the app theme on purpose.
    private var bg: Color { scheme == .dark ? Color(hex: 0x000000) : Color(hex: 0xFFFFFF) }
    private var primary: Color { scheme == .dark ? Color(hex: 0xF5F5F5) : Color(hex: 0x262626) }
    private var secondary: Color { scheme == .dark ? Color(hex: 0xA8A8A8) : Color(hex: 0x737373) }
    private var link: Color { scheme == .dark ? Color(hex: 0xE0F1FF) : Color(hex: 0x00376B) }
    private var blue: Color { Color(hex: 0x0095F6) }

    private var ratio: Double { FeedCrop.ratio(for: items.first?.aspect ?? 1) }
    private var current: PhotoItem? { items.indices.contains(index) ? items[index] : nil }
    private var name: String { username ?? "your_account" }
    private let side: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            photo
            actions
            VStack(alignment: .leading, spacing: 4) {
                Text("成為第一個說讚的人").font(.system(size: 14, weight: .semibold)).foregroundStyle(primary)
                captionText
                Text("剛剛").font(.system(size: 12)).foregroundStyle(secondary).padding(.top, 2)
            }
            .padding(.horizontal, side).padding(.bottom, side)
        }
        .frame(width: width)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.gray.opacity(0.35), lineWidth: 1))
        .task(id: items.map(\.id)) { await loadBig() }
        .onChange(of: items.count) { _, n in if index >= n { index = max(0, n - 1) } }
    }

    // MARK: author row

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(hex: 0xFEDA75), Color(hex: 0xFA7E1E), Color(hex: 0xD62976), Color(hex: 0x962FBF)],
                                             startPoint: .bottomLeading, endPoint: .topTrailing))
                Circle().fill(bg).padding(2)
                Circle().fill(Color.gray.opacity(0.35)).padding(4)
                Text(String(name.prefix(1)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(primary)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                (Text(name).fontWeight(.semibold)
                 + Text(collaborators.isEmpty ? "" : " 和 " + collaborators.map { $0 }.joined(separator: "、")).fontWeight(.semibold))
                    .font(.system(size: 14)).foregroundStyle(primary).lineLimit(1)
                if aiGenerated {
                    Text("AI 資訊").font(.system(size: 12)).foregroundStyle(secondary)
                }
            }
            Spacer(minLength: 0)
            Text("•••").font(.system(size: 13, weight: .bold)).foregroundStyle(primary)
        }
        .padding(.horizontal, side).padding(.vertical, 10)
    }

    // MARK: photo

    private var photo: some View {
        let h = width / ratio
        return ZStack {
            Color.gray.opacity(0.2)
            if let c = current, let img = big[c.id] ?? c.thumbnail {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: width, height: h).clipped()
            }
            if let c = current {
                ForEach(c.options.tags) { t in
                    TagPin(name: t.username).position(x: t.x * width, y: t.y * h)
                }
            }
            if items.count > 1 {
                Text("\(index + 1)/\(items.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(12)
                    .allowsHitTesting(false)
                HStack {
                    arrow("chevron.left", enabled: index > 0) { index -= 1 }
                    Spacer()
                    arrow("chevron.right", enabled: index < items.count - 1) { index += 1 }
                }
                .padding(.horizontal, 8)
            }
            HStack(spacing: 6) {
                if let c = current, !c.options.tags.isEmpty { badge { Image(systemName: "person.fill").font(.system(size: 11)) } }
                if let c = current, !c.options.altText.isEmpty { badge { Text("ALT").font(.system(size: 11, weight: .semibold)) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(10)
            .allowsHitTesting(false)
        }
        .frame(width: width, height: h)
        .clipped()
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { v in
            guard let onPlaceTag else { return }
            onPlaceTag(index, CGPoint(x: min(max(v.location.x / width, 0), 1), y: min(max(v.location.y / h, 0), 1)))
        })
        .accessibilityLabel(current.map { "預覽：\($0.url.lastPathComponent)" } ?? "預覽")
    }

    private func arrow(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                .frame(width: 26, height: 26).background(.white.opacity(0.85), in: Circle())
        }
        .buttonStyle(.plain).opacity(enabled ? 1 : 0).disabled(!enabled)
        .accessibilityLabel(symbol == "chevron.left" ? "上一張" : "下一張")
    }

    private func badge<V: View>(@ViewBuilder _ v: () -> V) -> some View {
        v().foregroundStyle(.white).padding(.horizontal, 8).frame(minWidth: 26, minHeight: 26)
            .background(.black.opacity(0.7), in: Capsule())
    }

    // MARK: actions + caption

    private var actions: some View {
        ZStack {
            HStack(spacing: 16) {
                Image(systemName: "heart"); Image(systemName: "bubble.right"); Image(systemName: "paperplane")
                Spacer()
                Image(systemName: "bookmark")
            }
            if items.count > 1 {
                HStack(spacing: 4) {
                    ForEach(items.indices, id: \.self) { i in
                        Circle().fill(i == index ? blue : secondary.opacity(0.5)).frame(width: 6, height: 6)
                    }
                }
            }
        }
        .font(.system(size: 22)).foregroundStyle(primary)
        .padding(.horizontal, side).padding(.vertical, 10)
    }

    private var captionText: some View {
        let long = caption.count > 90 || caption.contains("\n")
        let shown = (!expanded && long) ? String(caption.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)?.prefix(90) ?? "") : caption
        return VStack(alignment: .leading, spacing: 2) {
            if !caption.isEmpty {
                (Text(name).fontWeight(.semibold).foregroundColor(primary) + Text(" ") + Self.styled(shown, base: primary, link: link)
                 + (!expanded && long ? Text("… ").foregroundColor(primary) + Text("更多").foregroundColor(secondary) : Text("")))
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { if long { expanded.toggle() } }
            }
        }
    }

    /// #hashtags and @mentions are drawn in the link color, as in the feed.
    static func styled(_ text: String, base: Color, link: Color) -> Text {
        var out = Text("")
        var buf = ""
        var inLink = false
        func flush() { if !buf.isEmpty { out = out + Text(buf).foregroundColor(inLink ? link : base); buf = "" } }
        for ch in text {
            let isLinkChar = ch.isLetter || ch.isNumber || ch == "_" || ch == "."
            if inLink {
                if !isLinkChar { flush(); inLink = false }
            } else if ch == "#" || ch == "@" {
                flush(); inLink = true
            }
            buf.append(ch)
        }
        flush()
        return out
    }

    private func loadBig() async {
        for p in items where big[p.id] == nil {
            let url = p.url
            let img = await Task.detached(priority: .utility) { AppModel.thumbnail(url, maxPixel: 1200) }.value
            if let img { big[p.id] = img }
        }
    }
}

private struct TagPin: View {
    let name: String
    var body: some View {
        Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 6))
            .allowsHitTesting(false)
    }
}
