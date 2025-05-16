import Foundation

enum BuildConfiguration {
    case debug
    case release
    
    static var current: BuildConfiguration {
        #if DEBUG
        return .debug
        #else
        return .release
        #endif
    }
}

struct AppConfig {
    static let baseUrl: String = {
        switch BuildConfiguration.current {
        case .debug:
            return "twbe.fireshare.uk"
        case .release:
            return "tweet.fireshare.uk"
        }
    }()
    
    static let appId: String = {
        switch BuildConfiguration.current {
        case .debug:
            return "d4lRyhABgqOnqY4bURSm_T-4FZ4"
        case .release:
            return "heWgeGkeBX2gaENbIBS_Iy1mdTS"
        }
    }()
    
    static let appIdHash: String = {
        switch BuildConfiguration.current {
        case .debug:
            return "FGPaNfKA-RwvJ-_hGN0JDWMbm9R"
        case .release:
            return "FGPaNfKA-RwvJ-_hGN0JDWMbm9R"
        }
    }()
    
    static let alphaId: String = {
        switch BuildConfiguration.current {
        case .debug:
            return "iFG4GC9r0fF22jYBCkuPThybzwO"
        case .release:
            return "mwmQCHCEHClCIJy-bItx5ALAhq9"
        }
    }()
    
    static let entryUrls: String = {
        switch BuildConfiguration.current {
        case .debug:
            return "1x7Dh9mJfN5zSyPM5TRX3Sro_wQna"
        case .release:
            return "dSXMdZNrpMw0xJQEbxPZn5nnLBK"
        }
    }()
} 