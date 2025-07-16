import UIKit
import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
    
    static func lockOrientation(_ orientation: UIInterfaceOrientationMask) {
        orientationLock = orientation
        print("DEBUG: [AppDelegate] Locked orientation to: \(orientation)")
    }
    
    static func unlockOrientation() {
        orientationLock = .all
        print("DEBUG: [AppDelegate] Unlocked orientation")
    }
} 