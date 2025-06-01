//
//  Registration.swift
//  Tweet
//
//  Created by 超方 on 2025/5/24.
//

import SwiftUI

enum UserFormMode {
    case register
    case edit
}

struct RegistrationView: View {
    @Environment(\.dismiss) private var dismiss
    let mode: UserFormMode
    var user: User?
    var onSubmit: (String, String?, String?, String?, String) -> Void // username, password, alias, profile, hostId

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var alias: String = ""
    @State private var profile: String = ""
    @State private var hostId: String = ""
    @State private var showPasswordConfirm: Bool = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case username, password, confirmPassword, alias, profile, hostId
    }

    init(mode: UserFormMode, user: User? = nil, onSubmit: @escaping (String, String?, String?, String?, String) -> Void) {
        self.mode = mode
        self.user = user
        self.onSubmit = onSubmit
        // Prefill fields in edit mode
        if let user = user, mode == .edit {
            _username = State(initialValue: user.username ?? "")
            _alias = State(initialValue: user.name ?? "")
            _profile = State(initialValue: user.profile ?? "")
            _hostId = State(initialValue: user.hostIds?.first ?? "")
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Text(mode == .register ? "Create Account" : "Edit Profile")
                        .font(.title)
                        .fontWeight(.bold)

                    Group {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Username")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Username", text: $username)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .autocapitalization(.none)
                                .disabled(mode == .edit) // Username cannot be changed
                                .focused($focusedField, equals: .username)
                                .contentShape(Rectangle())
                                .onTapGesture { focusedField = .username }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Password")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            SecureField("Password", text: $password)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .focused($focusedField, equals: .password)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    focusedField = .password
                                    if mode == .edit { showPasswordConfirm = true }
                                }
                        }

                        if mode == .register || (mode == .edit && !password.isEmpty) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Confirm Password")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                SecureField("Confirm Password", text: $confirmPassword)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .focused($focusedField, equals: .confirmPassword)
                                    .contentShape(Rectangle())
                                    .onTapGesture { focusedField = .confirmPassword }
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Alias")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Alias", text: $alias)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .focused($focusedField, equals: .alias)
                                .contentShape(Rectangle())
                                .onTapGesture { focusedField = .alias }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Profile")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextEditor(text: $profile)
                                .frame(minHeight: 60, maxHeight: 120)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3)))
                                .focused($focusedField, equals: .profile)
                                .onTapGesture { focusedField = .profile }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Host ID (17 chars)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Host ID (17 chars)", text: $hostId)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .focused($focusedField, equals: .hostId)
                                .contentShape(Rectangle())
                                .onTapGesture { focusedField = .hostId }
                                .onChange(of: hostId) { newValue in
                                    if newValue.count > 17 {
                                        hostId = String(newValue.prefix(17))
                                    }
                                }
                        }
                    }

                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    Button(action: handleSubmit) {
                        Text(mode == .register ? "Register" : "Save")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
                .padding()
            }
            .navigationBarItems(trailing: Button("Close") { dismiss() })
        }
    }

    private func handleSubmit() {
        // Validation
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "Username is required."
            return
        }
        if hostId.trimmingCharacters(in: .whitespacesAndNewlines).count != 17 {
            errorMessage = "Host ID must be 17 characters."
            return
        }
        if mode == .register {
            if password.isEmpty {
                errorMessage = "Password is required."
                return
            }
            if password != confirmPassword {
                errorMessage = "Passwords do not match."
                return
            }
        } else if mode == .edit {
            if !password.isEmpty && password != confirmPassword {
                errorMessage = "Passwords do not match."
                return
            }
        }
        errorMessage = nil
        onSubmit(username, password.isEmpty ? nil : password, alias.isEmpty ? nil : alias, profile.isEmpty ? nil : profile, hostId)
        dismiss()
    }
}

