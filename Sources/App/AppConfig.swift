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
            return "http://twbe.fireshare.us"
        case .release:
            return "http://tweet.fireshare.us"
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
            return "5yOO4xP1QjAXhHpJtKMyIETVMxU"
        case .release:
            return "h5U5jxPr2p2tg2kMr8UeyRMNIJ_"
        }
    }()
    
    static let alphaId: String = {
        switch BuildConfiguration.current {
        case .debug:
            return "6IQc_t22JUub1TEgDP9Fo_Boosm"
        case .release:
            return "mKOihoVuFnQ2xt33R51KTQXSBkX"
        }
    }()
    
    static let entryMimeiId: String = {
        switch BuildConfiguration.current {
        case .debug:
            return "VQ3xCeguhlAF1jY7zfn-HM_Vrad"
        case .release:
            return "dSXMdZNrpMw0xJQEbxPZn5nnLBK"
        }
    }()
} 
