import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

/// 設定ウインドウの中身（「一般」「登録」をツールバーのタブで切り替える）
/// - タブを切り替えるとウインドウのタイトルを選んだタブ名にする（システム設定と同じ見せ方）
/// - ウインドウの高さは各タブの内容に合わせて変わる
final class SettingsTabViewController: NSTabViewController {
    private static let contentWidth: CGFloat = 400  // FILL Id の設定ウインドウと同じ幅

    init(manager: ScrollSettingsManager) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar

        addTab(
            GeneralSettingsView(),
            label: String(localized: "General"),
            image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        )
        addTab(
            ScrollingSettingsView(),
            label: String(localized: "Scrolling"),
            image: Self.scrollTabIcon()
        )
        addTab(
            RegistrationSettingsView(manager: manager),
            label: String(localized: "Registration"),
            image: NSImage(systemSymbolName: "plus.app", accessibilityDescription: nil)
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 「スクロール」タブのアイコン（マウスの中に下矢印。SF Symbols に無いので自作 SVG をアセットに登録してある）
    /// - アセットはテンプレート画像なので、ダークモードや選択中の色は自動で付く
    /// - ツールバーは SF Symbols 以外の画像を 32pt 枠いっぱいに拡大して描く（オフスクリーン描画で実測）。
    ///   そのため 32pt 角の透明キャンバスの中央に、高さ 22pt（隣の computermouse より 2pt 大きめ）で描いた画像を渡す
    private static func scrollTabIcon() -> NSImage? {
        guard let source = NSImage(named: "icon-scroll") else {
            return NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)
        }
        let canvas: CGFloat = 32
        let height: CGFloat = 22
        let width = height * source.size.width / source.size.height
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
            source.draw(in: NSRect(x: (rect.width - width) / 2,
                                   y: (rect.height - height) / 2,
                                   width: width,
                                   height: height))
            return true
        }
        image.isTemplate = true
        return image
    }

    private func addTab<V: View>(_ view: V, label: String, image: NSImage?) {
        let hosting = NSHostingController(
            rootView: view
                .frame(width: Self.contentWidth)
        )
        hosting.sizingOptions = .preferredContentSize
        // ツールバー型の NSTabViewController は、選んだタブの子ビューコントローラの title をウインドウタイトルにする
        hosting.title = label
        let item = NSTabViewItem(viewController: hosting)
        item.label = label
        image?.accessibilityDescription = label
        item.image = image
        addTabViewItem(item)
    }
}

// MARK: - 一般

private struct GeneralSettingsView: View {
    @AppStorage(DisplayModeStore.key) private var rawMode: String = DisplayModeStore.defaultValue.rawValue
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var hasNotch = NotchDetector.hasNotchedDisplay

    private var mode: Binding<DisplayMode> {
        Binding(
            get: {
                let stored = DisplayMode(rawValue: rawMode) ?? DisplayModeStore.defaultValue
                // ノッチ環境では「メニューバーのみ」を選べない → 実効モード（両方表示）を選択表示する
                if stored == .menuBar && hasNotch { return DisplayModeStore.defaultValue }
                return stored
            },
            set: { newValue in
                rawMode = newValue.rawValue
                NotificationCenter.default.post(name: .displayModeChanged, object: nil)
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("[ScrollToggle] Failed to change login item: %@", error.localizedDescription)
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }

    var body: some View {
        Form {
            Section {
                // ノッチ環境では「メニューバーのみ」を無効化（アイコンがノッチの陰に隠れるため）
                RadioGroup(
                    selection: mode,
                    options: DisplayMode.allCases.map { ($0, $0.label) },
                    disabled: hasNotch ? [.menuBar] : []
                )

                if hasNotch {
                    Text("“Menu Bar Only” is unavailable on this Mac because the built-in display has a notch, where the menu bar icon could become hidden.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Display Mode")
            } footer: {
                Text("Hold ⌘ while launching to reset display mode to initial state (Menu Bar and Dock).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                    .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            hasNotch = NotchDetector.hasNotchedDisplay
        }
        // ディスプレイ構成が変わったらノッチ判定を更新（メニューバーのみの有効/無効に反映）
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hasNotch = NotchDetector.hasNotchedDisplay
        }
    }
}

// MARK: - スクロール

/// 「スクロール」タブ：停止する方向（既定値）と、修飾キーによる一時解除
private struct ScrollingSettingsView: View {
    @AppStorage(ScrollBlockAxisStore.key) private var rawBlockAxis: String = ScrollBlockAxisStore.defaultValue.rawValue
    @AppStorage(ModifierOverrideStore.enabledKey) private var overrideEnabled: Bool = ModifierOverrideStore.defaultEnabled
    @AppStorage(ModifierOverrideStore.modifierKey) private var rawOverrideModifier: String = ModifierOverrideStore.defaultModifier.rawValue

    private var blockAxis: Binding<ScrollBlockAxis> {
        Binding(
            get: { ScrollBlockAxis(rawValue: rawBlockAxis) ?? ScrollBlockAxisStore.defaultValue },
            set: { newValue in
                rawBlockAxis = newValue.rawValue
                NotificationCenter.default.post(name: .scrollBlockAxisChanged, object: nil)
            }
        )
    }

    private var overrideEnabledBinding: Binding<Bool> {
        Binding(
            get: { overrideEnabled },
            set: { newValue in
                overrideEnabled = newValue
                NotificationCenter.default.post(name: .modifierOverrideChanged, object: nil)
            }
        )
    }

    private var overrideModifier: Binding<OverrideModifier> {
        Binding(
            get: { OverrideModifier(rawValue: rawOverrideModifier) ?? ModifierOverrideStore.defaultModifier },
            set: { newValue in
                rawOverrideModifier = newValue.rawValue
                NotificationCenter.default.post(name: .modifierOverrideChanged, object: nil)
            }
        )
    }

    var body: some View {
        Form {
            Section {
                RadioGroup(selection: blockAxis, options: [
                    (.verticalOnly, "Vertical Only"),
                    (.horizontalOnly, "Horizontal Only"),
                    (.both, "Both"),
                ])
            } header: {
                Text("Directions to Stop")
            } footer: {
                // 登録アプリはアプリごとに「登録」タブで設定する。ここはそれ以外の場面と初期値
                Text("Used when stopping in all apps. Newly registered apps also start with this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 修飾キーを押している間だけ停止を解除する（既定はオフ）
            Section {
                Toggle("Scroll While Holding Modifier Keys", isOn: overrideEnabledBinding)
                    .toggleStyle(.switch)
                Picker("Modifier Keys", selection: overrideModifier) {
                    ForEach(OverrideModifier.singles) { Text(verbatim: $0.label).tag($0) }
                    Divider()
                    ForEach(OverrideModifier.combinations) { Text(verbatim: $0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(!overrideEnabled)
            } header: {
                Text("Temporary Override")
            } footer: {
                Text("While the selected keys are held, you can scroll even when scrolling is stopped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 登録

/// NSMenuItem のアクションをクロージャで受けるための小さなターゲット
private final class AddMenuHandler: NSObject {
    private var actions: [Int: () -> Void] = [:]

    func makeItem(title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(menuItemSelected(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        actions[item.tag] = action
        return item
    }

    @objc private func menuItemSelected(_ sender: NSMenuItem) {
        actions[sender.tag]?()
    }
}

extension NSImage {
    /// アプリのアイコンを Info.plist の CFBundleIconFile の .icns から直接読む。
    /// macOS 26 以降の NSWorkspace.icon(forFile:)／NSRunningApplication.icon は、Icon Composer 形式の
    /// アイコンを持たないアプリ（Adobe 製品など）のアイコンを縮めてグレーの角丸の枠に入れて返すため。
    /// 読めなければ従来の API に戻す。App-共有資料/アプリアイコンのグレー枠_macOS26以降.md を参照。
    static func appIcon(at appURL: URL) -> NSImage {
        if let name = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           !name.isEmpty {
            let file = name.hasSuffix(".icns") ? name : name + ".icns"
            if let image = NSImage(contentsOf: appURL.appendingPathComponent("Contents/Resources/\(file)")) {
                return image
            }
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }
}

/// 登録アプリ1件分の表示情報
private struct RegisteredAppItem: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage

    var id: String { bundleID }

    /// バンドルIDからアプリ名とアイコンを引く。見つからなければバンドルIDと汎用アイコンで表示する
    init(bundleID: String) {
        self.bundleID = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let displayName = FileManager.default.displayName(atPath: url.path)
            name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
            icon = NSImage.appIcon(at: url)
        } else {
            name = bundleID
            icon = NSWorkspace.shared.icon(for: .application)
        }
    }
}

private struct RegistrationSettingsView: View {
    @ObservedObject var manager: ScrollSettingsManager
    @State private var selection = Set<String>()
    @State private var isDropTargeted = false

    private var stopTarget: Binding<ScrollStopTarget> {
        Binding(
            get: { manager.stopTarget },
            set: { manager.setStopTarget($0) }
        )
    }

    private var isListEnabled: Bool { manager.stopTarget == .registeredApps }

    private func axisBinding(for bundleID: String) -> Binding<ScrollBlockAxis> {
        Binding(
            get: { manager.appBlockAxes[bundleID] ?? manager.blockAxis },
            set: { manager.setBlockAxis($0, for: bundleID) }
        )
    }

    private var items: [RegisteredAppItem] {
        manager.registeredBundleIDs
            .map { RegisteredAppItem(bundleID: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                RadioGroup(selection: stopTarget, options: [
                    (.allApps, "All Apps"),
                    (.registeredApps, "Registered Apps"),
                ])
            } header: {
                Text("Stop Scrolling In")
            }

            Section {
                appList
                    .disabled(!isListEnabled)
                    .opacity(isListEnabled ? 1 : 0.45)
            } header: {
                HStack {
                    Text("Registered Apps")
                    Spacer()
                    // 各行の右端にある垂直・水平ボタンの見出し
                    Text("Directions to Stop")
                }
            } footer: {
                Text("Scrolling stops in the highlighted directions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var appList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Image(nsImage: item.icon)
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        AxisToggles(axis: axisBinding(for: item.bundleID),
                                    isRowSelected: selection.contains(item.bundleID))
                    }
                    .tag(item.bundleID)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 200)
            // 行の無いところをクリックしたら選択を外す（List は自分では外さない）
            .background(DeselectOnEmptyClick { selection.removeAll() })
            .onDeleteCommand(perform: removeSelected)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.accentColor, lineWidth: 3)
                }
            }

            HStack(spacing: 0) {
                Button(action: showAddMenu) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 20)
                }
                Divider().frame(height: 16)
                Button(action: removeSelected) {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .disabled(selection.isEmpty)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .overlay(alignment: .top) { Divider() }
        }
    }

    // MARK: 追加・削除

    /// ＋ボタンのメニュー：起動中のアプリ一覧＋「アプリケーションフォルダから選択...」。
    /// 開くたびに作り直して、その時点の起動中アプリを出す。
    private func showAddMenu() {
        let menu = NSMenu()
        let handler = AddMenuHandler()

        let ownID = Bundle.main.bundleIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (id: String, name: String, icon: NSImage?)? in
                guard let id = app.bundleIdentifier, id != ownID,
                      !manager.registeredBundleIDs.contains(id) else { return nil }
                return (id, app.localizedName ?? id, app.bundleURL.map { NSImage.appIcon(at: $0) } ?? app.icon)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if running.isEmpty {
            let item = NSMenuItem(title: String(localized: "No Running Apps to Add"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for app in running {
                let item = handler.makeItem(title: app.name) { manager.registerApps([app.id]) }
                if let icon = app.icon?.copy() as? NSImage {
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(handler.makeItem(title: String(localized: "Choose from Applications Folder...")) {
            addWithOpenPanel()
        })

        // popUp は閉じるまで戻らないので、その間 handler は生きている
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(handler) {}
    }

    private func addWithOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        register(urls: panel.urls)
    }

    private func removeSelected() {
        guard !selection.isEmpty else { return }
        manager.unregisterApps(selection)
        selection.removeAll()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { register(urls: [url]) }
            }
        }
        return accepted
    }

    /// .app の URL からバンドルIDを取り出して登録する（アプリ以外は無視）
    private func register(urls: [URL]) {
        let ids = urls
            .filter { $0.pathExtension == "app" }
            .compactMap { Bundle(url: $0)?.bundleIdentifier }
        manager.registerApps(ids)
    }
}

// MARK: - 共通

/// 一覧の空き場所（行の無いところ）をクリックしたら `onEmptyClick` を呼ぶ（SPAi の実装を移植）。
/// SwiftUI の List（macOS）は空き場所のクリックで選択を外さないので、一覧の背面に置いたこのビューが
/// ウインドウ内のマウスダウンを見張り、自分の範囲内で、一覧（NSTableView）の行に当たっていないクリックを拾う。
/// イベントはそのまま流す（ドラッグ・右クリックの動作は変えない）。
private struct DeselectOnEmptyClick: NSViewRepresentable {
    let onEmptyClick: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onEmptyClick = onEmptyClick
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onEmptyClick = onEmptyClick
    }

    final class MonitorView: NSView {
        var onEmptyClick: () -> Void = {}
        private var monitor: Any?

        /// クリックは受けない（見張るだけ）
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  let hit = window.contentView?.hitTest(event.locationInWindow) else { return }
            // クリックした場所から上へたどり、この範囲に収まるスクロールビュー（＝一覧）を探す。
            // 設定のフォーム自体も NSTableView なので、範囲で見分けないとフォームの行を一覧の行と取り違える
            let myRect = convert(bounds, to: nil).insetBy(dx: -2, dy: -2)
            var view: NSView? = hit
            while let current = view {
                if let scroll = current as? NSScrollView,
                   myRect.contains(scroll.convert(scroll.bounds, to: nil)) {
                    guard let table = scroll.documentView as? NSTableView else { return }
                    if table.row(at: table.convert(event.locationInWindow, from: nil)) < 0 { onEmptyClick() }
                    return
                }
                view = current.superview
            }
        }
    }
}

/// 登録アプリの行の右端に置く、垂直・水平の停止ボタン（オンの方向を停止する）。
/// 両方ともオフにはできない（オンが1つだけのときにそれを押しても変わらない）
private struct AxisToggles: View {
    @Binding var axis: ScrollBlockAxis
    /// 行が選択中（アクセントカラーの背景）か。選択中はオンのボタンを白地＋ワインレッドの記号にして背景と見分けられるようにする
    var isRowSelected: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            button(symbol: "arrow.up.and.down",
                   help: "Stop Vertical Scrolling",
                   isOn: axis.stopsVertical) {
                ScrollBlockAxis(stopsVertical: !axis.stopsVertical, stopsHorizontal: axis.stopsHorizontal)
            }
            button(symbol: "arrow.left.and.right",
                   help: "Stop Horizontal Scrolling",
                   isOn: axis.stopsHorizontal) {
                ScrollBlockAxis(stopsVertical: axis.stopsVertical, stopsHorizontal: !axis.stopsHorizontal)
            }
        }
    }

    private func button(symbol: String, help: LocalizedStringKey, isOn: Bool,
                        next: @escaping () -> ScrollBlockAxis?) -> some View {
        Button {
            if let newAxis = next() { axis = newAxis }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 18)
                .foregroundStyle(foreground(isOn: isOn))
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(fill(isOn: isOn))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isOn ? Color.clear : stroke, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// オンのボタンの色。メニューバー・Dock の停止表示（赤）にそろえ、設定画面では目立ちすぎないワインレッドにする。
    /// ダークモードでは暗い背景に沈まないよう少し明るくする（2026-11-26）。
    private static let stopColor = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0xC8 / 255.0, green: 0x38 / 255.0, blue: 0x4F / 255.0, alpha: 1)   // #C8384F
        }
        return NSColor(srgbRed: 0x9E / 255.0, green: 0x1A / 255.0, blue: 0x33 / 255.0, alpha: 1)       // #9E1A33
    })

    private func fill(isOn: Bool) -> Color {
        guard isOn else { return .clear }
        return isRowSelected ? .white : Self.stopColor
    }

    private func foreground(isOn: Bool) -> Color {
        if isOn { return isRowSelected ? Self.stopColor : .white }
        return isRowSelected ? .white.opacity(0.75) : .secondary
    }

    private var stroke: Color {
        isRowSelected ? .white.opacity(0.6) : Color.secondary.opacity(0.5)
    }
}

/// ラジオボタンの縦並び。ボタン（円）をラベルの左に置く（システム設定と同じ見せ方）。
/// グループ形式のフォームで Picker(.radioGroup) を使うとボタンが行の右端に寄るため、FILL Id と同じく自前で描く。
private struct RadioGroup<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: LocalizedStringKey)]
    /// 選べない（淡色にする）選択肢
    var disabled: Set<Value> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                RadioRow(title: option.title,
                         isSelected: selection == option.value,
                         isDisabled: disabled.contains(option.value)) {
                    selection = option.value
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// ラジオ1行
private struct RadioRow: View {
    let title: LocalizedStringKey
    let isSelected: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(title)
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)   // .plain スタイルは自動で薄くならないため明示的にグレーアウト
    }
}
