import Foundation

/// Lookup for the app's localized strings.
///
/// Deliberately not `Bundle.module` at the call sites: that accessor traps if the
/// SwiftPM resource bundle is missing, which would turn a packaging slip — the bundle not
/// copied into `Skreen2Go.app/Contents/Resources` — into a crash on launch. Here a
/// missing bundle degrades to the key's own default instead.
enum L10n {
    /// Language forced from Settings, or nil to follow the system.
    ///
    /// Resolving a specific `.lproj` ourselves, rather than writing `AppleLanguages`,
    /// means a change takes effect immediately instead of only after a relaunch.
    static var overrideLanguage: String? {
        didSet {
            guard overrideLanguage != oldValue else { return }
            cachedOverride = nil
        }
    }

    /// `nil` when the resource bundle cannot be found, which only happens if the app was
    /// assembled without it.
    static let bundle: Bundle? = resolveBundle()

    private static var cachedOverride: Bundle??

    static func string(_ key: String, fallback: String) -> String {
        guard let bundle = activeBundle() else { return fallback }
        let value = bundle.localizedString(forKey: key, value: fallback, table: nil)
        return value.isEmpty ? fallback : value
    }

    /// The forced-language bundle if one is set and available, otherwise the base bundle,
    /// which resolves against the system's preferred languages.
    private static func activeBundle() -> Bundle? {
        guard let overrideLanguage else { return bundle }
        if let cachedOverride { return cachedOverride ?? bundle }

        // Built from the bundle URL directly: `url(forResource:withExtension:)` does not
        // return `.lproj` directories, they are localization containers rather than
        // ordinary resources.
        let resolved = bundle
            .map { $0.bundleURL.appendingPathComponent("\(overrideLanguage).lproj") }
            .flatMap { Bundle(url: $0) }
        cachedOverride = .some(resolved)
        return resolved ?? bundle
    }

    private static func resolveBundle() -> Bundle? {
        let bundleName = "Skreen2Go_Skreen2GoCore"
        let candidates = [
            // Inside a built .app.
            Bundle.main.resourceURL,
            Bundle(for: BundleToken.self).resourceURL,
            Bundle.main.bundleURL,
            // Beside the binary, which is where SwiftPM puts it when running tests or
            // the executable straight out of .build.
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()
        ]

        for candidate in candidates {
            let url = candidate?.appendingPathComponent("\(bundleName).bundle")
            if let url, let bundle = Bundle(url: url) { return bundle }
        }
        // Running straight from the SwiftPM build directory.
        return Bundle(for: BundleToken.self)
    }

    private final class BundleToken {}
}

extension String {
    /// - Parameter fallback: shown verbatim if the key is missing, so a forgotten
    ///   translation reads as English rather than as a raw key.
    func localized(_ fallback: String) -> String {
        L10n.string(self, fallback: fallback)
    }

    func localized(_ fallback: String, _ arguments: CVarArg...) -> String {
        String(format: L10n.string(self, fallback: fallback), arguments: arguments)
    }
}
