import SwiftUI
import UserNotifications
import IGPubCore

/// Posts a macOS notification when the launch check finds a newer version. Clicking it brings the app forward
/// with the update window open. Only in the packaged app: notifications need a bundle identifier.
@MainActor
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotifier()
    nonisolated private static let id = "img_to_ig.update"
    /// Called when the user clicks the notification.
    var onOpen: (() -> Void)?

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func post(version: String, current: String) async {
        guard let center else { return }
        center.delegate = self
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "img_to_ig 有新版 \(version)"
        content.body = "目前是 \(current)。點這裡開啟更新。"
        content.sound = .default
        center.removeDeliveredNotifications(withIdentifiers: [Self.id])
        try? await center.add(UNNotificationRequest(identifier: Self.id, content: content, trigger: nil))
    }

    /// Show the banner even while the app is in front (macOS hides it otherwise).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == Self.id else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            onOpen?()
        }
    }
}

/// The window that pops up at launch when a newer version exists, and follows the download and install.
struct UpdateSheet: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            switch model.updateState {
            case .available(let r):
                header("有新版 \(r.version)", "目前版本 \(model.currentVersion)")
                if !r.notes.isEmpty {
                    ScrollView {
                        Text(verbatim: r.notes).igCallout()   // plain text, never markdown
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 220)
                    .padding(Theme.Space.m)
                    .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.line, lineWidth: 1))
                }
                Text("更新檔會先檢查是同一個簽章身分簽的才安裝，完成後 App 會自動重新開啟。").igCallout()
                HStack(spacing: Theme.Space.s) {
                    Button("查看說明") { NSWorkspace.shared.open(r.pageURL) }.buttonStyle(.igPlainSmall)
                    Spacer()
                    Button("稍後") { model.showUpdateSheet = false }
                        .buttonStyle(.igText).keyboardShortcut(.cancelAction)
                    Button("立即更新") { Task { await model.installUpdate() } }
                        .buttonStyle(.igPrimary).keyboardShortcut(.defaultAction).disabled(model.busy)
                }
                if model.busy {
                    Text("正在發佈，完成後才能更新。").igCallout()
                }
            case .downloading:
                progress("下載並驗證新版中…")
            case .installing:
                progress("安裝中，完成後會自動重新開啟")
            case .failed(let msg, _):
                header("更新沒有完成", nil)
                Text(verbatim: msg).igBody()
                HStack {
                    Spacer()
                    Button("關閉") { model.showUpdateSheet = false }
                        .buttonStyle(.igPrimary).keyboardShortcut(.defaultAction)
                }
            case .idle, .checking, .upToDate:
                EmptyView()
            }
        }
        .padding(Theme.Space.xxl)
        .frame(width: 520)
        .background(Theme.surface)
    }

    private func header(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.Font.title).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).igCallout() }
        }
    }

    private func progress(_ title: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            ProgressView().controlSize(.small)
            Text(title).font(Theme.Font.bodyStrong).foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
