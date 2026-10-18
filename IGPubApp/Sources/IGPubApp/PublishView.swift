import SwiftUI
import UniformTypeIdentifiers
import IGPubCore

struct PublishView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.iconStyle) private var style
    @State private var importing = false
    @State private var confirming = false
    @State private var dropTargeted = false

    var body: some View {
        AppShell {
            MainSidebar()
        } main: {
            switch model.flow {
            case .select:
                PageScaffold(eyebrow: "步驟 1／3", title: "選擇圖片",
                             subtitle: "把 JPEG 照片或資料夾拖進來，勾選要發的照片。同名的 .txt 會自動當作文案。",
                             wide: true) {
                    content
                } footer: {
                    selectFooter
                }
            case .edit:
                PageScaffold(eyebrow: "步驟 2／3", title: "編輯內容",
                             subtitle: "補文案、替代文字、標記人，左邊即時顯示發佈後的樣子。照片在這一步就會先暫存上傳，之後按發佈就不用再等上傳。",
                             wide: true) {
                    EditContent()
                } footer: {
                    editFooter
                }
            case .send:
                PageScaffold(eyebrow: "步驟 3／3", title: "發佈",
                             subtitle: "最後確認。這是發佈後在 Instagram 的樣子；貼文發佈後立刻公開，這個 App 無法撤回。",
                             wide: true) {
                    SendContent()
                } footer: {
                    sendFooter
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.jpeg, .folder],
                      allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { model.add(urls: urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.add(urls: [url]) } }
                }
            }
            return true
        }
        .sheet(isPresented: $confirming) {
            ConfirmSheet(isPresented: $confirming).environmentObject(model).environment(\.iconStyle, style)
        }
        .task { await model.refreshQuota() }
    }

    // MARK: content column

    @ViewBuilder private var content: some View {
        if let e = model.errorText { ErrorBanner(text: e, error: model.lastError) }
        HStack(spacing: Theme.Space.m) {
            ModePicker(mode: $model.mode)
            Spacer()
            Button(style == .darkroom ? "＋ 加入照片…" : "加入照片…") { importing = true }.buttonStyle(.igPlainSmall)
            Button("清空") { model.clearItems() }.buttonStyle(.igText)
                .disabled(model.busy || model.items.isEmpty)
        }
        if !model.skipped.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(model.skipped, id: \.self) { s in
                    HStack(spacing: Theme.Space.s) {
                        Text(style == .darkroom ? "SKIP" : "略過").font(Theme.Font.monoCaption)
                        Text(s).font(Theme.Font.caption)
                    }
                    .foregroundStyle(Theme.warn)
                }
            }
        }
        if !model.items.isEmpty {
            Text("點縮圖選取或取消；按住 Shift 再點另一張，可連選中間所有照片。拖曳縮圖或按右鍵可以調整順序，多張貼文就是依這個順序排。")
                .font(Theme.Font.caption).foregroundStyle(Theme.ink3)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: Theme.Space.l, alignment: .top)],
                      alignment: .leading, spacing: Theme.Space.l) {
                ForEach($model.items) { $item in
                    PhotoTile(item: $item, order: model.chosen.firstIndex { $0.id == item.id }.map { $0 + 1 })
                }
            }
        }
        Button { importing = true } label: {
            DropFrame(highlighted: dropTargeted) {
                VStack(spacing: Theme.Space.s) {
                    Text(model.items.isEmpty ? "還沒有照片" : "再加入照片").font(Theme.Font.title).foregroundStyle(Theme.ink)
                    Text("把 JPEG 或資料夾拖到視窗裡，或按這裡選擇。").font(Theme.Font.callout).foregroundStyle(Theme.ink2)
                    if let c = model.config {
                        Text("只收 .jpg／.jpeg。同名的 .txt 會自動當作文案。超過 \(c.maxBytes / (1024 * 1024)) MB 的照片依「設定 → 發佈預設」處理（預設照原檔上傳，畫質不變）。")
                            .font(Theme.Font.caption).foregroundStyle(Theme.ink3)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(minHeight: model.items.isEmpty ? 160 : 72)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("加入照片：選擇 JPEG 或資料夾")
    }

    // MARK: footers

    private var postsSummary: String {
        let n = model.chosen.count
        return model.mode == .carousel ? "已勾選 \(n) 張 · 合成 1 則多張貼文" : "已勾選 \(n) 張 · 每張各一則"
    }

    @ViewBuilder private var selectFooter: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(postsSummary).font(Theme.Font.label).foregroundStyle(Theme.ink)
            Text(model.chosen.isEmpty ? "先勾選至少一張照片。" : "下一步：編輯文案與設定。")
                .font(Theme.Font.caption).foregroundStyle(Theme.ink3).lineLimit(1)
        }
        Spacer()
        Button(style == .darkroom ? "下一步：編輯內容 →" : "下一步：編輯內容") { model.go(.edit) }
            .buttonStyle(.igPrimary).disabled(!model.canGo(.edit))
    }

    @ViewBuilder private var editFooter: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(postsSummary).font(Theme.Font.label).foregroundStyle(Theme.ink)
            Text(model.publishProblem ?? "確認內容沒問題，就到下一步。")
                .font(Theme.Font.caption).foregroundStyle(model.publishProblem == nil ? Theme.ink3 : Theme.danger).lineLimit(1)
        }
        Spacer()
        Button("返回選擇圖片") { model.go(.select) }.buttonStyle(.igPlain)
        Button(style == .darkroom ? "下一步：發佈 →" : "下一步：發佈") { model.go(.send) }
            .buttonStyle(.igPrimary).disabled(!model.canGo(.send))
    }

    @ViewBuilder private var sendFooter: some View {
        let finished = model.progressFinished && model.chosen.isEmpty
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(model.busy ? "發佈中…" : postsSummary).font(Theme.Font.label).foregroundStyle(Theme.ink)
            Text(model.publishProblem.flatMap { model.chosen.isEmpty ? nil : $0 } ?? "按下發佈後還會再確認一次。")
                .font(Theme.Font.caption).foregroundStyle(Theme.ink3).lineLimit(1)
        }
        Spacer()
        if finished {
            Button("回到選擇圖片") { model.clearProgress(); model.go(.select) }.buttonStyle(.igPrimary)
        } else {
            Button("返回編輯內容") { model.go(.edit) }.buttonStyle(.igPlain).disabled(model.busy)
            Button(style == .darkroom ? "發佈 →" : "發佈…") { confirming = true }
                .buttonStyle(.igPrimary).disabled(model.busy || model.publishProblem != nil)
        }
    }
}

/// Main-app sidebar: account, nav, token block.
struct MainSidebar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(model.config?.username.map { "@\($0)" } ?? "帳號未連線")
                .font(model.config?.username == nil ? Theme.Font.label : Theme.Font.monoStrong)
                .foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Text(model.quota ?? "24 小時發佈額度：—").font(Theme.Font.caption).foregroundStyle(Theme.ink3).lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: Theme.sidebarRowHeight, alignment: .leading)
        VStack(spacing: Theme.Space.xs) {
            Text("發佈流程").font(Theme.Font.caption).foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Theme.Space.m)
            ForEach(FlowStep.allCases) { StepRow(step: $0) }
            Rectangle().fill(Theme.sidebarLine).frame(height: 1).padding(.vertical, Theme.Space.s)
            SettingsLink {
                SidebarNavRow(symbol: "gearshape", mark: "→", title: "設定")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("設定")
        }
        Spacer(minLength: 0)
        if model.config != nil { TokenBlock() }
    }
}

// MARK: pieces

private struct ModePicker: View {
    @Binding var mode: PublishMode
    var body: some View {
        HStack(spacing: 0) {
            ForEach(PublishMode.allCases) { m in
                let on = m == mode
                Button { mode = m } label: {
                    Text(m.rawValue).font(on ? Theme.Font.label : Theme.Font.callout)
                        .foregroundStyle(on ? Theme.ink : Theme.ink2)
                        .padding(.horizontal, Theme.Space.l).frame(height: Theme.controlHeightSmall - 8)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 6).fill(Theme.surface)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(Theme.Space.xs)
        .background(Theme.segment, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("發佈方式")
    }
}

struct CaptionEditor: View {
    @Binding var text: String
    let label: String
    var body: some View {
        let over = text.count > AppConfig.maxCaption
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            // TextEditor, not TextField: Return must insert a line break in a caption. No overlaid placeholder: it never
            // lines up with the caret, so the hint lives outside the box.
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(Theme.Font.body).lineSpacing(Theme.calloutLineSpacing)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 240)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.top, Theme.Space.m).padding(.bottom, Theme.Space.s)   // text starts a little below the border
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .strokeBorder(over ? Theme.danger : Theme.lineStrong, lineWidth: over ? 1.5 : 1))
                .accessibilityLabel(label)
            Text((over ? "超過上限：" : "") + "\(String(text.count)) / \(String(AppConfig.maxCaption))")
                .font(Theme.Font.caption).monospacedDigit()
                .foregroundStyle(over ? Theme.danger : Theme.ink3)
                .accessibilityLabel("字數 \(text.count)，上限 \(AppConfig.maxCaption)")
        }
    }
}

private struct PhotoTile: View {
    @EnvironmentObject var model: AppModel
    @Binding var item: PhotoItem
    let order: Int?        // position among the checked photos
    @Environment(\.iconStyle) private var style
    @State private var dropTargeted = false

    var body: some View {
        let name = item.url.lastPathComponent
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ZStack(alignment: .topLeading) {
                // A square that takes the tile's width; the photo only fills it (it must not size the tile).
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let t = item.thumbnail { Image(nsImage: t).resizable().scaledToFill() } else { Theme.sidebar }
                    }
                    .clipped()
                    .opacity(item.selected ? 1 : 0.45)
                if let order, item.selected {
                    Text(String(format: "%02d", order)).font(Theme.Font.monoStrong).foregroundStyle(.white)
                        .padding(.horizontal, Theme.Space.s).padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, alignment: .topTrailing).padding(Theme.Space.s)
                        .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius))
            .contentShape(Rectangle())
            .onTapGesture { model.tapItem(item.id, extend: NSEvent.modifierFlags.contains(.shift)) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(item.selected ? "已選取" : "未選取")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { item.selected.toggle() }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.Font.label).foregroundStyle(item.selected ? Theme.ink : Theme.ink2)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: Theme.Space.s) {
                    if item.bytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))
                            .font(Theme.Font.caption).foregroundStyle(Theme.ink3)
                    }
                    if item.bytes > (model.config?.maxBytes ?? Int.max) {
                        Text(model.autoShrink ? "發佈時縮小" : "超過 8 MB，原檔上傳").font(Theme.Font.caption).foregroundStyle(Theme.warnText)
                    }
                    if item.alreadyPublished {
                        Text(item.selected ? "已發過，仍會再發" : "已發過")
                            .font(Theme.Font.caption).foregroundStyle(Theme.warnText)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(Theme.Space.s)
        .background(item.selected ? Theme.surface : Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .strokeBorder(dropTargeted ? Theme.ink : (item.selected ? Theme.accent : Theme.line),
                          lineWidth: dropTargeted ? 3 : (item.selected ? 1.5 : 1)))
        .draggable(item.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            guard let s = ids.first, let dragged = UUID(uuidString: s), dragged != item.id else { return false }
            model.moveItem(dragged, before: item.id)      // dropped on a photo: goes just before it
            return true
        } isTargeted: { dropTargeted = $0 }
        .contextMenu {
            Button("移到最前面") { model.moveItem(item.id, before: model.items.first?.id) }
            Button("往前一格") { model.shiftItem(item.id, by: -1) }
            Button("往後一格") { model.shiftItem(item.id, by: 1) }
            Button("移到最後面") { model.moveItem(item.id, before: nil) }
        }
    }
}

/// One step of the flow in the sidebar: number (or a check once passed), title, a short status.
private struct StepRow: View {
    @EnvironmentObject var model: AppModel
    let step: FlowStep
    var body: some View {
        let current = model.flow == step
        let passed = step.rawValue < model.flow.rawValue
        let enabled = model.canGo(step) || current
        Button { model.go(step) } label: {
            HStack(spacing: Theme.Space.m) {
                ZStack {
                    Circle().fill(current ? Theme.accent : (passed ? Theme.success : Theme.segment))
                    if passed { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                    else { Text("\(step.rawValue + 1)").font(Theme.Font.label).foregroundStyle(current ? .white : Theme.ink2) }
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(step.title).font(current ? Theme.Font.label : Theme.Font.callout).foregroundStyle(Theme.ink)
                    if let d = detail { Text(d).font(Theme.Font.caption).foregroundStyle(Theme.ink3).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: Theme.controlHeight + 8)
            .background {
                if current { RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.surface).shadow(color: .black.opacity(0.08), radius: 1, y: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel("步驟 \(step.rawValue + 1)：\(step.title)")
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private var detail: String? {
        switch step {
        case .select: return model.chosen.isEmpty ? nil : "已選 \(model.chosen.count) 張"
        case .edit:
            guard model.flow != .select, !model.chosen.isEmpty else { return nil }
            return "已暫存 \(model.stagedReady) / \(model.chosen.count)"
        case .send: return nil
        }
    }
}

/// Step 2: every post with its settings next to a live preview, and the progress of the background upload.
private struct EditContent: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let picked = model.chosen
        StagingCard()
        if model.mode == .carousel {
            PostEditor(ids: picked.map(\.id), carousel: true, number: 1)
        } else {
            ForEach(Array(picked.enumerated()), id: \.element.id) { i, p in
                PostEditor(ids: [p.id], carousel: false, number: i + 1)
            }
        }
    }
}

private struct StagingCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let total = model.chosen.count, ready = model.stagedReady, failed = model.stagedFailed
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("先上傳到你的儲存空間").font(Theme.Font.label).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(ready) / \(total) 張").font(Theme.Font.callout).monospacedDigit().foregroundStyle(Theme.ink3)
            }
            ProgressBar(value: total == 0 ? 0 : Double(ready) / Double(total)).accessibilityLabel("暫存進度")
            Text(failed > 0
                 ? "有 \(failed) 張暫存失敗，不影響發佈：按發佈時會再上傳一次。"
                 : "這些暫存檔只放在你自己的 R2，隨機檔名；發佈完成會刪除，沒用到的會在下次打開 App 時清掉。")
                .font(Theme.Font.caption).foregroundStyle(failed > 0 ? Theme.warnText : Theme.ink3)
        }
        .card(padding: Theme.cardPaddingCompact)
    }
}

/// A finished-looking preview of one post (read-only; page through the photos of a multi-photo post).
private struct StaticPreview: View {
    @EnvironmentObject var model: AppModel
    let ids: [UUID]
    let caption: String
    let collaborators: [String]
    let ai: Bool
    var width = Theme.previewWidth
    @State private var index = 0
    var body: some View {
        PostPreview(items: ids.compactMap { id in model.items.first { $0.id == id } }, caption: caption,
                    collaborators: collaborators, aiGenerated: ai, username: model.config?.username, width: width, index: $index)
    }
}

/// Step 3: the final look of everything that will go out, and the progress once it does.
private struct SendContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.pageViewport) private var viewport

    /// A single post (carousel or one photo) fills the free space: as wide as fits, and short enough that the post card
    /// itself fits the visible height when the window allows. Several posts keep the grid size.
    private func loneWidth(firstAspect: Double?) -> CGFloat {
        guard viewport.width > 0 else { return Theme.previewWidth }
        let ratio = FeedCrop.ratio(for: firstAspect ?? 1)
        let fit = min(viewport.width - 2 * Theme.Space.xxl, (viewport.height - Theme.previewChrome) * ratio, Theme.previewMaxWidth)
        return max(Theme.previewWidth, fit.rounded(.down))
    }

    var body: some View {
        if !model.progress.isEmpty { ProgressPanel() }
        if let e = model.errorText { ErrorBanner(text: e, error: model.lastError) }
        let picked = model.chosen
        if !picked.isEmpty {
            // Centered in the page, and a lone preview sized to the window.
            VStack(spacing: Theme.Space.xl) {
                Text("發佈後會長這樣").font(Theme.Font.label).foregroundStyle(Theme.ink)
                if model.mode == .carousel {
                    StaticPreview(ids: picked.map(\.id), caption: model.carouselCaption.trimmingCharacters(in: .whitespacesAndNewlines),
                                  collaborators: Usernames.parseList(model.carouselCollaboratorsText) ?? [], ai: model.carouselAI,
                                  width: loneWidth(firstAspect: picked.first?.aspect))
                } else if picked.count == 1, let p = picked.first {
                    StaticPreview(ids: [p.id], caption: p.caption.trimmingCharacters(in: .whitespacesAndNewlines),
                                  collaborators: p.extras?.collaborators ?? [], ai: p.aiGenerated, width: loneWidth(firstAspect: p.aspect))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.previewWidth), spacing: Theme.Space.xl, alignment: .top)],
                              alignment: .center, spacing: Theme.Space.xl) {
                        ForEach(picked) { p in
                            StaticPreview(ids: [p.id], caption: p.caption.trimmingCharacters(in: .whitespacesAndNewlines),
                                          collaborators: p.extras?.collaborators ?? [], ai: p.aiGenerated)
                        }
                    }
                }
                Text("在主頁格狀會長這樣").font(Theme.Font.label).foregroundStyle(Theme.ink)
                    .padding(.top, Theme.Space.l)
                ProfileGridPreview(posts: (model.mode == .carousel ? Array(picked.prefix(1)) : picked).map {
                    .init(id: $0.id, url: $0.url, thumbnail: $0.thumbnail, isCarousel: model.mode == .carousel)
                })
                Text("主頁縮圖取照片正中間的 3:4，發佈時無法指定；要換位置，發佈後在 Instagram App 的「調整預覽」修改。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.ink3).multilineTextAlignment(.center)
                    .frame(maxWidth: Theme.previewWidth)
                Text("預覽依 Instagram 的版型與裁切規則模擬，實際畫面以 Instagram 為準。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.ink3).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: confirm + progress

private struct ConfirmSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.iconStyle) private var style
    @Binding var isPresented: Bool
    var body: some View {
        let picked = model.chosen
        let carousel = model.mode == .carousel
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Group {
                if style == .darkroom {
                    StampLabel(text: "不可撤回", color: Theme.accentText)
                } else {
                    Image(systemName: "exclamationmark.triangle").font(Theme.Font.title).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: Theme.statusSlot.width, height: Theme.statusSlot.height, alignment: .leading)
            .accessibilityHidden(true)
            Text(carousel ? "公開發佈 1 則多張貼文（\(picked.count) 張）？" : "公開發佈 \(picked.count) 則貼文？")
                .font(Theme.Font.title).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            (Text("會發佈到 ") + Text(model.config?.username.map { "@\($0)" } ?? "你的帳號").font(Theme.Font.monoStrong)
             + Text("。貼文發佈後立刻公開，") + Text("這個 App 無法撤回").bold() + Text("，只能到 Instagram 手動刪除。"))
                .igBody()
            HStack(spacing: Theme.Space.m) {
                Spacer()
                Button("取消") { isPresented = false }
                    .buttonStyle(.igPlain)
                    .keyboardShortcut(.cancelAction)
                Button("確定公開發佈") {
                    isPresented = false
                    Task { await model.publish() }
                }
                .buttonStyle(.igPrimary)
                .disabled(model.isUpdating)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(width: 480)
        .background(Theme.surface)
    }
}

/// Full-width card at the top of the content column.
private struct ProgressPanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let rows = model.progress
        let done = rows.filter { $0.state == .done }.count
        let failed = rows.contains { $0.state == .failed }
        let current = rows.first { if case .running = $0.state { return true }; return false }
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text(!model.progressFinished ? "發佈中" : failed ? "已停止" : "發佈完成")
                    .font(Theme.Font.title).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(done) / \(rows.count) 完成").font(Theme.Font.callout).monospacedDigit().foregroundStyle(Theme.ink3)
            }
            ProgressBar(value: fraction(rows))
                .accessibilityLabel("發佈進度")
                .accessibilityValue("\(done) / \(rows.count)")
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(rows) { r in
                    HStack(spacing: Theme.Space.m) {
                        StatusSlot(kind: kind(r.state))
                        Text(r.name).font(Theme.Font.body).foregroundStyle(Theme.ink)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Theme.Space.s)
                        Text(stateText(r.state)).font(Theme.Font.callout).lineLimit(1).fixedSize()
                            .foregroundStyle(r.state == .failed ? Theme.danger : Theme.ink3)
                    }
                    .frame(height: Theme.controlHeightSmall)
                }
            }
            HStack(spacing: Theme.Space.s) {
                ForEach(PublishStage.allCases, id: \.self) { st in chip(st, at: stage(current?.state)) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("目前階段：\(stage(current?.state)?.label ?? (model.progressFinished ? "結束" : "準備中"))")
            HStack {
                Text("Instagram 處理一張照片通常要幾秒到一分鐘。請不要關閉 App；若中途出錯，已上傳的暫存檔會自動刪除。")
                    .igCallout(Theme.ink3)
                Spacer(minLength: Theme.Space.m)
                Button("關閉") { model.clearProgress() }
                    .buttonStyle(.igPlainSmall)
                    .disabled(!model.progressFinished)
            }
        }
        .card()
    }

    private func kind(_ s: ItemProgress) -> StatusKind {
        switch s {
        case .done: return .published
        case .failed: return .failed
        case .running: return .running
        case .ready: return .ok
        case .pending, .notPublished: return .idle
        }
    }

    private func stage(_ s: ItemProgress?) -> PublishStage? {
        if case .running(let st)? = s { return st }
        return nil
    }

    @ViewBuilder private func chip(_ st: PublishStage, at: PublishStage?) -> some View {
        if model.progressFinished && !model.progress.contains(where: { $0.state == .failed }) {
            Chip(text: st.label, fill: Theme.successSoft, color: Theme.success)
        } else if let at, st < at {
            Chip(text: st.label, fill: Theme.successSoft, color: Theme.success)
        } else if st == at {
            Chip(text: st.label, fill: Theme.accentSoft, color: Theme.accentText, bold: true)
        } else {
            Chip(text: st.label, fill: Theme.canvas, color: Theme.ink3)
        }
    }

    private func fraction(_ rows: [ProgressRow]) -> Double {
        guard !rows.isEmpty else { return 0 }
        let sum = rows.reduce(0.0) { acc, r in
            switch r.state {
            case .done: return acc + 1
            case .ready: return acc + 0.6
            case .running(let s): return acc + Double(s.rawValue + 1) / Double(PublishStage.allCases.count + 1)
            default: return acc
            }
        }
        return sum / Double(rows.count)
    }

    private func stateText(_ s: ItemProgress) -> String {
        switch s {
        case .pending: return "等待中"
        case .running(.upload): return "上傳中…"
        case .running: return "Instagram 處理中…"
        case .ready: return "已就緒"
        case .done: return "已發佈"
        case .failed: return "失敗"
        case .notPublished: return "未發佈"
        }
    }
}

private struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.sidebar)
                Capsule().fill(Theme.accent).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: Theme.Space.s)
        .animation(.easeOut(duration: 0.25), value: value)
    }
}


