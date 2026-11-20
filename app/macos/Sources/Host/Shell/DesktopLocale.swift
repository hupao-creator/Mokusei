import Foundation

public enum DesktopLocale: String, Sendable {
    case chinese = "zh-CN"
    case english = "en-US"

    public static var system: Self {
        // Read the macOS language order directly so an app-specific language
        // or the region used for date formatting cannot change the result.
        let languages = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return Self(primaryLanguage: languages?.first)
    }

    init(primaryLanguage: String?) {
        self = primaryLanguage.map { Locale.Language(identifier: $0).languageCode?.identifier == "zh" } == true
            ? .chinese : .english
    }

    public func text(_ chinese: String, _ english: String) -> String {
        self == .chinese ? chinese : english
    }
}
