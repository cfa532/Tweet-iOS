import Foundation
import SwiftUI

// MARK: - String Extension for Localization
extension String {
    /// Returns a localized version of the string
    var localized: String {
        return NSLocalizedString(self, comment: "")
    }
    
    /// Returns a localized version of the string with a comment
    func localized(comment: String) -> String {
        return NSLocalizedString(self, comment: comment)
    }
    
    /// Returns a localized version of the string with format arguments
    func localizedFormat(_ arguments: CVarArg...) -> String {
        return String(format: self.localized, arguments: arguments)
    }
}

// MARK: - LocalizedStringKey Extension
// Note: LocalizedStringKey already has proper initializers, so we don't need to extend it

// MARK: - Localization Manager
class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    
    @Published var currentLanguage: String {
        didSet {
            Task { @MainActor in
                UserDefaults.standard.set(currentLanguage, forKey: "AppLanguage")
                UserDefaults.standard.set([currentLanguage], forKey: "AppleLanguages")
                UserDefaults.standard.synchronize()
            }
        }
    }
    
    private init() {
        self.currentLanguage = UserDefaults.standard.string(forKey: "AppLanguage") ?? 
                              Locale.current.language.languageCode?.identifier ?? "en"
    }
    
    /// Available languages in the app
    var availableLanguages: [String] {
        return ["en", "zh-Hans", "ja"]
    }
    
    /// Language display names
    var languageDisplayNames: [String: String] {
        return [
            "en": "English",
            "zh-Hans": "简体中文",
            "ja": "日本語"
        ]
    }
    
    /// Get display name for a language code
    func displayName(for languageCode: String) -> String {
        return languageDisplayNames[languageCode] ?? languageCode
    }
    
    /// Switch to a different language
    func switchLanguage(to languageCode: String) {
        guard availableLanguages.contains(languageCode) else { return }
        currentLanguage = languageCode
    }
} 