import SwiftUI

/// What img_to_ig keeps in the Keychain: one item, three values. Shown before macOS asks, and in Settings.
struct KeychainItemTable: View {
    private let rows: [(String, String)] = [
        ("項目名稱", "img_to_ig"),
        ("種類", "應用程式密碼（service img_to_ig · account bundle）"),
        ("內容", "Instagram 存取權杖、儲存空間 Access Key ID、儲存空間 Secret Access Key"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(rows, id: \.0) { r in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                    Text(r.0).font(Theme.Font.callout).foregroundStyle(Theme.ink3).frame(width: 72, alignment: .leading)
                    Text(verbatim: r.1).font(r.0 == "項目名稱" ? Theme.Font.monoStrong : Theme.Font.callout).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// Shown once, right before the first macOS Keychain prompt, so the system dialog is not a surprise.
struct KeychainNoticeSheet: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("接下來 macOS 會問你鑰匙圈的權限").font(Theme.Font.title).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("img_to_ig 要讀取你之前存進鑰匙圈的設定。**只會讀下面這一個項目**，不會碰你鑰匙圈裡的其他密碼：")
                .igBody()
            KeychainItemTable()
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("你會看到的").font(Theme.Font.label).foregroundStyle(Theme.ink)
                Text("• 系統視窗寫著「img_to_ig 想使用你在鑰匙圈的『img_to_ig』裡儲存的機密資訊」，**可能會跳兩個**。")
                    .igCallout()
                Text("• 要輸入的是你的 **Mac 登入密碼**（開機密碼），輸入在 macOS 的視窗，App 看不到。").igCallout()
                Text("• 按「永遠允許」之後，這個版本不會再問；按「允許」則下次還會問。想要永遠不再被問，就按「永遠允許」。").igCallout()
                Text("• 按「拒絕」不會弄丟資料，只是這次讀不到，之後還可以再試。").igCallout()
            }
            HStack {
                Spacer()
                Button("我知道了，繼續") { model.acknowledgeKeychainNotice() }
                    .buttonStyle(.igPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(width: 520)
        .background(Theme.surface)
    }
}
