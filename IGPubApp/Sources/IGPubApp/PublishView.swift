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
            if model.reviewing {
                PageScaffold(eyebrow: "預覽", title: "確認發佈內容",
                             subtitle: "這是發佈後在 Instagram 的樣子，可以在這裡補文案、替代文字、標記人。確認沒問題再發佈。",
                             wide: true) {
                    ReviewContent()
                } footer: {
                    reviewFooter
                }
            } else {
                PageScaffold(eyebrow: "發佈", title: "選照片，按發佈",
                             subtitle: "把 JPEG 照片或資料夾拖進來，同名的 .txt 會自動當作文案。貼文發佈後立刻公開，無法由程式撤回。",
                             wide: true) {
                    content
                } footer: {
                    footer
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
        UpdateBanner()
        if !model.progress.isEmpty { ProgressPanel() }
        if let e = model.errorText { ErrorBanner(text: e, error: model.lastError) }
        HStack(spacing: Theme.Space.m) {
            ModePicker(mode: $model.mode)
            Spacer()
            Button(style == .darkroom ? "＋ 加入照片…" : "加入照片…") { importing = true }.buttonStyle(.igPlainSmall)
            Button("清空") { model.items = [] }.buttonStyle(.igText)
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
            Text("點縮圖選取或取消；按住 Shift 再點另一張，可連選中間所有照片。")
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
                        Text("只收 .jpg／.jpeg，單檔上限 \(c.maxBytes / (1024 * 1024)) MB。同名的 .txt 會自動當作文案。")
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

    // MARK: footer

    @ViewBuilder private var footer: some View {
        let n = model.chosen.count
        let carousel = model.mode == .carousel
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(carousel ? "已勾選 \(n) 張 · 合成 1 則多張貼文" : "已勾選 \(n) 張 · 每張各一則")
                .font(Theme.Font.label).foregroundStyle(Theme.ink)
            Text(model.publishProblem.flatMap { model.items.isEmpty ? nil : $0 } ?? "下一步會看到發佈後的預覽。")
                .font(Theme.Font.caption).foregroundStyle(Theme.ink3).lineLimit(1)
        }
        Spacer()
        if model.busy {
            Text("發佈中…").font(Theme.Font.callout).foregroundStyle(Theme.ink3)
        }
        Button(style == .darkroom ? "預覽並發佈 →" : "預覽並發佈…") { model.reviewing = true }
            .buttonStyle(.igPrimary)
            .disabled(model.busy || model.publishProblem != nil)
    }

    @ViewBuilder private var reviewFooter: some View {
        let n = model.chosen.count
        let carousel = model.mode == .carousel
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(carousel ? "1 則多張貼文 · \(n) 張" : "\(n) 則貼文")
                .font(Theme.Font.label).foregroundStyle(Theme.ink)
            Text(model.publishProblem ?? "按下發佈前，還會再確認一次。")
                .font(Theme.Font.caption).foregroundStyle(model.publishProblem == nil ? Theme.ink3 : Theme.danger).lineLimit(1)
        }
        Spacer()
        Button("返回修改") { model.reviewing = false }.buttonStyle(.igPlain).disabled(model.busy)
        Button(style == .darkroom ? "發佈 →" : "發佈…") { confirming = true }
            .buttonStyle(.igPrimary)
            .disabled(model.busy || model.publishProblem != nil)
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
            SidebarNavRow(symbol: "photo.on.rectangle", mark: "▸", title: "發佈", selected: true)
                .accessibilityAddTraits(.isSelected)
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
            TextField("文案（選填）", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.Font.body).lineSpacing(Theme.calloutLineSpacing)
                .lineLimit(2...5)
                .padding(Theme.Space.m)
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
            .strokeBorder(item.selected ? Theme.accent : Theme.line, lineWidth: item.selected ? 1.5 : 1))
    }
}

/// The page before publishing: every post as it will look, with its settings next to it.
private struct ReviewContent: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let picked = model.chosen
        if let e = model.errorText { ErrorBanner(text: e, error: model.lastError) }
        if model.mode == .carousel {
            PostEditor(ids: picked.map(\.id), carousel: true, number: 1)
        } else {
            ForEach(Array(picked.enumerated()), id: \.element.id) { i, p in
                PostEditor(ids: [p.id], carousel: false, number: i + 1)
            }
        }
        Text("預覽依 Instagram 的版型與裁切規則模擬，實際畫面以 Instagram 為準。")
            .font(Theme.Font.caption).foregroundStyle(Theme.ink3)
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
            Text(carousel ? "公開發佈 1 則輪播（\(picked.count) 張）？" : "公開發佈 \(picked.count) 則貼文？")
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


/// Shown at the top of the publish page when a newer version exists (or while updating / on a manual check).
struct UpdateBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        switch model.updateState {
        case .idle, .checking:
            EmptyView()
        case .upToDate:
            row(title: "目前已是最新版（\(model.currentVersion)）", detail: nil, release: nil, busy: false, canInstall: false)
        case .available(let r):
            row(title: "有新版 \(r.version)（目前 \(model.currentVersion)）", detail: r.notes, release: r, busy: false, canInstall: true)
        case .downloading:
            row(title: "下載並驗證新版中…", detail: nil, release: nil, busy: true, canInstall: false)
        case .installing:
            row(title: "安裝中，完成後會自動重新開啟", detail: nil, release: nil, busy: true, canInstall: false)
        case .failed(let msg, let r):
            row(title: "更新沒有完成", detail: msg, release: r, busy: false, canInstall: false)
        }
    }

    private func row(title: String, detail: String?, release: ReleaseInfo?, busy: Bool, canInstall: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.Font.bodyStrong).foregroundStyle(Theme.ink)
            if let detail, !detail.isEmpty {
                Text(verbatim: detail).font(Theme.Font.callout).foregroundStyle(Theme.ink2).lineLimit(5)   // plain text, never markdown
            }
            if !busy {
                HStack(spacing: Theme.Space.s) {
                    if canInstall {
                        Button("立即更新") { Task { await model.installUpdate() } }
                            .buttonStyle(.igPrimary).disabled(model.busy)
                    }
                    if let release { Button("查看說明") { NSWorkspace.shared.open(release.pageURL) }.buttonStyle(.igPlainSmall) }
                    Button(canInstall ? "稍後" : "關閉") { model.updateState = .idle }.buttonStyle(.igText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Theme.cardPaddingCompact, fill: Theme.accentSoft, border: Theme.accent.opacity(0.4))
    }
}
