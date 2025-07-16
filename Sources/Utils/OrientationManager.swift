import UIKit
import SwiftUI

class OrientationManager: ObservableObject {
    static let shared = OrientationManager()
    
    @Published var isLocked = false
    
    private init() {}
    
    func lockToPortrait() {
        AppDelegate.lockOrientation(.portrait)
        isLocked = true
        print("DEBUG: [OrientationManager] Locked to portrait orientation")
    }
    
    func unlockOrientation() {
        AppDelegate.unlockOrientation()
        isLocked = false
        print("DEBUG: [OrientationManager] Unlocked orientation")
    }
}

// Extension to handle orientation in SwiftUI App lifecycle
extension UIApplication {
    func setOrientation(_ orientation: UIInterfaceOrientation) {
        if let windowScene = connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }
} 