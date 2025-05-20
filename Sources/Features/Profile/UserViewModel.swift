import Foundation
import SwiftUI

class UserViewModel: ObservableObject {

    @Published var isLoggedIn: Bool = false
    
    init() {
        // TODO: Load user state from UserDefaults or Keychain
        loadUserState()
    }
    
    private func loadUserState() {
        // TODO: Implement user state loading
    }
    
    static func login(username: String, password: String) async throws -> [String: String] {
        let hproseInstance = HproseInstance.shared
        if let userId = try await hproseInstance.getUserId(username) {
            if var user = try await hproseInstance.getUser(userId) {
                user.password = password
                let ret = try await hproseInstance.login(user)
                return ret
            } else {
                return ["reason": "Cannot find user by \(userId)", "status": "failure"]
            }
        }
        return ["reason": "Cannot find userId by \(username)", "status": "failure"]
    }
    
    func register(username: String, email: String, password: String) async throws {
        // TODO: Implement registration logic
    }
    
    static func logout() {
        // TODO: Implement logout logic
        var appUser = HproseInstance.shared.appUser
        appUser.mid = Constants.GUEST_ID
        appUser.followingList = Gadget.getAlphaIds()
    }
} 
