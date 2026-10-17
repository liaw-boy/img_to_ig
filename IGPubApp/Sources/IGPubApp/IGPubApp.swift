import SwiftUI

@main
struct IGPubApp: App {
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
            .onAppear {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
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
}

