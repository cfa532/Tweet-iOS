import SwiftUI

@MainActor
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    
    @Published var isDarkMode: Bool = false {
        didSet {
            if oldValue != isDarkMode {
                HproseInstance.shared.preferenceHelper?.setDarkMode(isDarkMode)
                updateAppearance()
            }
        }
    }
    
    private init() {
        // Initialize from saved preference
        isDarkMode = HproseInstance.shared.preferenceHelper?.getDarkMode() ?? false
        updateAppearance()
    }
    
    func refreshFromPreferences() {
        let savedDarkMode = HproseInstance.shared.preferenceHelper?.getDarkMode() ?? false
        if self.isDarkMode != savedDarkMode {
            self.isDarkMode = savedDarkMode
        }
    }
    
    private func updateAppearance() {
        // Update the app's appearance based on dark mode setting
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.windows.forEach { window in
                window.overrideUserInterfaceStyle = isDarkMode ? .dark : .light
            }
        }
    }
} 