import SwiftUI

enum XTheme {
    static let accent = UIColor(named: "ThemeAccent") ?? UIColor(red: 0.114, green: 0.608, blue: 0.941, alpha: 1.0)
    static let background = UIColor(named: "ThemeBackground") ?? .systemBackground
    static let secondaryBackground = UIColor(named: "ThemeSecondaryBackground") ?? .secondarySystemBackground
    static let text = UIColor(named: "ThemeText") ?? .label
    static let secondaryText = UIColor(named: "ThemeSecondaryText") ?? .secondaryLabel
    static let border = UIColor(named: "ThemeBorder") ?? .separator
    static let cardBackground = UIColor(named: "ThemeCardBackground") ?? .systemBackground
    static let quotedTweetSurface = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x1B / 255.0, green: 0x1C / 255.0, blue: 0x1C / 255.0, alpha: 1.0)
            : UIColor(red: 0xE3 / 255.0, green: 0xE3 / 255.0, blue: 0xE4 / 255.0, alpha: 1.0)
    }

    static let accentColor = Color("ThemeAccent")
    static let backgroundColor = Color("ThemeBackground")
    static let secondaryBackgroundColor = Color("ThemeSecondaryBackground")
    static let textColor = Color("ThemeText")
    static let secondaryTextColor = Color("ThemeSecondaryText")
    static let borderColor = Color("ThemeBorder")
}

@MainActor
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var isDarkMode: Bool = false {
        didSet {
            Task { @MainActor in
                if oldValue != isDarkMode {
                    HproseInstance.shared.preferenceHelper?.setDarkMode(isDarkMode)
                    updateAppearance()
                }
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
        configureGlobalAppearance()

        // Update the app's appearance based on dark mode setting
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.windows.forEach { window in
                window.overrideUserInterfaceStyle = isDarkMode ? .dark : .light
                window.tintColor = XTheme.accent
                window.backgroundColor = XTheme.background
            }
        }
    }

    private func configureGlobalAppearance() {
        UIView.appearance().tintColor = XTheme.accent
        UITableView.appearance().backgroundColor = XTheme.background
        UITableViewCell.appearance().backgroundColor = XTheme.background
        UIRefreshControl.appearance().tintColor = XTheme.accent
        UISwitch.appearance().onTintColor = XTheme.accent

        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithOpaqueBackground()
        navigationAppearance.backgroundColor = XTheme.background
        navigationAppearance.shadowColor = XTheme.border
        navigationAppearance.titleTextAttributes = [.foregroundColor: XTheme.text]
        navigationAppearance.largeTitleTextAttributes = [.foregroundColor: XTheme.text]
        UINavigationBar.appearance().standardAppearance = navigationAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navigationAppearance
        UINavigationBar.appearance().compactAppearance = navigationAppearance
        UINavigationBar.appearance().tintColor = XTheme.text

        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = XTheme.background
        tabBarAppearance.shadowColor = XTheme.border
        UITabBar.appearance().standardAppearance = tabBarAppearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
        }
        UITabBar.appearance().tintColor = XTheme.accent
        UITabBar.appearance().unselectedItemTintColor = XTheme.secondaryText
    }
}
