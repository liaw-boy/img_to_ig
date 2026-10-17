import SwiftUI
import IGPubCore

private struct StepInfo {
    let title: String
    let short: String
    let summary: String
    let eyebrow: String
    let heading: String
    let subtitle: String
}

private let steps: [StepInfo] = [
    .init(title: "開始前", short: "開始前", summary: "了解需要準備什麼",
          eyebrow: "步驟 1／5 · 開始前",
          heading: "把照片發到 Instagram，只要選照片、按發佈。",
          subtitle: "第一次需要準備 3 個免費帳號，約 30～45 分鐘。每一步都有連結與說明，進度會自動保存，可以分次完成。"),
    .init(title: "Instagram 帳號", short: "IG 帳號", summary: "切換為專業帳號",
          eyebrow: "步驟 2／5 · 約 2 分鐘",
          heading: "把 Instagram 切換為專業帳號",
          subtitle: "個人帳號無法使用發佈 API。在手機的 Instagram App 裡操作，免費，也不需要 Facebook 粉絲專頁。"),
    .init(title: "Meta 開發者 App", short: "Meta App", summary: "取得 token",
          eyebrow: "步驟 3／5 · 約 15 分鐘",
          heading: "建立 Meta 開發者 App，取得 token",
          subtitle: "Instagram 只讓已登記的 App 代你發文。這個 App 只有你自己用，保持開發模式即可，不需要送審。"),
    .init(title: "儲存空間", short: "儲存空間", summary: "Cloudflare R2",
          eyebrow: "步驟 4／5 · 約 15 分鐘",
          heading: "設定儲存空間（Cloudflare R2）",
          subtitle: "Instagram 只能從網址抓圖，照片要先暫放到你自己的儲存空間，發佈完立刻刪除。免費額度就夠用。"),
    .init(title: "測試連線", short: "測試", summary: "確認一切可用",
          eyebrow: "步驟 5／5",
          heading: "測試連線",
          subtitle: "自動取得你的 Instagram user id，再檢查設定與儲存空間（上傳、讀回、刪除一個測試檔）。不會發佈任何貼文。"),
]

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.iconStyle) private var style

    var body: some View {
        let s = steps[min(max(model.step, 0), steps.count - 1)]
        AppShell {
            WizardSteps(items: steps.map { .init(title: $0.title, short: $0.short, summary: $0.summary) },
                        current: model.step, done: model.doneSteps) { model.step = $0 }
            Spacer(minLength: 0)
            if model.config != nil {
                Button { model.showSetup = false } label: {
                    SidebarNavRow(symbol: "arrow.uturn.backward", mark: "←", title: "返回發佈畫面")
                }
                .buttonStyle(.plain)
            }
        } main: {
            PageScaffold(eyebrow: s.eyebrow, title: s.heading, subtitle: s.subtitle) {
                switch model.step {
                case 0: IntroStep()
                case 1: AccountStep()
                case 2: MetaStep()
                case 3: StorageStep()
                default: TestResults(placeholder: true)
                }
                if let e = model.errorText, model.step != 4 {
                    ErrorBanner(text: e, error: model.lastError)
                }
            } footer: {
                footer
            }
        }
    }

    @ViewBuilder private var footer: some View {
        let dark = style == .darkroom
        Button(dark ? "← 上一步" : "上一步") { model.step = max(0, model.step - 1) }
            .buttonStyle(.igPlain)
            .disabled(model.step == 0)
        Spacer()
        if model.step < steps.count - 1 {
            Button(model.step == 0 ? (dark ? "開始設定 →" : "開始設定") : (dark ? "下一步 →" : "下一步")) {
                model.doneSteps.insert(model.step)
                model.step += 1
            }
            .buttonStyle(.igPrimary)
        } else {
            let passed = model.testLines.last?.ok == true && model.config != nil
            let start = Button(model.testLines.isEmpty ? "開始測試" : "重新測試") {
                Task { await model.runTest() }
            }
            .disabled(model.testing)
            if passed { start.buttonStyle(.igPlain) } else { start.buttonStyle(.igPrimary) }
            let enter = Button(dark ? "進入發佈畫面 →" : "進入發佈畫面") {
                model.doneSteps.insert(4)
                model.finishSetup()
            }
            .disabled(!passed)
            if passed { enter.buttonStyle(.igPrimary) } else { enter.buttonStyle(.igPlain) }
        }
    }
}

// MARK: shared pieces

/// Opens a web page. Same metrics in both styles; symbols adds an arrow icon, darkroom a "→".
struct LinkButton: View {
    let title: String
    let url: String
    var secondary = false
    @Environment(\.openURL) private var openURL
    @Environment(\.iconStyle) private var style
    var body: some View {
        if let u = URL(string: url) {
            let b = Button { openURL(u) } label: {
                HStack(spacing: Theme.Space.s) {
                    Text(title)
                    Group {
                        if style == .darkroom { Text("→") } else { Image(systemName: "arrow.up.right") }
                    }
                    .font(Theme.Font.callout)
                    .accessibilityHidden(true)
                }
            }
            .help(url)
            .accessibilityLabel("\(title)（開啟網頁）")
            if secondary { b.buttonStyle(.igSecondary) } else { b.buttonStyle(.igPlain) }
        }
    }
}

/// Instruction list; items accept Markdown (**bold**). Marker in a 24 pt slot: number box or "a.".
private struct Numbered: View {
    let items: [String]
    var start = 0
    @Environment(\.iconStyle) private var style
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, t in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                    Group {
                        if style == .darkroom {
                            Text(String(UnicodeScalar(UInt8(97 + start + i))) + ".").font(Theme.Font.monoStrong)
                                .foregroundStyle(Theme.accentText)
                        } else {
                            Text("\(start + i + 1)").font(Theme.Font.label).foregroundStyle(Theme.ink)
                                .frame(width: 24, height: 24)
                                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .frame(width: 24, alignment: .leading)
                    Text(LocalizedStringKey(t)).igBody(Theme.ink)
                }
            }
        }
    }
}

private struct PhaseHeading: View {
    let title: String
    let note: String
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.Font.bodyStrong).foregroundStyle(Theme.ink)
            Text(note).font(Theme.Font.callout).foregroundStyle(Theme.ink2)
        }
    }
}

/// Permission names: mono 13 in a subtle chip, may wrap.
private struct PermissionChips: View {
    let names: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("權限要包含：").font(Theme.Font.callout).foregroundStyle(Theme.ink2)
            ForEach(names, id: \.self) { Chip(text: $0, fill: Theme.canvas, color: Theme.ink, mono: true) }
        }
    }
}

/// Error from the core, with a jump to the step that fixes it.
struct ErrorBanner: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.iconStyle) private var style
    let text: String
    let error: IGPubError?
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            StatusSlot(kind: .failed)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(text).font(Theme.Font.bodyStrong).foregroundStyle(Theme.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let h = error?.hint { Text(h).igCallout() }
                if let fix = error?.fix, !(model.showSetup && model.step == fix.rawValue) {
                    Button(style == .darkroom ? "回到步驟 \(fix.rawValue + 1) 修正 →" : "回到步驟 \(fix.rawValue + 1) 修正") {
                        model.goFix(fix)
                    }
                    .buttonStyle(.igSecondarySmall)
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: Theme.cardPaddingCompact, fill: Theme.dangerSoft, border: Theme.danger.opacity(0.35))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("錯誤")
    }
}

struct SecretField: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let account: String
    let help: String
    @State private var value = ""

    var body: some View {
        let present = model.secretPresent[account] == true
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text(title).font(Theme.Font.label).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                StatusSlot(kind: present ? .ok : .pending)
                Text(present ? "已存入鑰匙圈" : "尚未存入").font(Theme.Font.caption)
                    .foregroundStyle(present ? Theme.success : Theme.ink3)
                    .frame(width: 72, alignment: .leading)
            }
            HStack(spacing: Theme.Space.s) {
                SecureField(present ? "已設定；要更換請貼上新的值" : "貼上 \(title)", text: $value)
                    .igField()
                    .accessibilityLabel(title)
                    .onSubmit(save)
                Button("存入鑰匙圈", action: save)
                    .buttonStyle(.igSecondary)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("移除") { model.removeSecret(account) }
                    .buttonStyle(IGTextButtonStyle(color: Theme.danger))
                    .disabled(!present)
                    .accessibilityLabel("從鑰匙圈移除 \(title)")
            }
            Text(help).font(Theme.Font.caption).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.saveSecret(account, value)
        value = ""
    }
}

/// Text field with inline validation: green "格式正確" or the core's red message. Fixed-height status line.
struct FieldRow: View {
    let title: String
    @Binding var text: String
    let prompt: String
    let help: String
    var mono = false
    var check: ((String) -> String?)?

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let problem: String? = trimmed.isEmpty ? nil : check?(text)
        let valid: Bool? = (trimmed.isEmpty || check == nil) ? nil : (problem == nil)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.Font.label).foregroundStyle(Theme.ink)
            TextField(prompt, text: $text)
                .igField(valid: valid, mono: mono)
                .autocorrectionDisabled()
                .accessibilityLabel(title)
            Group {
                if let valid {
                    StatusLine(ok: valid, text: valid ? "格式正確 · \(help)" : (problem ?? ""))
                } else {
                    Text(help).font(Theme.Font.caption).foregroundStyle(Theme.ink3)
                }
            }
            .frame(minHeight: 16, alignment: .topLeading)
        }
    }
}

/// Endpoint / bucket / region fields (wizard and Settings).
struct StorageFields: View {
    @Binding var cfg: AppConfig

    /// Shows only the account id; stores the full https endpoint (the CLI config format).
    private var accountIdBinding: Binding<String> {
        Binding(
            get: { AppConfig.r2AccountId(endpoint: cfg.endpoint) ?? cfg.endpoint },
            set: { cfg.endpoint = AppConfig.r2Endpoint(accountId: $0) ?? $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            FieldRow(title: "Cloudflare 帳戶 ID", text: accountIdBinding,
                     prompt: "32 個英數字，例如 a1b2c3…",
                     help: "只填帳戶 ID，網址由 App 自動組成", mono: true,
                     check: { v in
                         let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                         if AppConfig.isR2AccountId(t) { return nil }
                         if t.hasPrefix("https://") { return AppModel.fieldError(.storage) { $0.endpoint = t } }
                         return "帳戶 ID 是 32 個英數字，在 Cloudflare「帳戶詳細」裡"
                     })
            FieldRow(title: "Bucket 名稱", text: $cfg.bucket, prompt: "my-photo-bucket",
                     help: "你建立的 bucket 名稱", mono: true,
                     check: { v in AppModel.fieldError(.storage) { $0.bucket = v } })
            FieldRow(title: "Region", text: $cfg.region, prompt: "auto", help: "Cloudflare R2 請填 auto",
                     mono: true, check: { v in AppModel.fieldError(.storage) { $0.region = v } })
        }
    }
}

/// Label left, value right.
struct InfoRow<V: View>: View {
    let label: String
    @ViewBuilder var value: V
    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Text(label).font(Theme.Font.callout).foregroundStyle(Theme.ink2)
            Spacer(minLength: Theme.Space.m)
            value
        }
        .frame(minHeight: Theme.statusSlot.height)
        .accessibilityElement(children: .combine)
    }
}

// MARK: steps

private struct IntroStep: View {
    @Environment(\.iconStyle) private var style
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                RequirementCard(index: 1, icon: "camera", title: "Instagram 專業帳號",
                                text: "在手機 App 裡切換，免費，不需要粉絲專頁。", time: "約 2 分鐘")
                RequirementCard(index: 2, icon: "chevron.left.forwardslash.chevron.right", title: "Meta 開發者 App",
                                text: "讓 Instagram 允許這個 App 代你發文。自用不用送審。", time: "約 15 分鐘")
                RequirementCard(index: 3, icon: "cylinder.split.1x2", title: "Cloudflare R2 儲存空間",
                                text: "Instagram 只能從網址抓圖，照片在這裡暫放幾分鐘就刪。", time: "約 15 分鐘 · 可能要綁卡")
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Group {
                    if style == .darkroom {
                        StampLabel(text: "PRIVATE", color: Theme.ink)
                    } else {
                        Image(systemName: "lock").font(Theme.Font.title).foregroundStyle(Theme.ink)
                    }
                }
                .frame(width: Theme.statusSlot.width, height: Theme.statusSlot.height, alignment: .leading)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("你的資料只屬於你").font(Theme.Font.label).foregroundStyle(Theme.ink)
                    Text("token 與金鑰只存在這台 Mac 的鑰匙圈。App 只連到 Instagram 和你自己的儲存空間，沒有任何中間伺服器。照片暫存時用隨機檔名、短效網址，發佈完立刻刪除。")
                        .igBody()
                }
                Spacer(minLength: 0)
            }
            .card(fill: Theme.sidebar, border: Theme.sidebar)
        }
    }
}

private struct RequirementCard: View {
    let index: Int
    let icon: String
    let title: String
    let text: String
    let time: String
    @Environment(\.iconStyle) private var style
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Group {
                if style == .darkroom {
                    Text(String(format: "%02d ▸", index)).font(Theme.Font.monoStrong).foregroundStyle(Theme.accentText)
                } else {
                    Image(systemName: icon).font(Theme.Font.title).foregroundStyle(Theme.accent)
                }
            }
            .frame(height: 24, alignment: .leading)
            .accessibilityHidden(true)
            Text(title).font(Theme.Font.label).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(text).igCallout(Theme.ink3)
            Spacer(minLength: 0)
            Text(time).font(Theme.Font.caption).foregroundStyle(Theme.ink2)
        }
        .frame(minWidth: 120, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: Theme.cardPaddingCompact)
        .accessibilityElement(children: .combine)
    }
}

private struct AccountStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Numbered(items: [
                "開啟 Instagram App → 個人檔案 → 右上角選單 → 設定。",
                "找到「帳號類型與工具」→「切換為專業帳號」。",
                "類別選「創作者」或「商業」皆可，其餘依畫面完成。",
                "完成後，個人檔案或設定裡會看到「專業帳號」相關工具。",
            ])
            CautionNote(text: "選單名稱可能因 App 版本而不同，找「切換為專業帳號」即可。")
        }
        .card()
    }
}

private struct MetaStep: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let present = model.secretPresent[SecretName.accessToken] == true
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                LinkButton(title: "開啟 Meta「我的 Apps」", url: "https://developers.facebook.com/apps/", secondary: true)
                LinkButton(title: "還沒註冊開發者？", url: "https://developers.facebook.com/")
            }
            PhaseHeading(title: "A．建立 Meta App", note: "在 Meta 開發者網站完成，共 4 步。")
            Numbered(items: [
                "登入並完成開發者註冊。你的 Instagram 必須是**專業帳號**（商業或創作者）。",
                "按「建立應用程式」。名稱**不能含 IG、Insta、Gram、FB**，隨意取名並填你的信箱。",
                "使用案例：左側篩選選「內容管理」，勾 **管理 Instagram 的訊息和內容**。",
                "商家：選「我還不想連結商家資產管理組合」。要求頁沒有條件，直接下一步並建立。",
            ])
            PhaseHeading(title: "B．允許你的 Instagram 帳號", note: "讓這個 App 能代表你發佈。")
            Numbered(items: [
                "進入該使用案例的「**權限和功能**」，確認兩個權限顯示「可供測試」即可。**不要按「新增到應用程式檢閱」**，那會讓帳號永久變成技術供應商，無法復原。",
                "「**應用程式角色**」→ 新增人員 → **Instagram 測試人員**，填你的 Instagram 帳號。",
                "打開 Instagram App：設定 → 應用程式和網站 → 測試員邀請，接受邀請。",
            ], start: 4)
            PhaseHeading(title: "C．產生權杖並貼上", note: "權杖只顯示一次，貼錯就重新產生。")
            Numbered(items: [
                "回到「**含有 Instagram 登入的 API 設定**」，在「產生存取權杖」按「新增帳號」，再按「產生權杖」。Webhooks 不用設定。",
                "授權畫面只留「查看個人檔案和使用影音素材」與「**存取和發佈內容**」，其餘關閉，按「允許」。",
                "複製權杖，貼到下面的欄位。權杖 60 天有效。",
            ], start: 7)
            PermissionChips(names: ["instagram_business_basic", "instagram_business_content_publish"])
            CautionNote(text: "以上依 2026 年 10 月的 Meta 後台（繁體中文）整理，之後改版名稱可能不同。權杖只顯示一次，貼錯就重新產生。")
        }
        .card()
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SecretField(title: "Instagram access token", account: SecretName.accessToken,
                        help: "存入後只留在這台 Mac 的鑰匙圈，畫面不再顯示。約 60 天到期，App 會在到期前 \(AppModel.remindDays) 天提醒換發。")
            Rectangle().fill(Theme.line).frame(height: 1)
            InfoRow(label: "Instagram user id") {
                Text(model.draft.userId.isEmpty ? "測試連線時自動取得" : model.draft.userId)
                    .font(Theme.Font.mono)
                    .foregroundStyle(model.draft.userId.isEmpty ? Theme.ink3 : Theme.ink)
                    .textSelection(.enabled)
            }
            InfoRow(label: "token 狀態") {
                StatusSlot(kind: present ? .ok : .pending)
            }
        }
        .card()
    }
}

private struct StorageStep: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                LinkButton(title: "開啟 Cloudflare 控制台", url: "https://dash.cloudflare.com/", secondary: true)
                LinkButton(title: "R2 金鑰說明", url: "https://developers.cloudflare.com/r2/api/s3/tokens/")
            }
            Numbered(items: [
                "登入 Cloudflare → 左側「R2 Object Storage」→ 啟用（可能要綁信用卡）。",
                "按「Create bucket」建立一個私有 bucket，名稱用小寫英數與連字號，例如 my-photo-bucket。",
                "在 Cloudflare 的「帳戶詳細」找到**帳戶 ID**（32 個英數字），貼到下面即可，不用加網址。",
                "在「Manage API Tokens」建立 token：權限選 **Object Read & Write**，只套用在剛才的 bucket。",
                "複製 Access Key ID 與 Secret Access Key（Secret 只顯示一次）。",
            ])
        }
        .card()
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StorageFields(cfg: $model.draft)
            SecretField(title: "Access Key ID", account: SecretName.s3AccessKey, help: "R2 token 頁面的 Access Key ID。")
            SecretField(title: "Secret Access Key", account: SecretName.s3SecretKey,
                        help: "R2 token 頁面的 Secret Access Key，只顯示一次。")
        }
        .card()
    }
}

/// Result rows of the connection test (wizard and Settings). Reserves its height so nothing jumps.
struct TestResults: View {
    var placeholder = false
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if model.testLines.isEmpty && !model.testing {
                Text("按下「開始測試」後，結果會逐項顯示在這裡。")
                    .font(Theme.Font.callout).foregroundStyle(Theme.ink3)
                    .padding(Theme.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(model.testLines.enumerated()), id: \.element.id) { i, l in
                if i > 0 { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
                TestRow(line: l)
            }
            if model.testing {
                if !model.testLines.isEmpty { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
                HStack(spacing: Theme.Space.m) {
                    StatusSlot(kind: .running)
                    Text("檢查中…").font(Theme.Font.body).foregroundStyle(Theme.ink2)
                    Spacer()
                }
                .padding(Theme.Space.l)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 280, alignment: .top)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.line, lineWidth: 1))
    }
}

private struct TestRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.iconStyle) private var style
    let line: StepLine
    var body: some View {
        let ok = line.ok == true
        HStack(alignment: .top, spacing: Theme.Space.m) {
            StatusSlot(kind: ok ? .ok : .failed)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(line.title).font(ok ? Theme.Font.body : Theme.Font.bodyStrong)
                    .foregroundStyle(ok ? Theme.ink : Theme.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if line.detail != nil || line.account != nil {
                    (Text(line.detail ?? "") + Text(line.account.map { " \($0)" } ?? "").font(Theme.Font.mono))
                        .igCallout(ok ? Theme.ink3 : Theme.ink2)
                }
                if !ok, let fix = line.fix {
                    HStack(spacing: Theme.Space.m) {
                        Button(style == .darkroom ? "回到步驟 \(fix.rawValue + 1) 修正 →" : "回到步驟 \(fix.rawValue + 1) 修正") {
                            model.goFix(fix)
                        }
                        .buttonStyle(.igSecondarySmall)
                        if fix == .storage {
                            LinkButton(title: "R2 金鑰說明", url: "https://developers.cloudflare.com/r2/api/s3/tokens/")
                        } else if fix == .meta {
                            LinkButton(title: "Meta「我的 Apps」", url: "https://developers.facebook.com/apps/")
                        }
                    }
                    .padding(.top, Theme.Space.xs)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.l)
        .background(ok ? Color.clear : Theme.dangerSoft)
    }
}
