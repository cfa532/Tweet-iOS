//
//  Registration.swift
//  Tweet
//
//  Created by 超方 on 2025/5/24.
//

import SwiftUI
import PhotosUI

@available(iOS 16.0, *)
struct RegistrationView: View {
    @Environment(\.dismiss) private var dismiss
    var onSubmit: (String, String?, String?, String?, String?) -> Void // username, password, alias, profile, hostId, avatarId

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var alias: String = ""
    @State private var profile: String = ""
    @State private var hostId: String = ""
    @State private var showPasswordConfirm: Bool = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?
    @State private var avatarId: String? = nil
    @State private var showImagePicker = false
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var isUploadingAvatar = false
    @State private var avatarUploadError: String? = nil
    @EnvironmentObject private var hproseInstance: HproseInstance

    enum Field: Hashable {
        case username, password, confirmPassword, alias, profile, hostId
    }

    init(onSubmit: @escaping (String, String?, String?, String?, String?) -> Void) {
        self.onSubmit = onSubmit
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    if !hproseInstance.appUser.isGuest {
                        VStack {
                            ZStack(alignment: .bottomTrailing) {
                                Avatar(user: hproseInstance.appUser, size: 80)
                                    .onTapGesture { showImagePicker = true }
                                    .overlay(
                                        Group {
                                            if isUploadingAvatar {
                                                ProgressView()
                                                    .frame(width: 80, height: 80)
                                                    .background(Color.black.opacity(0.3))
                                                    .clipShape(Circle())
                                            }
                                        }
                                    )
                                Image(systemName: "camera.fill")
                                    .foregroundColor(.white)
                                    .background(Circle().fill(Color.blue).frame(width: 28, height: 28))
                                    .offset(x: -8, y: -8)
                            }
                            if let avatarUploadError = avatarUploadError {
                                Text(avatarUploadError)
                                    .foregroundColor(.red)
                                    .font(.caption)
                            }
                        }
                        .padding(.bottom, 8)
                        .photosPicker(isPresented: $showImagePicker, selection: $selectedPhoto, matching: .images)
                        .onChange(of: selectedPhoto) { newItem in
                            if let item = newItem {
                                Task {
                                    isUploadingAvatar = true
                                    avatarUploadError = nil
                                    do {
                                        if let data = try await item.loadTransferable(type: Data.self) {
                                            let typeIdentifier = item.supportedContentTypes.first?.identifier ?? "public.image"
                                            let fileName = "avatar_\(Int(Date().timeIntervalSince1970)).jpg"
                                            if let uploaded = try await hproseInstance.uploadToIPFS(data: data, typeIdentifier: typeIdentifier, fileName: fileName, referenceId: hproseInstance.appUser.mid), !uploaded.mid.isEmpty {
                                                try await hproseInstance.setUserAvatar(user: hproseInstance.appUser, avatar: uploaded.mid)
                                                await MainActor.run {
                                                    hproseInstance.appUser.avatar = uploaded.mid
                                                }
                                            } else {
                                                avatarUploadError = "Failed to upload avatar."
                                            }
                                        } else {
                                            avatarUploadError = "Failed to load image data."
                                        }
                                    } catch {
                                        avatarUploadError = error.localizedDescription
                                    }
                                    isUploadingAvatar = false
                                }
                            }
                        }
                    }

                    Group {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Username *")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            TextField("Username", text: $username)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .autocapitalization(.none)
                                .disabled(!hproseInstance.appUser.isGuest) // Username cannot be changed
                                .focused($focusedField, equals: .username)
                                .contentShape(Rectangle())
                                .onTapGesture { focusedField = .username }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Password *")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            SecureField("Password", text: $password)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .focused($focusedField, equals: .password)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    focusedField = .password
                                    if !hproseInstance.appUser.isGuest { showPasswordConfirm = true }
                                }
                        }

                        if hproseInstance.appUser.isGuest || !password.isEmpty {
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
                            Text("Host ID (optional)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("", text: $hostId)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .focused($focusedField, equals: .hostId)
                                .contentShape(Rectangle())
                                .onTapGesture { focusedField = .hostId }
                                .onChange(of: hostId) { newValue in
                                    if newValue.count > Constants.MIMEI_ID_LENGTH {
                                        hostId = String(newValue.prefix(Constants.MIMEI_ID_LENGTH))
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
                        Text(hproseInstance.appUser.isGuest ? "Create Account" : "Save")
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
            .onAppear {
                let appUser = hproseInstance.appUser
                if !appUser.isGuest {
                    username = appUser.username ?? ""
                    alias = appUser.name ?? ""
                    profile = appUser.profile ?? ""
                    hostId = appUser.hostIds?.first ?? ""
                    avatarId = appUser.avatar
                }
            }
        }
    }

    private func handleSubmit() {
        // Validation
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "Username is required."
            return
        }
        if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hproseInstance.appUser.isGuest {
            errorMessage = "Password is required."
            return
        }
        if hostId.trimmingCharacters(in: .whitespacesAndNewlines).count != 0 && hostId.trimmingCharacters(in: .whitespacesAndNewlines).count != Constants.MIMEI_ID_LENGTH {
            errorMessage = "Host ID must be \(Constants.MIMEI_ID_LENGTH) characters if provided."
            return
        }
        if hproseInstance.appUser.isGuest {
            // Registration: password required and must match
            if password != confirmPassword {
                errorMessage = "Passwords do not match."
                return
            }
        } else {
            // Edit: password optional, but if provided, must match confirm
            if !password.isEmpty && password != confirmPassword {
                errorMessage = "Passwords do not match."
                return
            }
        }
        errorMessage = nil
        onSubmit(
            username,
            password.isEmpty ? nil : password,
            alias.isEmpty ? nil : alias,
            profile.isEmpty ? nil : profile,
            hostId
        )
        dismiss()
    }
}

