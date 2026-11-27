import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// ⌘起動でリセットされた場合に起動完了後ダイアログを出すためのフラグ
    static var shouldShowResetAlert: Bool = false

    private var statusItem: NSStatusItem?
    /// 隔離起動の案内より後で作る（作るとイベントタップの準備でアクセシビリティの許可を求めることがあるため）
    private lazy var manager = ScrollSettingsManager()
    private var appSwitchObserver: Any?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隔離起動（App Translocation）中なら、Finder での移動を案内する。ほかの起動時処理より先に行う。
        // 一時的な場所のままアクセシビリティの許可やログイン項目の登録をさせないため（SPAi と同じ理由）。
        // 移動すれば出なくなるので毎回出す。
        if AppTranslocation.isTranslocated(Bundle.main.bundleURL) {
            if !showTranslocationAlert() {
                NSApp.terminate(nil)
                return
            }
        }

        applyDisplayMode()

        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateAppearance()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayModeChanged),
            name: .displayModeChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSettings),
            name: .openSettingsRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollStateChanged),
            name: .scrollStateChanged,
            object: nil
        )

        // ディスプレイ構成の変化（外部ディスプレイの抜き差し・蓋の開閉）でノッチの有無が
        // 変わり得る。実効表示モードを再適用する（ノッチ出現時に「メニューバーのみ」→「両方」）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayModeChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        if Self.shouldShowResetAlert {
            Self.shouldShowResetAlert = false
            DispatchQueue.main.async { [weak self] in
                self?.showResetAlert()
            }
        }
    }

    private func showResetAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Display settings reset", comment: "Reset alert title")
        alert.informativeText = NSLocalizedString("Display mode has been reset to \"Menu Bar and Dock\".", comment: "Reset alert body")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))
        alert.runModal()
    }

    // MARK: - 隔離起動の案内

    /// 隔離起動の案内を出す。「このまま続ける」なら true、「終了」なら false。
    /// 元の場所がアプリケーションフォルダの中なら「いったん外へ出して戻す」案内にする。
    /// 元の場所が分からなければ両方に効く文言にする（Glow Ai と同じ）。
    private func showTranslocationAlert() -> Bool {
        let original = AppTranslocation.originalURL(of: Bundle.main.bundleURL)
        let title: String
        let action: String
        switch original.map({ AppTranslocation.isInApplicationsFolder($0) }) {
        case true?:
            title = String(localized: "Move Mouse Scroll Toggle again in the Finder")
            action = String(localized: "Mouse Scroll Toggle is in the Applications folder, but it was moved there in a way that doesn't meet Apple's requirements. Quit Mouse Scroll Toggle, move it to the Desktop in the Finder, move it back to the Applications folder, and then open it again. Also, make sure to move it by itself, not together with other apps.")
        case false?:
            title = String(localized: "Move Mouse Scroll Toggle to the Applications folder")
            action = String(localized: "Quit Mouse Scroll Toggle, move it to the Applications folder in the Finder, and then open it again. Also, make sure to move it by itself, not together with other apps.")
        case nil:
            title = String(localized: "Move Mouse Scroll Toggle to the Applications folder")
            action = String(localized: "Quit Mouse Scroll Toggle, move it to the Applications folder in the Finder, and then open it again. If it's already in the Applications folder, move it to the Desktop and back again in the Finder. Also, make sure to move it by itself, not together with other apps.")
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = [
            String(localized: "Mouse Scroll Toggle is running from a temporary location because it was opened right after being downloaded."),
            String(localized: "For security, macOS runs apps obtained from the internet from a copy in a temporary location until you move them in the Finder."),
            action,
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "Quit"))             // 既定（Return）
        let continueButton = alert.addButton(withTitle: String(localized: "Continue Anyway"))
        continueButton.keyEquivalent = "\u{1b}"                           // Esc
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func displayModeChanged() {
        applyDisplayMode()
    }

    @objc private func scrollStateChanged() {
        updateAppearance()
    }

    // MARK: - 表示モード適用

    private func applyDisplayMode() {
        let mode = DisplayModeStore.resolved()

        switch mode {
        case .menuBar:
            NSApp.setActivationPolicy(.accessory)
        case .dock, .both:
            NSApp.setActivationPolicy(.regular)
        }

        let needStatusItem = (mode == .menuBar || mode == .both)
        if needStatusItem {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        }

        updateAppearance()
    }

    // MARK: - 設定ウィンドウ（自前実装）

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let tabs = SettingsTabViewController(manager: manager)
        let window = NSWindow(contentViewController: tabs)
        window.title = NSLocalizedString("Settings", comment: "Settings window title")
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ScrollToggleSettingsWindow")
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - メニュー構築（メニューバー & Dock 共通）

    /// - Parameter includeQuit: Dock メニューは macOS が最下部に標準の「終了」を付けるので false にする
    private func buildCommonMenu(includeQuit: Bool = true) -> NSMenu {
        let menu = NSMenu()

        // スクロールの状態はアイコンの見た目（とツールチップ）で分かるので、メニューには出さない
        if !AXIsProcessTrusted() {
            let axItem = NSMenuItem(
                title: NSLocalizedString("⚠️ Permission to control your Mac required", comment: "Accessibility warning"),
                action: #selector(requestAccessibility),
                keyEquivalent: "")
            axItem.target = self
            menu.addItem(axItem)
            menu.addItem(NSMenuItem.separator())
        }

        let prefsItem = NSMenuItem(
            title: NSLocalizedString("Settings...", comment: "Settings menu item"),
            action: #selector(showSettings),
            keyEquivalent: "")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let helpItem = NSMenuItem(
            title: NSLocalizedString("Help", comment: "Help menu item (common menu)"),
            action: #selector(openHelp),
            keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        guard includeQuit else { return menu }

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: NSLocalizedString("Quit", comment: "Quit menu item"),
            action: #selector(quit),
            keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Dock メニュー

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        return buildCommonMenu(includeQuit: false)
    }

    // MARK: - アクション

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc private func showSettings() {
        openSettingsWindow()
    }

    /// ヘルプウインドウを開く（ヘルプメニュー／共通メニュー〔Dock・メニューバー〕から呼ばれる）。
    /// タイトルはどこから開いてもヘルプメニューの項目名と同じ「Mouse Scroll Toggle ヘルプ」。
    @objc func openHelp() {
        HelpWindowController.shared.show(title: String(localized: "Mouse Scroll Toggle Help"))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - アイコン表示更新

    private func updateAppearance() {
        updateStatusBarAppearance()
        updateDockIconAppearance()
    }

    private func updateStatusBarAppearance() {
        guard let statusItem, let button = statusItem.button else { return }

        guard AXIsProcessTrusted() else {
            button.image = coloredSymbol("exclamationmark.triangle", color: NSColor(calibratedRed: 0.7, green: 0.2, blue: 0.0, alpha: 1.0))
            button.toolTip = NSLocalizedString("Permission to control your Mac required", comment: "Tooltip")
            statusItem.menu = nil
            button.target = self
            button.action = #selector(requestAccessibility)
            return
        }
        button.target = nil
        button.action = nil

        let effective = manager.effectiveScrollEnabled
        if effective {
            button.image = coloredSymbol("lightswitch.on.square", color: .systemBlue)
        } else {
            button.image = coloredSymbol("lightswitch.off.square", color: .systemRed)
        }
        button.toolTip = currentStateLabel()
        statusItem.menu = buildCommonMenu()
    }

    private func updateDockIconAppearance() {
        let mode = DisplayModeStore.resolved()
        guard mode == .dock || mode == .both else { return }

        if manager.effectiveScrollEnabled {
            NSApp.applicationIconImage = nil
        } else {
            if let path = Bundle.main.path(forResource: "icon-stop", ofType: "icns") {
                NSApp.applicationIconImage = NSImage(contentsOfFile: path)
            }
        }
    }

    /// SF Symbol をカラーで生成する（isTemplate = false）
    /// 大きさは FILL Id・SPAi のメニューバーアイコン（アプリアイコンを 19×19pt に縮小、見える部分は約 15.5pt）にそろえる。
    /// 18pt の記号は余白込みで 21×21pt（スイッチの見える部分は約 16×17pt）なので、縦横比を保って 19×19pt に
    /// 収めると見える部分が約 15.4pt になる。以前は 18×18pt に押し込んでいて約 14.5pt と小さかった（2026-11-26）。
    private func coloredSymbol(_ name: String, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let src = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }

        let size = NSSize(width: 19, height: 19)
        let result = NSImage(size: size, flipped: false) { rect in
            // 縦横比を保って中央に収める（記号によっては横長のため）
            let s = min(rect.width / src.size.width, rect.height / src.size.height)
            let w = src.size.width * s, h = src.size.height * s
            src.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            return true
        }
        result.isTemplate = false
        return result
    }

    // MARK: - ヘルパー

    private func currentStateLabel() -> String {
        if !AXIsProcessTrusted() {
            return NSLocalizedString("Permission to control your Mac required", comment: "State label")
        }
        if manager.stopTarget == .allApps {
            return NSLocalizedString("Mouse Scroll OFF (All Apps)", comment: "State label: stopped in all apps")
        }
        if manager.registeredAppIsActive {
            let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "App"
            return String(format: NSLocalizedString("Mouse Scroll OFF (%@)", comment: "State label auto off"), name)
        }
        return NSLocalizedString("Mouse Scroll ON", comment: "State label on")
    }
}
