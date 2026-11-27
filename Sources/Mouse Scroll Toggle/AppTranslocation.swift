import Foundation

/// App Translocation（隔離属性付きのアプリを Finder で移動せずに起動したとき、
/// 読み取り専用の一時的な場所から実行される macOS の仕組み）の判定。
/// Glow Ai の実装をそのまま移植。共通資料 App-共有資料/AppTranslocation対策.md を参照。
enum AppTranslocation {
    private static let securityHandle =
        dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)

    /// 隔離起動しているか。
    /// `SecTranslocateIsTranslocatedURL` を dlsym で呼び、取得できなければパスで判定する。
    static func isTranslocated(_ url: URL) -> Bool {
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
        if let handle = securityHandle,
           let sym = dlsym(handle, "SecTranslocateIsTranslocatedURL") {
            let fn = unsafeBitCast(sym, to: Fn.self)
            var isTrans = false
            var err: Unmanaged<CFError>? = nil
            if fn(url as CFURL, &isTrans, &err).boolValue { return isTrans }
            err?.release()   // 失敗時に返る CFError を解放（リーク防止）
        }
        return url.path.contains("/AppTranslocation/")
    }

    /// 隔離起動中のアプリの元の場所。
    /// `SecTranslocateCreateOriginalPathForURL`（公開ヘッダに無い）を dlsym で呼ぶ。取得できなければ nil。
    static func originalURL(of url: URL) -> URL? {
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = securityHandle,
              let sym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        var err: Unmanaged<CFError>? = nil
        guard let original = fn(url as CFURL, &err)?.takeRetainedValue() else {
            err?.release()
            return nil
        }
        return original as URL
    }

    /// 元の場所がアプリケーションフォルダ（/Applications または ~/Applications）の中か。
    /// アプリケーションフォルダの中で ZIP を展開した場合や、ほかのアプリとまとめて移動した場合に当たる。
    static func isInApplicationsFolder(_ url: URL) -> Bool {
        let appDirs = FileManager.default.urls(for: .applicationDirectory,
                                               in: [.localDomainMask, .userDomainMask])
        let path = url.standardizedFileURL.path
        return appDirs.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }
}
