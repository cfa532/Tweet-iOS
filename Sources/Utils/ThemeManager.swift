import SwiftUI

enum XTheme {
    static var accent: UIColor {
        UIColor(red: 0x1D / 255.0, green: 0x9B / 255.0, blue: 0xF0 / 255.0, alpha: 1.0)
    }

    static var background: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? .black : .white
        }
    }

    static var secondaryBackground: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x16 / 255.0, green: 0x18 / 255.0, blue: 0x1C / 255.0, alpha: 1.0)
                : UIColor(red: 0xF7 / 255.0, green: 0xF9 / 255.0, blue: 0xF9 / 255.0, alpha: 1.0)
        }
    }

    static var text: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0xE7 / 255.0, green: 0xE9 / 255.0, blue: 0xEA / 255.0, alpha: 1.0)
                : UIColor(red: 0x0F / 255.0, green: 0x14 / 255.0, blue: 0x19 / 255.0, alpha: 1.0)
        }
    }

    static var secondaryText: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x71 / 255.0, green: 0x76 / 255.0, blue: 0x7B / 255.0, alpha: 1.0)
                : UIColor(red: 0x53 / 255.0, green: 0x64 / 255.0, blue: 0x71 / 255.0, alpha: 1.0)
        }
    }

    static var border: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x2F / 255.0, green: 0x33 / 255.0, blue: 0x36 / 255.0, alpha: 1.0)
                : UIColor(red: 0xCF / 255.0, green: 0xD9 / 255.0, blue: 0xDE / 255.0, alpha: 1.0)
        }
    }

    static var cardBackground: UIColor {
        background
    }

    static var quotedTweetSurface: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x1B / 255.0, green: 0x1C / 255.0, blue: 0x1C / 255.0, alpha: 1.0)
                : UIColor(red: 0xE3 / 255.0, green: 0xE3 / 255.0, blue: 0xE4 / 255.0, alpha: 1.0)
        }
    }

    static var accentColor: Color { Color(uiColor: accent) }
    static var backgroundColor: Color { Color(uiColor: background) }
    static var secondaryBackgroundColor: Color { Color(uiColor: secondaryBackground) }
    static var textColor: Color { Color(uiColor: text) }
    static var secondaryTextColor: Color { Color(uiColor: secondaryText) }
    static var borderColor: Color { Color(uiColor: border) }
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
