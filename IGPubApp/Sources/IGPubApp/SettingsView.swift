import SwiftUI
import AppKit
import UniformTypeIdentifiers
import IGPubCore

enum SettingsTab: Int, CaseIterable, Identifiable {
    case account, storage, defaults, privacy
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .account: return "帳號"
        case .storage: return "R2 金鑰"
        case .defaults: return "發佈預設"
        case .privacy: return "紀錄與隱私"
        }
    }
    var symbol: String {
        switch self {
        case .account: return "person.crop.circle"
        case .storage: return "key"
        case .defaults: return "slider.horizontal.3"
        case .privacy: return "lock.shield"
        }
    }
}

/// Settings window: fixed 680×520 for every tab; tab content scrolls.
struct SettingsView: View {
    static let size = CGSize(width: 680, height: 520)
    @State private var tab: SettingsTab = .account

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(tab: $tab)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    switch tab {
                    case .account: AccountTab()
                    case .storage: StorageTab()
                    case .defaults: DefaultsTab()
                    case .privacy: PrivacyTab()
                    }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Theme.canvas)
    }
}

private struct SettingsTabBar: View {
    @Binding var tab: SettingsTab
    @Environment(\.iconStyle) private var style
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(SettingsTab.allCases) { t in
                    let on = t == tab
                    Button { tab = t } label: {
                        VStack(spacing: Theme.Space.xs) {
                            Group {
                                if style == .darkroom {
                                    Text(String(format: "%02d", t.rawValue + 1)).font(Theme.Font.monoStrong)
                                } else {
                                    Image(systemName: t.symbol).font(Theme.Font.bodyStrong)
                                }
                            }
                            .frame(height: 20)
                            .accessibilityHidden(true)
                            Text(t.title).font(on ? Theme.Font.label : Theme.Font.caption)
                        }
                        .foregroundStyle(on ? Theme.accentText : Theme.ink2)
                        .frame(width: 96, height: 56)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.surface)
                                    .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t.title)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(Theme.Space.s)
            .frame(maxWidth: .infinity)
            .background(Theme.sidebar)
            Rectangle().fill(Theme.sidebarLine).frame(height: 1)
        }
    }
}

private struct SectionTitle: View {
    let text: String
    var trailing: String?
    var trailingColor: Color = Theme.ink3
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(Theme.Font.label).foregroundStyle(Theme.ink)
            Spacer()
            if let trailing { Text(trailing).font(Theme.Font.caption).foregroundStyle(trailingColor) }
        }
    }
}

// MARK: 帳號

private struct AccountTab: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.iconStyle) private var style
    @State private var pasting = false

    var body: some View {
        let cfg = model.config
        HStack(spacing: Theme.Space.l) {
            Circle().fill(Theme.sidebar).frame(width: 48, height: 48)
                .overlay(Text(String((cfg?.username ?? "?").prefix(1)).uppercased())
                    .font(Theme.Font.title).foregroundStyle(Theme.ink3))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(cfg?.username.map { "@\($0)" } ?? "帳號未連線")
                    .font(cfg?.username == nil ? Theme.Font.bodyStrong : Theme.Font.monoStrong).foregroundStyle(Theme.ink)
                HStack(spacing: Theme.Space.xs) {
                    Text("user id").font(Theme.Font.caption)
                    Text(cfg?.userId.isEmpty == false ? cfg!.userId : "—").font(Theme.Font.mono).textSelection(.enabled)
                    Text("· Instagram Login").font(Theme.Font.caption)
                }
                .foregroundStyle(Theme.ink3)
            }
            Spacer()
            StatusSlot(kind: model.isReady ? .ok : .pending)
            Text(model.isReady ? "已連線" : "未完成設定").font(Theme.Font.callout)
                .foregroundStyle(model.isReady ? Theme.success : Theme.warn)
        }
        .card(padding: Theme.cardPaddingCompact)

        VStack(alignment: .leading, spacing: Theme.Space.m) {
            let used = model.tokenAgeDays
            let left = model.tokenDaysLeft
            SectionTitle(text: "Access token",
                         trailing: used.map { u in "已使用 \(u) 天" + (left.map { " · 約 \($0) 天後到期" } ?? "") } ?? "尚未存入",
                         trailingColor: model.tokenWarn ? Theme.warn : Theme.ink3)
            ProgressView(value: Double(min(max(AppModel.tokenLifetimeDays - (left ?? AppModel.tokenLifetimeDays), 0),
                                           AppModel.tokenLifetimeDays)),
                         total: Double(AppModel.tokenLifetimeDays))
                .tint(model.tokenWarn ? Theme.warn : Theme.accent)
                .accessibilityLabel("token 已用掉的天數")
            Text("換發會用目前的 token 向 Instagram 換一個新的，有效期重新計算。token 一旦過期就不能換發，只能回 Meta 後台重新產生。")
                .igCallout()
            HStack(spacing: Theme.Space.m) {
                Button(style == .darkroom ? "立即換發 →" : "立即換發") { Task { await model.refreshToken() } }
                    .buttonStyle(.igPrimary)
                    .disabled(!model.canRefreshToken)
                    .help(model.refreshHelp)
                Button(pasting ? "收起" : "貼上新的 token…") { pasting.toggle() }
                    .buttonStyle(.igPlain)
            }
            if !model.canRefreshToken {
                Text(model.refreshHelp).font(Theme.Font.caption).foregroundStyle(Theme.ink3)
            }
            if pasting {
                SecretField(title: "新的 access token", account: SecretName.accessToken,
                            help: "存入後會重新計算使用天數。畫面不會顯示 token。")
            }
        }
        .card(padding: Theme.cardPaddingCompact)

        Toggle(isOn: $model.remindExpiry) {
            Text("token 到期前 \(AppModel.remindDays) 天提醒我").font(Theme.Font.body).foregroundStyle(Theme.ink)
        }
        .toggleStyle(.checkbox)
        .card(padding: Theme.cardPaddingCompact)

        Button(style == .darkroom ? "重新開啟設定精靈 →" : "重新開啟設定精靈") { model.showSetup = true }
            .buttonStyle(.igPlain)
    }
}

// MARK: R2 金鑰

private struct StorageTab: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SectionTitle(text: "Cloudflare R2", trailing: "修改後按「重新測試連線」，通過才會儲存")
            StorageFields(cfg: $model.draft)
        }
        .card(padding: Theme.cardPaddingCompact)
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SecretField(title: "Access Key ID", account: SecretName.s3AccessKey, help: "要更換時貼上新的值。")
            SecretField(title: "Secret Access Key", account: SecretName.s3SecretKey, help: "要更換時貼上新的值。")
        }
        .card(padding: Theme.cardPaddingCompact)
        HStack {
            Button("重新測試連線") { Task { await model.runTest() } }
                .buttonStyle(.igSecondary)
                .disabled(model.testing)
            Spacer()
        }
        TestResults()
    }
}

// MARK: 發佈預設

private struct DefaultsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var caption = ""
    @State private var maxMB = AppModel.maxMB
    @State private var message: (ok: Bool, text: String)?

    var body: some View {
        let has = model.config != nil
        if !has {
            CautionNote(text: "完成設定精靈並通過測試連線後，才能修改預設文案與檔案大小上限。")
        }
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionTitle(text: "預設文案", trailing: "\(String(caption.count)) / \(String(AppConfig.maxCaption))",
                         trailingColor: caption.count > AppConfig.maxCaption ? Theme.danger : Theme.ink3)
            TextEditor(text: $caption)
                .font(Theme.Font.body)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.s)
                .frame(height: 96)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .strokeBorder(caption.count > AppConfig.maxCaption ? Theme.danger : Theme.lineStrong, lineWidth: 1))
                .accessibilityLabel("預設文案")
            Text("照片沒有同名 .txt、也沒有另外輸入文案時使用。").font(Theme.Font.caption).foregroundStyle(Theme.ink3)
        }
        .card(padding: Theme.cardPaddingCompact)
        .disabled(!has)

        VStack(alignment: .leading, spacing: Theme.Space.m) {
            InfoRow(label: "預設發佈方式") {
                Picker("預設發佈方式", selection: $model.defaultMode) {
                    ForEach(PublishMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 260)
            }
            InfoRow(label: "單次最多發佈（單張模式）") {
                Stepper(value: $model.maxPerRun, in: AppModel.maxPerRunRange) {
                    Text("\(model.maxPerRun) 則").font(Theme.Font.mono).monospacedDigit()
                }
            }
            InfoRow(label: "單檔大小上限") {
                Stepper(value: $maxMB, in: 1...AppModel.maxMB) {
                    Text("\(maxMB) MB").font(Theme.Font.mono).monospacedDigit()
                }
                .disabled(!has)
            }
            Text("Instagram 的 JPEG 上限是 \(AppModel.maxMB) MB。").font(Theme.Font.caption).foregroundStyle(Theme.ink3)
            Toggle("超過上限的照片，發佈時自動縮小", isOn: $model.autoShrink).toggleStyle(.checkbox).font(Theme.Font.callout)
            Text(model.autoShrink
                 ? "會先在原尺寸降一點畫質，不夠才縮小尺寸，並轉成 sRGB；原檔不動。"
                 : "預設關閉：照原檔上傳，畫質完全不變。超過上限的照片 Instagram 可能會拒絕，那時再開啟這個選項。")
                .font(Theme.Font.caption).foregroundStyle(Theme.ink3)
        }
        .card(padding: Theme.cardPaddingCompact)

        HStack(spacing: Theme.Space.m) {
            if let m = message {
                StatusLine(ok: m.ok, text: m.text)
            }
            Spacer()
            Button("儲存") { save() }
                .buttonStyle(.igPrimary)
                .disabled(!has || caption.count > AppConfig.maxCaption)
        }
        .onAppear(perform: load)
    }

    private func load() {
        caption = model.config?.defaultCaption ?? ""
        maxMB = min(max((model.config?.maxBytes ?? AppModel.maxMB * 1024 * 1024) / (1024 * 1024), 1), AppModel.maxMB)
        message = nil
    }

    private func save() {
        guard var c = model.config else { return }
        c.defaultCaption = caption
        c.maxBytes = maxMB * 1024 * 1024
        if let e = model.saveConfig(c) {
            message = (false, e)
        } else {
            message = (true, "已儲存")
        }
    }
}

// MARK: 紀錄與隱私

private struct PrivacyTab: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmClear = false
    @State private var confirmRemove = false
    @State private var message: (ok: Bool, text: String)?

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()

    private var posts: [PostRecord] { PostRecord.group(model.history) }

    private static func postTitle(_ p: PostRecord) -> String {
        if p.photoCount > 1 { return "多張貼文 · \(p.photoCount) 張" }
        if p.isCarousel { return "多張貼文" }       // its other photos were posted again later, so the count is unknown
        return p.names.first ?? "（未記錄檔名）"
    }

    private var updateStatus: String {
        switch model.updateState {
        case .idle: return ""
        case .checking: return "檢查中…"
        case .upToDate: return "目前已是最新版"
        case .available(let r): return "有新版 \(r.version)"
        case .downloading, .installing: return "更新中…"
        case .failed(let m, _): return m
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionTitle(text: "版本與更新", trailing: "目前版本 \(model.currentVersion)")
                Toggle("啟動時自動檢查更新", isOn: $model.autoCheckUpdates).toggleStyle(.checkbox).font(Theme.Font.callout)
                HStack(spacing: Theme.Space.m) {
                    Button("立即檢查") { Task { await model.checkForUpdates(manual: true, showSheet: false) } }.buttonStyle(.igPlainSmall)
                    Text(verbatim: updateStatus).font(Theme.Font.caption).foregroundStyle(Theme.ink3).lineLimit(2)
                    if let p = UpdatePresentation(model.updateState, current: model.currentVersion), p.action != nil {
                        Button(p.actionLabel) { Task { await model.installUpdate() } }
                            .buttonStyle(.igPlainSmall).disabled(model.busy)
                    }
                }
                Text("檢查更新只會向 GitHub 查詢最新版本號，不會送出照片、帳號或 token。更新檔必須是同一個簽章身分簽的才會安裝。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.ink3)
            }
            .padding(Theme.Space.l)
            Rectangle().fill(Theme.lineSoft).frame(height: 1)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionTitle(text: "鑰匙圈裡的項目", trailing: "只有這一個")
                KeychainItemTable()
                Text("到「鑰匙圈存取」搜尋 img_to_ig 就能找到。macOS 詢問時輸入的是你的 Mac 登入密碼，App 拿不到它。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.ink3)
            }
            .padding(Theme.Space.l)
            Rectangle().fill(Theme.lineSoft).frame(height: 1)
            SectionTitle(text: "發佈歷史", trailing: "共 \(posts.count) 則貼文 · 只存在這台 Mac")
                .padding(Theme.Space.l)
            Rectangle().fill(Theme.lineSoft).frame(height: 1)
            if posts.isEmpty {
                Text("還沒有發佈紀錄。").font(Theme.Font.callout).foregroundStyle(Theme.ink3).padding(Theme.Space.l)
            }
            ForEach(Array(posts.prefix(200).enumerated()), id: \.element.id) { i, e in
                if i > 0 { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
                HStack(spacing: Theme.Space.m) {
                    Text(Self.postTitle(e))
                        .font(Theme.Font.callout).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Theme.Space.m)
                    Text(e.at.map { Self.dateFormat.string(from: $0) } ?? "日期未知").font(Theme.Font.caption)
                        .foregroundStyle(Theme.ink3)
                    Text(e.mediaId).font(Theme.Font.mono).foregroundStyle(Theme.ink2).textSelection(.enabled)
                        .lineLimit(1)
                }
                .padding(.horizontal, Theme.Space.l)
                .frame(height: Theme.controlHeight)
            }
            if posts.count > 200 {
                Text("只顯示最近 200 則。").font(Theme.Font.caption).foregroundStyle(Theme.ink3).padding(Theme.Space.l)
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.line, lineWidth: 1))
        .onAppear { model.reloadHistory() }

        HStack(alignment: .top, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("匯出診斷資訊").font(Theme.Font.label).foregroundStyle(Theme.ink)
                Text("卡關時把這個檔案傳給幫你的人。內含版本、設定檢查結果與最近的錯誤訊息，不含 token、金鑰與儲存空間位址。")
                    .igCallout()
                Spacer(minLength: 0)
                Button("匯出…") { exportDiagnostics() }.buttonStyle(.igSecondary)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .card(padding: Theme.cardPaddingCompact)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("清除發佈紀錄").font(Theme.Font.label).foregroundStyle(Theme.ink)
                Text("清除後，App 不再記得哪些照片發過，可能會重複發佈。Instagram 上的貼文不受影響。")
                    .igCallout()
                Spacer(minLength: 0)
                Button("清除紀錄…") { confirmClear = true }.buttonStyle(.igPlain)
                    .disabled(model.history.isEmpty)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .card(padding: Theme.cardPaddingCompact)
        }
        .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("移除所有資料").font(Theme.Font.label).foregroundStyle(Theme.dangerText)
                Text("刪除鑰匙圈裡的 token 與金鑰、設定和 App 偏好，回到第一次開啟的狀態。不會刪除你的儲存空間或 Meta App。")
                    .igCallout()
            }
            Spacer(minLength: Theme.Space.m)
            Button("移除所有資料…") { confirmRemove = true }.buttonStyle(.igDanger)
        }
        .card(padding: Theme.cardPaddingCompact, fill: Theme.dangerSoft, border: Theme.danger.opacity(0.35))

        if let m = message { StatusLine(ok: m.ok, text: m.text) }

        Color.clear.frame(height: 0)
            .alert("清除發佈紀錄？", isPresented: $confirmClear) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) {
                    if let e = model.clearHistory() { message = (false, e) } else { message = (true, "已清除發佈紀錄") }
                }
            } message: {
                Text("清除後，App 與 Python 命令列工具（共用同一份紀錄 ~/.img_to_ig/published.json）都不再記得哪些照片發過，之後可能會重複發佈。這個動作無法復原。")
            }
            .sheet(isPresented: $confirmRemove) {
                RemoveAllSheet(isPresented: $confirmRemove) { clearLedger in
                    if let e = model.removeAllData(clearLedger: clearLedger) {
                        message = (false, e)
                    } else {
                        DispatchQueue.main.async { NSApp.keyWindow?.performClose(nil) }
                    }
                }
            }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "img_to_ig-診斷資訊.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let text = model.diagnostics()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            message = (true, "已匯出到 \(url.lastPathComponent)")
        } catch {
            message = (false, "匯出失敗：\(error.localizedDescription)")
        }
    }
}

private struct RemoveAllSheet: View {
    @Binding var isPresented: Bool
    let perform: (Bool) -> Void
    @State private var alsoLedger = false
    @Environment(\.iconStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Group {
                if style == .darkroom {
                    StampLabel(text: "不可復原", color: Theme.danger)
                } else {
                    Image(systemName: "exclamationmark.triangle").font(Theme.Font.title).foregroundStyle(Theme.danger)
                }
            }
            .frame(width: Theme.statusSlot.width, height: Theme.statusSlot.height, alignment: .leading)
            .accessibilityHidden(true)
            Text("移除所有資料？").font(Theme.Font.title).foregroundStyle(Theme.ink)
            Text("會刪除鑰匙圈裡的 token 與兩把儲存空間金鑰、設定檔，以及設定精靈的進度與 App 偏好，然後回到設定精靈。這個動作無法復原。")
                .igBody()
            Toggle(isOn: $alsoLedger) {
                Text("同時清除發佈紀錄（Python 命令列工具也會受影響，之後可能重複發佈）")
                    .font(Theme.Font.callout).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            HStack(spacing: Theme.Space.m) {
                Spacer()
                Button("取消") { isPresented = false }
                    .buttonStyle(.igPlain)
                    .keyboardShortcut(.cancelAction)
                Button("移除") {
                    isPresented = false
                    perform(alsoLedger)
                }
                .buttonStyle(.igDanger)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(width: 460)
        .background(Theme.surface)
    }
}
