//
//  Login.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/5/24.
//

import SwiftUI

@available(iOS 16.0, *)
struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var username = ""
    @State private var password = ""
    @State private var showRegistration = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?
    
    enum Field {
        case username
        case password
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text(LocalizedStringKey("Welcome to dTweet"))
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.themeText)
                
                Group {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringKey("Username"))
                            .font(.headline)
                            .foregroundColor(.themeText)
                        
                        TextField(LocalizedStringKey("Enter your username"), text: $username)
                            .textFieldStyle(PlainTextFieldStyle())
                            .autocapitalization(.none)
                            .disabled(isLoading)
                            .focused($focusedField, equals: .username)
                            .submitLabel(.next)
                            .onSubmit {
                                focusedField = .password
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(.systemGray6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(focusedField == .username ? Color.themeAccent : Color.clear, lineWidth: 2)
                                    )
                            )
                            .onTapGesture {
                                focusedField = .username
                            }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringKey("Password"))
                            .font(.headline)
                            .foregroundColor(.themeText)
                        
                        SecureField(LocalizedStringKey("Enter your password"), text: $password)
                            .textFieldStyle(PlainTextFieldStyle())
                            .disabled(isLoading)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.done)
                            .onSubmit {
                                focusedField = nil
                                Task {
                                    await login()
                                }
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(.systemGray6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(focusedField == .password ? Color.themeAccent : Color.clear, lineWidth: 2)
                                    )
                            )
                            .onTapGesture {
                                focusedField = .password
                            }
                    }
                }
                
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                
                DebounceButton(
                    cooldownDuration: 0.5,
                    enableAnimation: true,
                    enableVibration: false
                ) {
                    Task {
                        await login()
                    }
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text(LocalizedStringKey("Login"))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.themeAccent)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(isLoading || username.isEmpty || password.isEmpty)
                
                Button(LocalizedStringKey("Don't have an account? Register")) {
                    showRegistration = true
                }
                .foregroundColor(.themeAccent)
                .disabled(isLoading)
            }
            .padding()
            .navigationBarItems(trailing: Button(LocalizedStringKey("Close")) {
                dismiss()
            })
            .sheet(isPresented: $showRegistration) {
                RegistrationView(
                    onSubmit: { (username: String, password: String?, alias: String?, profile: String?, hostId: String?) in
                        let success = try await hproseInstance.registerUser(
                            username: username,
                            password: password ?? "",
                            alias: alias ?? "",
                            profile: profile ?? "",
                            hostId: (hostId?.isEmpty ?? true) ? nil : hostId,
                            cloudDrivePort: 0
                        )
                        if !success {
                            // Let RegistrationView handle the error with toast
                            throw NSError(domain: "Registration", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Registration failed.", comment: "Registration error message")])
                        }
                        // Success is handled by RegistrationView with toast message
                    }
                )
            }
        }
    }
    
    private func login() async {
        isLoading = true
        errorMessage = nil
        
        do {
            if username.isEmpty || password.isEmpty {
                errorMessage = NSLocalizedString("Username & password are required.", comment: "Login error message")
                return
            }
            // Use entry URL when calling getUserId during login
            if let userId = try await hproseInstance.getUserId(username, baseUrl: HproseInstance.baseUrl) {
                // Force fetch from server with empty baseUrl to ensure fresh data
                // This prevents the issue where cached user with nil username is returned
                if let user = try await hproseInstance.fetchUser(userId, baseUrl: "") {
                    if (user.username == nil) {
                        print("DEBUG: [Login] Cannot find user - username: \(username), userid: \(userId)")
                        errorMessage = NSLocalizedString("Login failed. Please try again.", comment: "Generic login failure message")
                    } else {
                        user.password = password
                        let result = try await hproseInstance.login(user)
                        if result["status"] as? String == "success" {
                            // Post notification for successful login
                            NotificationCenter.default.post(name: .userDidLogin, object: nil)
                            dismiss()
                        } else {
                            print("DEBUG: [Login] Login failed - username: \(username), userid: \(userId), reason: \(result["reason"] as? String ?? "unknown")")
                            errorMessage = result["reason"] as? String
                        }
                    }
                } else {
                    print("DEBUG: [Login] Cannot find user - username: \(username), userid: \(userId)")
                    errorMessage = NSLocalizedString("Login failed. Please try again.", comment: "Generic login failure message")
                }
            } else {
                print("DEBUG: [Login] Cannot find userId - username: \(username)")
                errorMessage = NSLocalizedString("Login failed. Please try again.", comment: "Generic login failure message")
            }
        } catch {
            print("DEBUG: [Login] Login error - username: \(username), error: \(error.localizedDescription)")
            let lowercasedDescription = error.localizedDescription.lowercased()
            if lowercasedDescription.contains("base url") ||
                lowercasedDescription.contains("provider ip") ||
                lowercasedDescription.contains("userid not found") ||
                lowercasedDescription.contains("login failed") {
                errorMessage = NSLocalizedString("Login failed. Please try again.", comment: "Generic login failure message")
            } else {
                errorMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
            }
        }
        
        isLoading = false
    }
}
