import SwiftUI
import IGPubCore

/// One post as it will be published: the preview on the left, everything you can set for it on the right.
/// A carousel is one editor (page through its photos); singles get one editor each.
struct PostEditor: View {
    @EnvironmentObject var model: AppModel
    let ids: [UUID]
    let carousel: Bool
    let number: Int

    @State private var index = 0
    @State private var pending: CGPoint?
    @State private var pendingName = ""
    @FocusState private var nameFocused: Bool

    private var shown: [PhotoItem] { ids.compactMap { id in model.items.first { $0.id == id } } }
    private var currentID: UUID? { shown.indices.contains(index) ? shown[index].id : shown.first?.id }

    private func item<T>(_ kp: WritableKeyPath<PhotoItem, T>, default d: T) -> Binding<T> {
        Binding(get: { currentID.flatMap { id in model.items.first { $0.id == id }?[keyPath: kp] } ?? d },
                set: { v in
                    if let id = currentID, let i = model.items.firstIndex(where: { $0.id == id }) { model.items[i][keyPath: kp] = v }
                })
    }

    private var captionBinding: Binding<String> { carousel ? $model.carouselCaption : item(\.caption, default: "") }
    private var collabBinding: Binding<String> { carousel ? $model.carouselCollaboratorsText : item(\.collaboratorsText, default: "") }
    private var aiBinding: Binding<Bool> { carousel ? $model.carouselAI : item(\.aiGenerated, default: false) }
    private var altBinding: Binding<String> {
        Binding(get: { item(\.options, default: ItemOptions()).wrappedValue.altText },
                set: { v in var o = item(\.options, default: ItemOptions()).wrappedValue; o.altText = v; item(\.options, default: ItemOptions()).wrappedValue = o })
    }
    private var tags: [UserTag] { item(\.options, default: ItemOptions()).wrappedValue.tags }

    var body: some View {
        let list = shown
        let collab = Usernames.parseList(collabBinding.wrappedValue) ?? []
        HStack(alignment: .top, spacing: Theme.Space.xl) {
            PostPreview(items: list, caption: captionBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines),
                        collaborators: collab, aiGenerated: aiBinding.wrappedValue,
                        username: model.config?.username, width: 375, index: $index,
                        onPlaceTag: { _, pt in pending = pt; pendingName = ""; nameFocused = true })
            form
        }
        .card()
        .onChange(of: index) { _, _ in pending = nil }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                Text(carousel ? "多張貼文（\(shown.count) 張）" : "第 \(number) 則 · \(shown.first?.url.lastPathComponent ?? "")")
                    .font(Theme.Font.title).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("文案").font(Theme.Font.label).foregroundStyle(Theme.ink)
                CaptionEditor(text: captionBinding, label: "文案")
                Text("選填。按 Enter 換行，可以直接打 #主題標籤 和 @帳號（最多 30 個標籤、20 個 @）。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.ink3)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("合作夥伴（最多 \(PostExtras.maxCollaborators) 個帳號）").font(Theme.Font.label).foregroundStyle(Theme.ink)
                UsernameChipsField(text: collabBinding, max: PostExtras.maxCollaborators, frequent: model.frequentCollaborators)
                    .id(carousel ? "carousel" : currentID.map(\.uuidString) ?? "")   // a fresh field (and draft) per photo
                Text("對方必須是公開帳號，名稱要打對，否則 Instagram 會拒絕整則貼文。").font(Theme.Font.caption).foregroundStyle(Theme.ink3)
                Toggle("這則貼文是 AI 生成的", isOn: aiBinding).toggleStyle(.checkbox).font(Theme.Font.callout)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: Theme.Space.s) {
                Text(carousel ? "目前這張：第 \(index + 1) 張 · \(shown.indices.contains(index) ? shown[index].url.lastPathComponent : "")" : "照片設定")
                    .font(Theme.Font.label).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack {
                    Text("替代文字").font(Theme.Font.callout).foregroundStyle(Theme.ink2)
                    Spacer()
                    let n = altBinding.wrappedValue.count
                    Text("\(String(n)) / \(String(ItemOptions.maxAltText))").font(Theme.Font.caption).monospacedDigit()
                        .foregroundStyle(n > ItemOptions.maxAltText ? Theme.danger : Theme.ink3)
                }
                TextField("給看不到照片的人聽的描述（選填）", text: altBinding, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.plain).font(Theme.Font.body)
                    .padding(Theme.Space.m)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.lineStrong, lineWidth: 1))
                    .accessibilityLabel("替代文字")
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("標記人").font(Theme.Font.callout).foregroundStyle(Theme.ink2)
                Text("點左邊的照片放標記位置，再填對方的帳號。對方必須是公開帳號。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.ink3)
                if pending != nil {
                    HStack(spacing: Theme.Space.s) {
                        TextField("@帳號", text: $pendingName).igField(mono: true).focused($nameFocused)
                            .onSubmit { commitTag() }
                        Button("加入") { commitTag() }.buttonStyle(.igPlainSmall)
                        Button("取消") { pending = nil }.buttonStyle(.igText)
                    }
                    if !pendingName.isEmpty, Usernames.normalize(pendingName) == nil {
                        Text("帳號只能有英文字母、數字、句點和底線，句點不能在頭尾或連續出現").font(Theme.Font.caption).foregroundStyle(Theme.danger)
                    }
                }
                ForEach(tags) { t in
                    HStack {
                        Text("@" + t.username).font(Theme.Font.mono).foregroundStyle(Theme.ink)
                        Spacer()
                        Button("移除") { removeTag(t.username) }.buttonStyle(.igText)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func mutateOptions(_ f: (inout ItemOptions) -> Void) {
        guard let id = currentID, let i = model.items.firstIndex(where: { $0.id == id }) else { return }
        f(&model.items[i].options)
    }

    private func commitTag() {
        guard let pt = pending, let n = Usernames.normalize(pendingName) else { return }
        guard !tags.contains(where: { $0.username.lowercased() == n.lowercased() }), tags.count < ItemOptions.maxTags else { return }
        mutateOptions { $0.tags.append(UserTag(username: n, x: Double(pt.x), y: Double(pt.y))) }
        pending = nil
    }

    private func removeTag(_ name: String) { mutateOptions { $0.tags.removeAll { $0.username == name } } }
}
