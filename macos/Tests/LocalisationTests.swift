import Foundation
import Testing

@testable import rbxport

/// The language helper and the catalog behind it. Every call names its language, so none of these
/// touches the app-wide current one that other tests read.
@MainActor
@Suite(.scratchDefaults)
struct LocalisationTests {
    @Test func knownKeysComeBackInGermanAndJapanese() {
        #expect(L10n.t("Rename", locale: "de") == "Umbenennen")
        #expect(L10n.t("Delete", locale: "de") == "Löschen")
        #expect(L10n.t("Rename", locale: "ja") == "名前を変更")
        #expect(L10n.t("Playlists", locale: "ja") == "プレイリスト")
        #expect(L10n.t("Rename", locale: "zh-CN") == "重命名")
        #expect(L10n.t("Rename", locale: "zh-TW") != "Rename")
    }

    @Test func englishAndUnknownTextComeBackAsWritten() {
        #expect(L10n.t("Rename", locale: "en") == "Rename")
        #expect(L10n.t("No such words in any catalog", locale: "de") == "No such words in any catalog")
        #expect(L10n.t("Rename", locale: "xx") == "Rename")
    }

    @Test func aMenuTitleWithAnEllipsisBorrowsTheWordsOfTheBareKey() {
        #expect(L10n.t("Sync Manager\u{2026}", locale: "de") == L10n.t("Sync Manager", locale: "de") + "\u{2026}")
        #expect(L10n.t("Sync Manager\u{2026}", locale: "de") != "Sync Manager\u{2026}")
    }

    @Test func templatesFillTheirValuesInEachLanguage() {
        #expect(L10n.t("{count} minutes ago", ["count": 5], locale: "en") == "5 minutes ago")
        #expect(L10n.t("{count} minutes ago", ["count": 5], locale: "de") == "vor 5 Minuten")
        #expect(L10n.t("{count} minutes ago", ["count": 7], locale: "ja") == "7 分前")
        // A template with no translation still fills.
        #expect(L10n.t("{x} and {y}", ["x": "a", "y": 2], locale: "de") == "a and 2")
    }

    @Test func templatesBecomeCatalogKeysTheWayTheScriptWritesThem() {
        #expect(L10n.catalogKey("{count} minutes ago") == "%@ minutes ago")
        #expect(L10n.catalogKey("Creating backup: {percent}% \u{2014} {copied} of {total}") == "Creating backup: %1$@%% \u{2014} %2$@ of %3$@")
        #expect(L10n.catalogKey("{a} then {b}, then {a}") == "%1$@ then %2$@, then %1$@")
        #expect(L10n.catalogKey("Plain 100%") == "Plain 100%")
        #expect(L10n.placeholderNames("{b} {a} {b}") == ["b", "a"])
        // Positional values land where the translation puts them.
        #expect(L10n.t("{a} of {b}", ["a": 1, "b": 2], locale: "en") == "1 of 2")
    }

    @Test func everyLanguageChoiceIsACatalogLanguage() throws {
        #expect(L10n.choices.count == 18)
        #expect(L10n.choices.first?.code == "en" && L10n.choices.first?.label == "English")
        #expect(L10n.choices.first { $0.code == "ja" }?.label == "日本語")
        #expect(L10n.choices.first { $0.code == "zh-CN" }?.appleCode == "zh-Hans")
        #expect(L10n.choices.first { $0.code == "zh-TW" }?.appleCode == "zh-Hant")
        let declared = try #require(Bundle(for: PreferencesStore.self).object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String])
        for choice in L10n.choices {
            #expect(declared.contains(choice.appleCode), "\(choice.code) is declared in CFBundleLocalizations")
            if choice.code != "en" {
                #expect(L10n.hasTranslation("Rename", locale: choice.code), "\(choice.code) has a compiled catalog")
                #expect(L10n.t("Rename", locale: choice.code) != "Rename" || choice.code == "hu", "\(choice.code) translates Rename")
            }
        }
    }

    @Test func deckHardwareLabelsAreNeverTranslated() {
        let labels = [
            "CUE", "PLAY", "IN", "OUT", "RELOOP", "EXIT", "LOOP", "MEMORY", "SET", "DEL", "GRID", "MARK", "TAP", "Q",
            "MASTER TEMPO", "RESET", "BEAT SYNC", "MASTER", "KEY", "TRIM", "LOW", "MID", "HIGH", "KILL", "DUAL CONTROL",
            "BARS", "4Beats", "8Bars",
        ]
        for code in ["de", "ja", "fr", "zh-CN", "ko"] {
            for label in labels {
                #expect(L10n.t(label, locale: code) == label, "\(label) in \(code)")
                #expect(!L10n.hasTranslation(label, locale: code), "\(label) in \(code) is not in the catalog")
            }
        }
        // Their tooltips are other keys and still translate.
        #expect(L10n.t("Rename", locale: "de") == "Umbenennen")
    }

    @Test func aTranslationHasNoStrayNewline() {
        #expect(L10n.t("Key", locale: "de") == "Tonart")
    }

    @Test func theLanguagePreferenceIsViewLocale() {
        let defaults = scratchDefaults(prefix: "rbxport-l10n")
        let store = PreferencesStore(defaults: defaults)
        #expect(store.locale == "en")
        #expect(defaults.object(forKey: "view.locale") == nil)
        store.locale = "de"
        #expect(defaults.string(forKey: "view.locale") == "de")
        #expect(PreferencesStore(defaults: defaults).locale == "de")
        store.locale = "zh-TW"
        #expect(defaults.string(forKey: "view.locale") == "zh-TW")
        // A stale or hand-edited value reads as English.
        defaults.set("klingon", forKey: "view.locale")
        #expect(PreferencesStore(defaults: defaults).locale == "en")
        store.locale = "ja"
        store.reset(.view)
        #expect(store.locale == "en" && defaults.string(forKey: "view.locale") == "en")
    }

    @Test func followingThePreferenceDoesNotNeedAppleLanguages() {
        // The helper's own state is global, so only the pure parts are exercised here.
        #expect(L10n.appleCode(for: "zh-CN") == "zh-Hans")
        #expect(L10n.appleCode(for: "nonsense") == "en")
    }
}

