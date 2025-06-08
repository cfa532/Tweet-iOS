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
    
    enum Field: Hashable {
        case username
        case password
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Welcome to dTweet")
                    .font(.title)
                    .fontWeight(.bold)
                
                Group {
                    TextField("Username", text: $username)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disabled(isLoading)
                        .focused($focusedField, equals: .username)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focusedField = .username
                        }
                    
                    SecureField("Password", text: $password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .disabled(isLoading)
                        .focused($focusedField, equals: .password)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focusedField = .password
                        }
                }
                
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                Button(action: {
                    Task {
                        await login()
                    }
                }) {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("Login")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(isLoading || username.isEmpty || password.isEmpty)
                
                Button("Don't have an account? Register") {
                    showRegistration = true
                }
                .foregroundColor(.blue)
                .disabled(isLoading)
            }
            .padding()
            .navigationBarItems(trailing: Button("Close") {
                dismiss()
            })
            .sheet(isPresented: $showRegistration) {
                RegistrationView { (username: String, password: String?, alias: String?, profile: String?, hostId: String?) in
                    Task {
                        do {
                            let success = try await hproseInstance.registerUser(
                                username: username,
                                password: password ?? "",
                                alias: alias ?? "",
                                profile: profile ?? "",
                                hostId: (hostId?.isEmpty ?? true) ? nil : hostId
                            )
                            if success {
                                showSuccess = true
                                showRegistration = false
                            } else {
                                errorMessage = "Registration failed."
                            }
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .alert("Login Successful. Wait for a few minutes before login.", isPresented: $showSuccess) {
                Button("OK") {
//                    dismiss()
                }
            } message: {
                Text("Welcome back!")
            }
        }
    }
    
    private func login() async {
        isLoading = true
        errorMessage = nil
        
        do {
            if username.isEmpty || password.isEmpty {
                errorMessage = "Username & password are required."
                return
            }
            if let userId = try await hproseInstance.getUserId(username) {
                // retrieve user object from the net.
                if let user = try await hproseInstance.getUser(userId) {
                    user.password = password
                    let result = try await hproseInstance.login(user)
                    if result["status"] as? String == "success" {
                        // Post notification for successful login
                        NotificationCenter.default.post(name: .userDidLogin, object: nil)
                        dismiss()
                    } else {
                        errorMessage = result["reason"] as? String
                    }
                } else {
                    errorMessage = "Cannot find user by \(userId)"
                }
            } else {
                errorMessage = "Cannot find userId by \(username)"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
}

