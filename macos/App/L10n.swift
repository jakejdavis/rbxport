import Foundation
import Observation
import os

/// One entry of the Language picker: React's locale code, its native label and Apple's language code.
struct LanguageChoice: Identifiable, Equatable, Sendable {
    /// React's code (`view.locale`), for example `zh-CN`.
    let code: String
    /// The language's own name (LANGUAGE_CHOICES in src/i18n/index.tsx).
    let label: String
    /// The code the String Catalog uses for it (`zh-Hans`).
    let appleCode: String
    var id: String { code }
    var locale: Locale { Locale(identifier: appleCode) }
}

/// Bumped on the main actor when the language changes. `L10n.t` reads it, so any SwiftUI body or
/// `withObservationTracking` block that builds a string through the helper re-runs on a change.
@Observable final class L10nRevision: @unchecked Sendable {
    var value = 0
}

/// Looks strings up by their English text in Localizable.xcstrings, which
/// `macos/scripts/build-xcstrings.mjs` builds from the React app's catalogs. SwiftUI literals
/// (`Text("Rename")`) localise by themselves, from the `\.locale` environment; everything that
/// is not a literal at the point of display (menu titles, column headers, model messages) goes
/// through here instead. A string with no translation comes back as written.
///
/// A template keeps React's `{name}` placeholders in the source text. The catalog key is the same text
/// with them turned into `%@` (or `%1$@`, `%2$@` when there are several), exactly as the script
/// writes it, so a translation can move the values around.
enum L10n {
    /// React's LANGUAGE_CHOICES, in its order.
    static let choices: [LanguageChoice] = [
        ("en", "English", "en"), ("fr", "Français", "fr"), ("de", "Deutsch", "de"), ("es", "Español", "es"),
        ("it", "Italiano", "it"), ("nl", "Nederlands", "nl"), ("ru", "Русский", "ru"), ("pt", "Português", "pt"),
        ("sv", "Svenska", "sv"), ("da", "Dansk", "da"), ("tr", "Türkçe", "tr"), ("el", "Ελληνικά", "el"),
        ("hu", "Magyar", "hu"), ("cs", "čeština", "cs"), ("zh-CN", "简体中文", "zh-Hans"),
        ("zh-TW", "繁體中文", "zh-Hant"), ("ko", "한국어", "ko"), ("ja", "日本語", "ja"),
    ].map { LanguageChoice(code: $0.0, label: $0.1, appleCode: $0.2) }

    /// Apple's language code for a React one; English for anything unknown.
    static func appleCode(for code: String) -> String { choices.first { $0.code == code }?.appleCode ?? "en" }

    /// The language the helper uses when a call names none. Set from the preference by the app.
    static var current: String { currentCode.withLock { $0 } }
    @MainActor static func setCurrent(_ code: String) {
        let known = choices.contains { $0.code == code } ? code : "en"
        guard known != current else { return }
        currentCode.withLock { $0 = known }
        revision.value += 1
    }
    private static let currentCode = OSAllocatedUnfairLock(initialState: "en")
    static let revision = L10nRevision()

    /// Keeps the helper on `prefs.locale`, now and after each change. With `writesAppleLanguages` a change also
    /// sets the app's `AppleLanguages`, so the system-drawn parts (the app menu, standard alerts and panels)
    /// follow after the next launch. Only a change made in the running app writes it: never pass true under
    /// test or for a dev launch.
    @MainActor static func follow(_ prefs: PreferencesStore, writesAppleLanguages: Bool) {
        setCurrent(prefs.locale)
        prefs.onChange { [weak prefs] key in
            guard key == PrefKeys.locale, let prefs else { return }
            setCurrent(prefs.locale)
            if writesAppleLanguages { UserDefaults.standard.set([appleCode(for: prefs.locale)], forKey: "AppleLanguages") }
        }
    }

    // MARK: Lookup

    /// The text in a language (`locale`, a React code; the current one when nil).
    static func t(_ source: String, locale: String? = nil) -> String {
        let code = resolve(locale)
        guard code != "en", let bundle = bundle(for: code) else { return source }
        let missing = "\u{1}missing"
        let found = bundle.localizedString(forKey: source, value: missing, table: nil)
        if found != missing { return found }
        // A menu title with an ellipsis ("Sync Manager\u{2026}") borrows its words from the key without one.
        if source.hasSuffix("\u{2026}"), source.count > 1 {
            let bare = String(source.dropLast())
            let base = bundle.localizedString(forKey: bare, value: missing, table: nil)
            if base != missing { return base + "\u{2026}" }
        }
        return source
    }

    /// A template with `{name}` placeholders, filled from `values`.
    static func t(_ source: String, _ values: [String: Any], locale: String? = nil) -> String {
        let names = placeholderNames(source)
        guard !names.isEmpty else { return t(source, locale: locale) }
        let key = catalogKey(source, names: names)
        let code = resolve(locale)
        var format = key
        if code != "en", let bundle = bundle(for: code) {
            let missing = "\u{1}missing"
            let found = bundle.localizedString(forKey: key, value: missing, table: nil)
            if found != missing { format = found }
        }
        let args: [CVarArg] = names.map { "\(values[$0] ?? "")" as NSString }
        return String(format: format, arguments: args)
    }

    /// Placeholder names in order of first appearance.
    static func placeholderNames(_ text: String) -> [String] {
        var names: [String] = []
        for match in placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range(at: 1), in: text), !names.contains(String(text[range])) {
                names.append(String(text[range]))
            }
        }
        return names
    }

    /// The catalog key of a template, as `convertPlaceholders` in build-xcstrings.mjs writes it.
    static func catalogKey(_ source: String, names: [String]? = nil) -> String {
        let names = names ?? placeholderNames(source)
        guard !names.isEmpty else { return source }
        var out = ""
        var last = source.startIndex
        for match in placeholder.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let whole = Range(match.range, in: source), let name = Range(match.range(at: 1), in: source) else { continue }
            out += source[last..<whole.lowerBound].replacingOccurrences(of: "%", with: "%%")
            out += names.count == 1 ? "%@" : "%\((names.firstIndex(of: String(source[name])) ?? 0) + 1)$@"
            last = whole.upperBound
        }
        return out + source[last...].replacingOccurrences(of: "%", with: "%%")
    }

    // swiftlint:disable:next force_try
    private static let placeholder = try! NSRegularExpression(pattern: #"\{([A-Za-z_][A-Za-z0-9_]*)\}"#)

    /// True when the catalog holds a translation for the key in the language.
    static func hasTranslation(_ source: String, locale: String) -> Bool {
        let code = resolve(locale)
        guard let bundle = bundle(for: code) else { return false }
        let key = catalogKey(source)
        let missing = "\u{1}missing"
        return bundle.localizedString(forKey: key, value: missing, table: nil) != missing
    }

    private static func resolve(_ locale: String?) -> String {
        if let locale { return locale }
        _ = revision.value  // registers the dependency for observation tracking
        return current
    }

    // MARK: Bundles

    private final class Anchor {}
    private static let bundles = OSAllocatedUnfairLock(initialState: [String: Bundle?]())

    /// The `.lproj` of a language inside the app bundle.
    private static func bundle(for code: String) -> Bundle? {
        let apple = appleCode(for: code)
        return bundles.withLock { cache in
            if let hit = cache[apple] { return hit }
            let main = Bundle(for: Anchor.self)
            let found = main.path(forResource: apple, ofType: "lproj").flatMap(Bundle.init(path:))
            cache[apple] = .some(found)
            return found
        }
    }
}
