import SwiftUI
import UserNotifications
import IGPubCore

/// Installs the notification delegate before launch finishes, so a click on a notification that launches the
/// app (or arrives after a relaunch) is still routed to it. Also: closing the one window quits the app, but
/// never in the middle of a publish or an update.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false   // no tab bar "+" either: one main window
        MainActor.assumeIsolated { UpdateNotifier.shared.activate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model, !model.quittingForUpdate else { return .terminateNow }
            let message: String
            if model.busy { message = "正在發佈，現在結束可能讓貼文發到一半、或之後被重複發佈。請等發佈完成再結束。" }
            else if model.isUpdating { message = "正在更新，完成後 App 會自動重新開啟。" }
            else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "現在還不能結束 img_to_ig"
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            alert.runModal()
            return .terminateCancel      // if the window was closed, click the Dock icon to bring it back
        }
    }
}

/// Posts a macOS notification when the launch check finds a newer version while the app is in the background.
/// Clicking it brings the app forward with the update window open. Only in the packaged app: notifications
/// need a bundle identifier.
@MainActor
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotifier()
    nonisolated private static let id = "img_to_ig.update"
    /// A click that arrived before anyone could handle it (the app was still starting).
    private var pendingOpen = false
    /// Called when the user clicks the notification.
    var onOpen: (() -> Void)? {
        didSet { if pendingOpen, let onOpen { pendingOpen = false; onOpen() } }
    }

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func activate() { center?.delegate = self }

    /// Only when the app is not in front: in front, the update window already says it.
    func postIfInactive(version: String, current: String) async {
        guard !NSApp.isActive, let center else { return }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "img_to_ig 有新版 \(version)"
        content.body = "目前是 \(current)。點這裡開啟更新。"
        content.sound = .default
        center.removeDeliveredNotifications(withIdentifiers: [Self.id])
        try? await center.add(UNNotificationRequest(identifier: Self.id, content: content, trigger: nil))
    }

    /// Removes a delivered notification once it no longer applies (dismissed, updated, or no newer version).
    func clear() {
        center?.removePendingNotificationRequests(withIdentifiers: [Self.id])
        center?.removeDeliveredNotifications(withIdentifiers: [Self.id])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == Self.id else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if let onOpen { onOpen() } else { pendingOpen = true }
        }
    }
}

/// What to show for an update state. Shared by the update window and Settings,
/// so their wording and actions cannot drift apart.
struct UpdatePresentation {
    enum Action { case install, retry }
    let title: String
    let detail: String?
    let release: ReleaseInfo?
    let busy: Bool
    let action: Action?

    init?(_ state: UpdateState, current: String) {
        switch state {
        case .idle, .checking:
            return nil
        case .upToDate:
            self.init(title: "目前已是最新版（\(current)）", detail: nil, release: nil, busy: false, action: nil)
        case .available(let r):
            self.init(title: "有新版 \(r.version)（目前 \(current)）", detail: ReleaseNotes.plainText(r.notes), release: r, busy: false, action: .install)
        case .downloading:
            self.init(title: "下載並驗證新版中…", detail: nil, release: nil, busy: true, action: nil)
        case .installing:
            self.init(title: "安裝中，完成後會自動重新開啟", detail: nil, release: nil, busy: true, action: nil)
        case .failed(let msg, let r):
            self.init(title: "更新沒有完成", detail: msg, release: r, busy: false, action: r == nil ? nil : .retry)
        }
    }

    private init(title: String, detail: String?, release: ReleaseInfo?, busy: Bool, action: Action?) {
        self.title = title; self.detail = detail; self.release = release; self.busy = busy; self.action = action
    }

    var actionLabel: String { action == .retry ? "重試" : "立即更新" }
}

/// The buttons under an update message: install / retry, release notes, and dismiss.
struct UpdateActions: View {
    @EnvironmentObject var model: AppModel
    let p: UpdatePresentation
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let release = p.release {
                Button("查看說明") { NSWorkspace.shared.open(release.pageURL) }.buttonStyle(.igPlainSmall)
            }
            Spacer()
            Button(p.action == nil ? "關閉" : "稍後") { model.dismissUpdate() }
                .buttonStyle(.igText).keyboardShortcut(.cancelAction)
            if p.action != nil {
                Button(p.actionLabel) { Task { await model.installUpdate() } }
                    .buttonStyle(.igPrimary).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }
    }
}

/// The window that pops up when a newer version exists, and follows the download and install.
struct UpdateSheet: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if let p = UpdatePresentation(model.updateState, current: model.currentVersion) {
                if p.busy {
                    HStack(spacing: Theme.Space.m) {
                        ProgressView().controlSize(.small)
                        Text(p.title).font(Theme.Font.bodyStrong).foregroundStyle(Theme.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(p.title).font(Theme.Font.title).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                    if let detail = p.detail, !detail.isEmpty {
                        ScrollView {
                            Text(verbatim: detail).igCallout()   // plain text, never markdown
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: Theme.sheetScrollMaxHeight)
                        .padding(Theme.Space.m)
                        .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.line, lineWidth: 1))
                    }
                    if p.action == .install {
                        Text("更新檔會先檢查是同一個簽章身分簽的才安裝，完成後 App 會自動重新開啟。").igCallout()
                    }
                    if p.action != nil && model.busy {
                        Text("正在發佈，完成後才能更新。").igCallout()
                    }
                    UpdateActions(p: p)
                }
            }
        }
        .padding(Theme.Space.xxl)
        .frame(width: Theme.sheetWidth)
        .background(Theme.surface)
    }
}
