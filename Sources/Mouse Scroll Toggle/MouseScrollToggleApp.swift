import SwiftUI
import AppKit

/// 表示モード
enum DisplayMode: String, CaseIterable, Identifiable {
    case menuBar    // メニューバーのみ
    case dock       // Dockのみ
    case both       // 両方表示

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .menuBar: return "Menu Bar Only"
        case .dock:    return "Dock Only"
        case .both:    return "Menu Bar and Dock"
        }
    }
}

enum DisplayModeStore {
    static let key = "ScrollToggle.displayMode"
    static let defaultValue: DisplayMode = .both

    static func load() -> DisplayMode {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let mode = DisplayMode(rawValue: raw) else {
            return defaultValue
        }
        return mode
    }

    /// ノッチを考慮した実効モード。ノッチ付きディスプレイでは「メニューバーのみ」を
    /// 「メニューバーとDock」に読み替える（アイコンがノッチの陰に隠れて操作不能になるのを防ぐ）。
    /// 保存値そのものは書き換えない（非破壊。ノッチが外れれば元の設定に戻る）。FILL Id と同じ。
    static func resolved() -> DisplayMode {
        let mode = load()
        if mode == .menuBar && NotchDetector.hasNotchedDisplay {
            return defaultValue
        }
        return mode
    }
}

extension Notification.Name {
    static let displayModeChanged = Notification.Name("ScrollToggle.displayModeChanged")
    static let openSettingsRequested = Notification.Name("ScrollToggle.openSettingsRequested")
}

@main
struct ScrollToggleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // ⌘キーを押しながら起動 → 表示モードのみリセット
        if NSEvent.modifierFlags.contains(.command) {
            UserDefaults.standard.removeObject(forKey: DisplayModeStore.key)
            AppDelegate.shouldShowResetAlert = true
        }
    }

    var body: some Scene {
        // 設定ウィンドウは AppDelegate 側で自前の NSWindow を表示する。
        // Settings シーンは Scene 要件を満たすためのダミー（このシーンは開かれない）。
        // アプリメニュー / Dock メニューの「設定...」は同じ openSettingsWindow を呼ぶため
        // 二重ウィンドウにならない。
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings...") {
                        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
                    }
                    .keyboardShortcut(",")
                }
                CommandGroup(replacing: .help) {
                    Button("Mouse Scroll Toggle Help") {
                        appDelegate.openHelp()
                    }
                    .keyboardShortcut("?", modifiers: .command)
                }
            }
    }
}
