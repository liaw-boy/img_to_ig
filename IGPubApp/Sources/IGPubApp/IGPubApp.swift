import SwiftUI

@main
struct IGPubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @AppStorage(IconStyle.key) private var iconStyle: IconStyle = .symbols

    var body: some Scene {
        WindowGroup("img_to_ig") {
            Group {
                if model.showSetup {
                    SetupView()
                } else {
                    PublishView()
                }
            }
            .environmentObject(model)
            .environment(\.iconStyle, iconStyle)
            .tint(Theme.accent)
            .foregroundStyle(Theme.ink)
            .background(Theme.canvas)
            .frame(minWidth: 960, minHeight: 640)
            .task { await model.autoCheckIfDue() }
            .sheet(isPresented: $model.showKeychainNotice) {
                KeychainNoticeSheet().environmentObject(model).interactiveDismissDisabled()
            }
            .sheet(isPresented: updateSheetShown) {
                UpdateSheet().environmentObject(model).interactiveDismissDisabled()
            }
            .onAppear {
                appDelegate.model = model
                Self.enlargeWindowOnce()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .defaultSize(width: 1360, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}   // one main window: the update sheet and drafts assume a single one
            CommandGroup(after: .appInfo) {
                Button("檢查更新…") { Task { await model.checkForUpdates(manual: true) } }
            }
            CommandGroup(after: .appSettings) {
                Button("重新開啟設定精靈") { model.showSetup = true }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
            }
            CommandMenu("顯示") {
                Picker("圖示樣式", selection: $iconStyle) {
                    ForEach(IconStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environment(\.iconStyle, iconStyle)
                .tint(Theme.accent)
                .foregroundStyle(Theme.ink)
        }
        .windowResizability(.contentSize)
    }

    /// Waits for the Keychain notice to close (one sheet at a time) and only while there is something to show.
    private var updateSheetShown: Binding<Bool> {
        Binding(
            get: {
                model.showUpdateSheet && !model.showKeychainNotice
                    && UpdatePresentation(model.updateState, current: model.currentVersion) != nil
            },
            set: { if !$0 { model.showUpdateSheet = false } }
        )
    }

    /// macOS restores the last window size, so a bigger default would never show; enlarge once, then leave it to the user.
    private static func enlargeWindowOnce() {
        let key = "windowEnlargedV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        DispatchQueue.main.async {
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let screen = w.screen ?? NSScreen.main else { return }
            let v = screen.visibleFrame
            let size = NSSize(width: min(1360, v.width * 0.92), height: min(900, v.height * 0.92))
            if w.frame.width < size.width || w.frame.height < size.height {
                w.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height), display: true)
            }
            UserDefaults.standard.set(true, forKey: key)
        }
    }
}
