import Foundation
import CoreGraphics
import AppKit
import Combine

/// スクロールを停止する方向
enum ScrollBlockAxis: String, CaseIterable, Identifiable {
    case both           // 垂直・水平の両方
    case verticalOnly   // 垂直方向のみ
    case horizontalOnly // 水平方向のみ

    var id: String { rawValue }

    /// 垂直方向を停止するか
    var stopsVertical: Bool { self != .horizontalOnly }
    /// 水平方向を停止するか
    var stopsHorizontal: Bool { self != .verticalOnly }

    /// 垂直・水平それぞれの停止の有無から作る。両方とも停止しない組み合わせは作れない（nil）
    init?(stopsVertical: Bool, stopsHorizontal: Bool) {
        switch (stopsVertical, stopsHorizontal) {
        case (true, true):   self = .both
        case (true, false):  self = .verticalOnly
        case (false, true):  self = .horizontalOnly
        case (false, false): return nil
        }
    }
}

enum ScrollBlockAxisStore {
    static let key = "ScrollToggle.blockAxis"
    static let defaultValue: ScrollBlockAxis = .both

    static func load() -> ScrollBlockAxis {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let axis = ScrollBlockAxis(rawValue: raw) else {
            return defaultValue
        }
        return axis
    }
}

/// スクロールを停止する対象
enum ScrollStopTarget: String, CaseIterable, Identifiable {
    case allApps        // すべてのアプリで停止
    case registeredApps // 登録アプリが最前面のときだけ停止

    var id: String { rawValue }
}

enum ScrollStopTargetStore {
    static let key = "ScrollToggle.stopTarget"
    static let defaultValue: ScrollStopTarget = .registeredApps

    static func load() -> ScrollStopTarget {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let target = ScrollStopTarget(rawValue: raw) else {
            return defaultValue
        }
        return target
    }
}

/// 押している間はスクロールの停止を解除する修飾キー（の組み合わせ）
enum OverrideModifier: String, CaseIterable, Identifiable {
    case command
    case option
    case shift
    case control
    case optionCommand
    case shiftCommand
    case optionShiftCommand

    var id: String { rawValue }

    /// 単独のキー（ポップアップで区切り線の上に並べる）
    static let singles: [OverrideModifier] = [.command, .option, .shift, .control]
    /// 組み合わせ（区切り線の下に並べる）
    static let combinations: [OverrideModifier] = [.optionCommand, .shiftCommand, .optionShiftCommand]

    /// ポップアップの表示名。単独のキーは記号＋キー名、組み合わせは記号だけ（幅を抑えるため）。
    /// キー名は日本語の macOS でも英字表記なのでローカライズしない
    var label: String {
        switch self {
        case .option:             return "⌥ option"
        case .control:            return "⌃ control"
        case .shift:              return "⇧ shift"
        case .command:            return "⌘ command"
        case .optionCommand:      return "⌥⌘"
        case .shiftCommand:       return "⇧⌘"
        case .optionShiftCommand: return "⌥⇧⌘"
        }
    }

    /// 対応する修飾キーのフラグ
    var flags: CGEventFlags {
        switch self {
        case .option:             return .maskAlternate
        case .control:            return .maskControl
        case .shift:              return .maskShift
        case .command:            return .maskCommand
        case .optionCommand:      return [.maskAlternate, .maskCommand]
        case .shiftCommand:       return [.maskShift, .maskCommand]
        case .optionShiftCommand: return [.maskAlternate, .maskShift, .maskCommand]
        }
    }

    /// 判定に使う修飾キー（⌥⌃⇧⌘）。caps lock・fn などは見ない
    static let relevantFlags: CGEventFlags = [.maskAlternate, .maskControl, .maskShift, .maskCommand]

    /// 押されている修飾キーが、この組み合わせとちょうど一致するか（余分なキーが押されていれば一致しない）
    func matches(_ eventFlags: CGEventFlags) -> Bool {
        eventFlags.intersection(Self.relevantFlags) == flags
    }
}

/// 修飾キーによる一時解除の設定（「一般」タブ）。既定はオン・⌘ command
enum ModifierOverrideStore {
    static let enabledKey = "ScrollToggle.modifierOverrideEnabled"
    static let modifierKey = "ScrollToggle.overrideModifier"
    static let defaultEnabled = true
    static let defaultModifier: OverrideModifier = .command

    /// 未保存なら `defaultEnabled`（`UserDefaults.bool` は未保存で false を返すので使わない）
    static func loadEnabled() -> Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func loadModifier() -> OverrideModifier {
        guard let raw = UserDefaults.standard.string(forKey: modifierKey),
              let modifier = OverrideModifier(rawValue: raw) else {
            return defaultModifier
        }
        return modifier
    }
}

extension Notification.Name {
    /// 修飾キーによる一時解除の設定が変わったときに投げる
    static let modifierOverrideChanged = Notification.Name("ScrollToggle.modifierOverrideChanged")
    static let scrollBlockAxisChanged = Notification.Name("ScrollToggle.scrollBlockAxisChanged")
    /// 停止状態（登録アプリ・停止対象・最前面アプリ）が変わったときに投げる。アイコン表示の更新用
    static let scrollStateChanged = Notification.Name("ScrollToggle.scrollStateChanged")
}

/// スクロールの停止を管理する。
/// - 停止は CGEventTap でスクロールイベントを破棄／片方向の移動量を 0 にして行う
/// - 停止対象: 「すべて」なら常に停止、「登録アプリ」なら登録アプリが最前面のときだけ停止
final class ScrollSettingsManager: ObservableObject {
    private let registeredAppsKey = "ScrollToggle.registeredBundleIDs"
    private let appBlockAxesKey = "ScrollToggle.appBlockAxes"

    /// 停止対象として登録されたバンドルID一覧
    @Published private(set) var registeredBundleIDs: Set<String> = []

    /// 登録アプリごとの停止する方向（バンドルID → 方向）。登録アプリには必ず値がある
    @Published private(set) var appBlockAxes: [String: ScrollBlockAxis] = [:]

    /// 最前面アプリのバンドルID
    private var frontmostBundleID: String = ""

    /// 停止対象
    @Published private(set) var stopTarget: ScrollStopTarget = ScrollStopTargetStore.load()

    /// 登録アプリが最前面かどうか
    private(set) var registeredAppIsActive: Bool = false

    /// 実効値（停止対象が「すべて」か、登録アプリが最前面なら false）
    var effectiveScrollEnabled: Bool {
        switch stopTarget {
        case .allApps:        return false
        case .registeredApps: return !registeredAppIsActive
        }
    }

    /// 停止する方向の既定値（「一般」タブで設定）。
    /// すべてのアプリで停止するときに使い、新しく登録したアプリの初期値にもなる
    private(set) var blockAxis: ScrollBlockAxis = ScrollBlockAxisStore.load()

    /// いま実際に停止する方向（イベントタップのコールバックから参照する）。
    /// 登録アプリが最前面で停止しているときだけ、そのアプリの設定を使う
    var activeBlockAxis: ScrollBlockAxis {
        if stopTarget == .registeredApps, registeredAppIsActive,
           let axis = appBlockAxes[frontmostBundleID] {
            return axis
        }
        return blockAxis
    }

    /// 修飾キーによる一時解除（イベントタップのコールバックから参照する）。nil なら機能オフ
    private(set) var overrideModifier: OverrideModifier? = ScrollSettingsManager.loadOverrideModifier()

    private static func loadOverrideModifier() -> OverrideModifier? {
        ModifierOverrideStore.loadEnabled() ? ModifierOverrideStore.loadModifier() : nil
    }

    private var appSwitchObserver: Any?
    private var blockAxisObserver: Any?
    private var modifierOverrideObserver: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// いまのジェスチャ（トラックパッド・Magic Mouse）を一時解除の修飾キーを押して始めたか。
    /// 慣性のイベントをどう扱うかに使う。始まりを見ていないうち（起動直後など）は従来どおりの動きにするため true
    private var gestureStartedWithOverride = true
    /// `scrollWheelEventScrollPhase` の値（CGScrollPhase）。began＝1、mayBegin＝128
    private static let scrollPhaseBegan: Int64 = 1
    private static let scrollPhaseMayBegin: Int64 = 128

    init() {
        loadRegisteredApps()
        startObservingAppSwitches()
        blockAxisObserver = NotificationCenter.default.addObserver(
            forName: .scrollBlockAxisChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.blockAxis = ScrollBlockAxisStore.load()
        }
        modifierOverrideObserver = NotificationCenter.default.addObserver(
            forName: .modifierOverrideChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.overrideModifier = ScrollSettingsManager.loadOverrideModifier()
        }
        checkFrontmostApp()
        syncEventTap()
    }

    deinit {
        if let obs = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        if let obs = blockAxisObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = modifierOverrideObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        removeEventTap()
    }

    // MARK: - 停止対象

    func setStopTarget(_ target: ScrollStopTarget) {
        stopTarget = target
        UserDefaults.standard.set(target.rawValue, forKey: ScrollStopTargetStore.key)
        stateDidChange()
    }

    // MARK: - アプリ登録管理

    func registerApps(_ bundleIDs: [String]) {
        let ownID = Bundle.main.bundleIdentifier
        let newIDs = bundleIDs.filter { $0 != ownID && !registeredBundleIDs.contains($0) }
        guard !newIDs.isEmpty else { return }
        registeredBundleIDs.formUnion(newIDs)
        // 新しく登録したアプリは、停止する方向の既定値で始める
        for id in newIDs { appBlockAxes[id] = blockAxis }
        saveRegisteredApps()
        saveAppBlockAxes()
        stateDidChange()
    }

    func unregisterApps(_ bundleIDs: Set<String>) {
        registeredBundleIDs.subtract(bundleIDs)
        for id in bundleIDs { appBlockAxes[id] = nil }
        saveRegisteredApps()
        saveAppBlockAxes()
        stateDidChange()
    }

    /// 登録アプリの停止する方向を変える
    func setBlockAxis(_ axis: ScrollBlockAxis, for bundleID: String) {
        guard registeredBundleIDs.contains(bundleID) else { return }
        appBlockAxes[bundleID] = axis
        saveAppBlockAxes()
    }

    /// 登録・停止対象の変更後に、停止状態とイベントタップとアイコン表示を揃える
    private func stateDidChange() {
        checkFrontmostApp()
        syncEventTap()
        NotificationCenter.default.post(name: .scrollStateChanged, object: nil)
    }

    private func loadRegisteredApps() {
        let saved = UserDefaults.standard.stringArray(forKey: registeredAppsKey) ?? []
        registeredBundleIDs = Set(saved)

        // アプリごとの方向。値の無い登録アプリ（この機能より前に登録したもの）は、
        // それまでの動きを変えないよう既定値で埋めて保存する
        let rawAxes = UserDefaults.standard.dictionary(forKey: appBlockAxesKey) as? [String: String] ?? [:]
        var axes: [String: ScrollBlockAxis] = [:]
        for id in registeredBundleIDs {
            axes[id] = rawAxes[id].flatMap(ScrollBlockAxis.init(rawValue:)) ?? blockAxis
        }
        appBlockAxes = axes
        if axes.count != rawAxes.count || axes.contains(where: { rawAxes[$0.key] != $0.value.rawValue }) {
            saveAppBlockAxes()
        }
    }

    private func saveRegisteredApps() {
        UserDefaults.standard.set(Array(registeredBundleIDs), forKey: registeredAppsKey)
    }

    private func saveAppBlockAxes() {
        UserDefaults.standard.set(appBlockAxes.mapValues(\.rawValue), forKey: appBlockAxesKey)
    }

    // MARK: - アプリ切り替え監視

    private func startObservingAppSwitches() {
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bid = app?.bundleIdentifier ?? ""
            self.frontmostBundleID = bid
            self.registeredAppIsActive = self.registeredBundleIDs.contains(bid)
            self.syncEventTap()
        }
    }

    private func checkFrontmostApp() {
        let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        frontmostBundleID = bid
        registeredAppIsActive = registeredBundleIDs.contains(bid)
    }

    // MARK: - CGEventTap

    private func syncEventTap() {
        if effectiveScrollEnabled {
            removeEventTap()
        } else {
            installEventTap()
        }
    }

    private func installEventTap() {
        guard eventTap == nil else { return }
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            return
        }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return nil }
                let manager = Unmanaged<ScrollSettingsManager>.fromOpaque(userInfo).takeUnretainedValue()
                return manager.handleTapEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[ScrollToggle] CGEventTap 作成失敗")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    /// イベントタップのコールバック本体。
    /// - both: スクロールイベントを破棄する
    /// - 片方向のみ: 停止する軸の移動量を 0 にして通す（トラックパッドのジェスチャのフェーズを崩さないため破棄しない）
    /// - 方向は activeBlockAxis（登録アプリが最前面ならそのアプリの設定、それ以外は既定値）
    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // タップがタイムアウト等で無効化されたら再有効化する
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }

        let overrideHeld = overrideModifier?.matches(event.flags) ?? false

        // トラックパッド・Magic Mouse のジェスチャの始まりで、一時解除の修飾キーを押していたかを覚える。
        // 修飾キーなしで始めたジェスチャの慣性は、あとから修飾キーを押しても止めたままにする
        // （押した時点で残りの慣性が通り、画面が流れてしまうため。2026-11-28 ユーザー指摘）。
        // 修飾キーを押して始めたジェスチャの慣性は従来どおり、押している間だけ通す（離すとすぐ止まる。ユーザー指定）
        let scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        if scrollPhase == Self.scrollPhaseBegan || scrollPhase == Self.scrollPhaseMayBegin {
            gestureStartedWithOverride = overrideHeld
        }
        let isMomentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0

        // 一時解除の修飾キーをちょうどその組み合わせで押している間は、止めずに通す。
        // そのとき修飾キーの情報は外す（残すとアプリが「⌥＋スクロール＝拡大縮小」などとして扱うため。InDesign で実例）
        if overrideHeld, !(isMomentum && !gestureStartedWithOverride), let modifier = overrideModifier {
            event.flags = event.flags.subtracting(modifier.flags)
            return Unmanaged.passUnretained(event)
        }

        switch activeBlockAxis {
        case .both:
            return nil
        case .verticalOnly:
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            return Unmanaged.passUnretained(event)
        case .horizontalOnly:
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
            return Unmanaged.passUnretained(event)
        }
    }

    private func removeEventTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        runLoopSource = nil
    }
}
