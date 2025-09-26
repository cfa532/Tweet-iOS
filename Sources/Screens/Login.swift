//
//  Login.swift
//  Tweet
//
//  Created by 超方 on 2025/5/24.
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
    @State private var showSuccess = false
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
                    onSubmit: { (username: String, password: String?, alias: String?, profile: String?, hostId: String?, cloudDrivePort: Int?) in
                        let success = try await hproseInstance.registerUser(
                            username: username,
                            password: password ?? "",
                            alias: alias ?? "",
                            profile: profile ?? "",
                            hostId: (hostId?.isEmpty ?? true) ? nil : hostId,
                            cloudDrivePort: cloudDrivePort
                        )
                        if success {
                            showSuccess = true
                            showRegistration = false
                        } else {
                            // Let RegistrationView handle the error with toast
                            throw NSError(domain: "Registration", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Registration failed.", comment: "Registration error message")])
                        }
                    }
                )
            }
            .alert(LocalizedStringKey("Login Successful. Wait for a few minutes before login."), isPresented: $showSuccess) {
                Button(LocalizedStringKey("OK")) {
//                    dismiss()
                }
            } message: {
                Text(LocalizedStringKey("Welcome back!"))
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
            if let userId = try await hproseInstance.getUserId(username) {
                // retrieve user object from the net.
                if let user = try await hproseInstance.fetchUser(userId) {
                    if (user.username == nil) {
                        print("DEBUG: [Login] Cannot find user - username: \(username), userid: \(userId)")
                        errorMessage = String(format: NSLocalizedString("Cannot find user by %@", comment: "User not found error"), username)
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
                    errorMessage = String(format: NSLocalizedString("Cannot find user by %@", comment: "User not found error"), username)
                }
            } else {
                print("DEBUG: [Login] Cannot find userId - username: \(username)")
                errorMessage = String(format: NSLocalizedString("Cannot find userId by %@", comment: "UserId not found error"), username)
            }
        } catch {
            print("DEBUG: [Login] Login error - username: \(username), error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
}

