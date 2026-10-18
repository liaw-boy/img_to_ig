import SwiftUI

/// How the new post(s) sit on the profile grid. Instagram shows every post there as a 3:4 tile cut from the
/// middle of the (first) photo, and the API cannot change that crop; it can only be moved later in the
/// Instagram app ("Adjust preview"). Earlier posts are drawn as blank tiles: the app keeps no images of them.
struct ProfileGridPreview: View {
    /// One tile per post, in publishing order.
    let posts: [Post]
    struct Post: Identifiable {
        let id: UUID            // the post's first photo
        let url: URL
        let thumbnail: NSImage?
        let isCarousel: Bool
    }

    static let maxNewTiles = 9
    private let columns = 3, gap: CGFloat = 2

    @Environment(\.colorScheme) private var scheme
    @State private var sharp: [UUID: NSImage] = [:]

    /// Newest first, like the grid: the last post published lands top left.
    private var newTiles: [Post] { Array(posts.reversed().prefix(Self.maxNewTiles)) }
    private var tileCount: Int { max(2 * columns, (newTiles.count + columns - 1) / columns * columns) }

    var body: some View {
        let tile = (Theme.previewWidth - gap * CGFloat(columns - 1)) / CGFloat(columns)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: gap), count: columns), spacing: gap) {
            ForEach(0..<tileCount, id: \.self) { i in
                if i < newTiles.count {
                    newTile(newTiles[i], width: tile)
                } else {
                    Rectangle().fill(Color.gray.opacity(scheme == .dark ? 0.22 : 0.18))
                        .frame(width: tile, height: tile * 4 / 3)
                }
            }
        }
        .frame(width: Theme.previewWidth)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("主頁格狀預覽：新貼文 \(newTiles.count) 則，各取照片正中間的 3:4")
        .task(id: posts.map(\.id)) { await loadSharp() }
    }

    private func newTile(_ p: Post, width: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: width * 4 / 3)
            .overlay {
                if let img = sharp[p.id] ?? p.thumbnail {
                    Image(nsImage: img).resizable().interpolation(.high).scaledToFill()   // centered fill = middle 3:4
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if p.isCarousel {
                    Image(systemName: "square.fill.on.square.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 2).padding(6)
                }
            }
    }

    /// The list thumbnails are small; tiles get a sharper copy once it is read.
    private func loadSharp() async {
        for p in newTiles where sharp[p.id] == nil {
            let url = p.url
            let img = await Task.detached(priority: .utility) { AppModel.thumbnail(url, maxPixel: 600) }.value
            if let img { sharp[p.id] = img }
        }
    }
}
