//
//  ProfileEditView.swift
//  Tweet
//
//  Created by 超方 on 2025/5/24.
//

import SwiftUI
import PhotosUI

@available(iOS 16.0, *)
struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    var onSubmit: (String, String?, String?, String?, String?, Int) async throws -> Void // username, password, alias, profile, hostId, cloudDrivePort
    var onSubmissionStateChange: ((Bool) -> Void)? = nil // Callback for submission state
    var onAvatarUploadStateChange: ((Bool) -> Void)? = nil // Callback for avatar upload state
    var onAvatarUploadSuccess: (() -> Void)? = nil // Callback for successful avatar upload
    var onAvatarUploadFailure: ((String) -> Void)? = nil // Callback for failed avatar upload
    var onProfileUpdateFailure: ((String) -> Void)? = nil // Callback for profile update failure

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var alias: String = ""
    @State private var profile: String = ""
    @State private var hostId: String = ""
    @State private var cloudDrivePort: String = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?
    @State private var avatarId: String? = nil
    @State private var showImagePicker = false
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var isUploadingAvatar = false
    @State private var avatarUploadError: String? = nil
    @State private var isSubmitting = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .error
    @State private var showExitConfirmation = false
    @State private var hasUnsavedChanges = false
    @State private var initialValues: [String: String] = [:]
    @State private var avatarUpdateTrigger = 0 // Force avatar view update
    @State private var showImageCropper = false
    @State private var selectedImage: UIImage? = nil
    @EnvironmentObject private var hproseInstance: HproseInstance

    enum Field: Hashable {
        case password, confirmPassword, alias, profile, hostId, cloudDrivePort
    }

    init(onSubmit: @escaping (String, String?, String?, String?, String?, Int) async throws -> Void, onSubmissionStateChange: ((Bool) -> Void)? = nil, onAvatarUploadStateChange: ((Bool) -> Void)? = nil, onAvatarUploadSuccess: (() -> Void)? = nil, onAvatarUploadFailure: ((String) -> Void)? = nil, onProfileUpdateFailure: ((String) -> Void)? = nil) {
        self.onSubmit = onSubmit
        self.onSubmissionStateChange = onSubmissionStateChange
        self.onAvatarUploadStateChange = onAvatarUploadStateChange
        self.onAvatarUploadSuccess = onAvatarUploadSuccess
        self.onAvatarUploadFailure = onAvatarUploadFailure
        self.onProfileUpdateFailure = onProfileUpdateFailure
    }

    private var avatarSection: some View {
        VStack {
            ZStack(alignment: .bottomTrailing) {
                Avatar(user: hproseInstance.appUser, size: 80)
                    .id("profile_avatar_\(avatarUpdateTrigger)")
                    .onTapGesture { showImagePicker = true }
                    .overlay(uploadingOverlay)
                
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
        .onChange(of: selectedPhoto) { _, newItem in
            if let item = newItem {
                NSLog("📸 [Avatar] Photo selected, loading image...")
                Task {
                    do {
                        if let data = try await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            NSLog("✅ [Avatar] Image loaded successfully, size: \(image.size)")
                            await MainActor.run {
                                selectedImage = image
                                showImageCropper = true
                                NSLog("🎬 [Avatar] showImageCropper set to true")
                            }
                        } else {
                            NSLog("⚠️ [Avatar] Failed to load image data or create UIImage")
                        }
                    } catch {
                        NSLog("⚠️ [Avatar Upload] Failed to load image: \(error.localizedDescription)")
                        avatarUploadError = NSLocalizedString("Failed to load image.", comment: "Image loading error")
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var uploadingOverlay: some View {
        if isUploadingAvatar {
            ZStack {
                Color.black.opacity(0.6)
                    .clipShape(Circle())
                
                VStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.2)
                    
                    Text(NSLocalizedString("Uploading...", comment: "Upload progress message"))
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
            .frame(width: 80, height: 80)
        }
    }
    
    private var formFields: some View {
        VStack(spacing: 20) {
            avatarSection

            // Username display (read-only)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(LocalizedStringKey("Username"))
                        .font(.caption)
                        .foregroundColor(.themeSecondaryText)
                    Spacer()
                }
                Text(username)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .foregroundColor(.secondary)
            }

            // Password fields (optional for profile update)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(LocalizedStringKey("New Password (optional)"))
                        .font(.caption)
                        .foregroundColor(.themeSecondaryText)
                    Spacer()
                }
                SecureField(LocalizedStringKey("New Password"), text: $password)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .focused($focusedField, equals: .password)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .password }
            }

            if !password.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey("Confirm New Password"))
                        .font(.caption)
                        .foregroundColor(.themeSecondaryText)
                    SecureField(LocalizedStringKey("Confirm New Password"), text: $confirmPassword)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused($focusedField, equals: .confirmPassword)
                        .contentShape(Rectangle())
                        .onTapGesture { focusedField = .confirmPassword }
                }
            }

            // Editable fields
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("Alias"))
                    .font(.caption)
                    .foregroundColor(.themeSecondaryText)
                TextField(LocalizedStringKey("Alias"), text: $alias)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .focused($focusedField, equals: .alias)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .alias }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("Profile"))
                    .font(.caption)
                    .foregroundColor(.themeSecondaryText)
                TextEditor(text: $profile)
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.themeBorder.opacity(0.3)))
                    .focused($focusedField, equals: .profile)
                    .onTapGesture { focusedField = .profile }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("Host ID (optional)"))
                    .font(.caption)
                    .foregroundColor(.themeSecondaryText)
                TextField("", text: $hostId)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .focused($focusedField, equals: .hostId)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .hostId }
                    .onChange(of: hostId) { _, newValue in
                        if newValue.count > Constants.MIMEI_ID_LENGTH {
                            hostId = String(newValue.prefix(Constants.MIMEI_ID_LENGTH))
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("Cloud Drive Port"))
                    .font(.caption)
                    .foregroundColor(.themeSecondaryText)
                TextField(LocalizedStringKey("Cloud Drive Port"), text: $cloudDrivePort)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .cloudDrivePort)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .cloudDrivePort }
                    .onChange(of: cloudDrivePort) { _, newValue in
                        // Only allow numeric input
                        let filtered = newValue.filter { $0.isNumber }
                        if filtered != newValue {
                            cloudDrivePort = filtered
                        }
                    }
            }

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            DebounceButton(
                cooldownDuration: 1.0,
                enableVibration: false
            ) {
                handleSubmit()
            } label: {
                HStack {
                    if isSubmitting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    }
                    Text(isSubmitting ? NSLocalizedString("Saving...", comment: "Save progress message") : NSLocalizedString("Save", comment: "Save button"))
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background((isSubmitting || isUploadingAvatar) ? Color.themeAccent.opacity(0.6) : Color.themeAccent)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(isSubmitting || isUploadingAvatar)
        }
        .padding()
    }
    
    private var mainContent: some View {
        ScrollView {
            formFields
        }
        .navigationBarItems(trailing: closeButton)
        .overlay(toastOverlay)
        .onAppear(perform: loadInitialData)
        .onChange(of: password) { _, _ in checkForChanges() }
        .onChange(of: confirmPassword) { _, _ in checkForChanges() }
        .onChange(of: alias) { _, _ in checkForChanges() }
        .onChange(of: profile) { _, _ in checkForChanges() }
        .onChange(of: hostId) { _, _ in checkForChanges() }
        .onChange(of: cloudDrivePort) { _, _ in checkForChanges() }
        .confirmationDialog(
            NSLocalizedString("Unsaved Changes", comment: "Confirmation dialog title"),
            isPresented: $showExitConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("Discard Changes", comment: "Discard changes button"), role: .destructive) {
                dismiss()
            }
            Button(NSLocalizedString("Continue Editing", comment: "Continue editing button"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("You have unsaved changes. Are you sure you want to exit without saving?", comment: "Confirmation dialog message"))
        }
    }
    
    private var closeButton: some View {
        Button(NSLocalizedString("Close", comment: "Close button")) {
            if hasUnsavedChanges {
                showExitConfirmation = true
            } else {
                dismiss()
            }
        }
    }
    
    @ViewBuilder
    private var toastOverlay: some View {
        VStack {
            Spacer()
            if showToast {
                ToastView(message: toastMessage, type: toastType)
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showToast)
    }
    
    @ViewBuilder
    private var cropperView: some View {
        if let image = selectedImage {
            CircularImageCropperView(
                image: image,
                onCrop: { croppedImage in
                    NSLog("✅ [Avatar] User tapped Done, cropping image")
                    showImageCropper = false
                    uploadCroppedImage(croppedImage)
                },
                onCancel: {
                    NSLog("❌ [Avatar] User cancelled crop")
                    showImageCropper = false
                    selectedImage = nil
                    selectedPhoto = nil
                }
            )
            .onAppear {
                NSLog("🎨 [Avatar] Presenting CircularImageCropperView")
            }
        } else {
            Color.clear
                .onAppear {
                    NSLog("⚠️ [Avatar] fullScreenCover triggered but selectedImage is nil")
                    showImageCropper = false
                }
        }
    }
    
    var body: some View {
        NavigationView {
            mainContent
        }
        .fullScreenCover(isPresented: $showImageCropper) {
            cropperView
        }
        .onChange(of: showImageCropper) { _, newValue in
            NSLog("🔄 [Avatar] showImageCropper changed to: \(newValue)")
        }
    }
    
    private func loadInitialData() {
        let appUser = hproseInstance.appUser
        username = appUser.username ?? ""
        alias = appUser.name ?? ""
        profile = appUser.profile ?? ""
        hostId = appUser.hostIds?.first ?? ""
        avatarId = appUser.avatar
        cloudDrivePort = (appUser.cloudDrivePort == 0) ? "" : appUser.cloudDrivePort.description
        
        // Store initial values for change detection
        initialValues = [
            "username": username,
            "alias": alias,
            "profile": profile,
            "hostId": hostId,
            "cloudDrivePort": cloudDrivePort
        ]
    }

    private func uploadCroppedImage(_ image: UIImage) {
        Task {
            isUploadingAvatar = true
            avatarUploadError = nil
            onAvatarUploadStateChange?(true) // Notify parent about upload start
            
            do {
                // Convert UIImage to JPEG data
                guard let data = image.jpegData(compressionQuality: 0.9) else {
                    throw NSError(domain: "ProfileEditView", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to data"])
                }
                
                let typeIdentifier = "public.jpeg"
                let fileName = "avatar_\(Int(Date().timeIntervalSince1970)).jpg"
                let (uploaded, _) = try await hproseInstance.uploadToIPFS(data: data, typeIdentifier: typeIdentifier, fileName: fileName, referenceId: hproseInstance.appUser.mid)
                
                NSLog("DEBUG: [Avatar Upload] uploadToIPFS returned - uploaded: \(uploaded?.mid ?? "NIL"), isEmpty: \(uploaded?.mid.isEmpty ?? true)")
                
                if let uploaded = uploaded, !uploaded.mid.isEmpty {
                    NSLog("DEBUG: [Avatar Upload] Starting avatar update process")
                    
                    let oldAvatar = await MainActor.run { hproseInstance.appUser.avatar }
                    
                    // Wait for server to confirm avatar update
                    let confirmedAvatar = try await hproseInstance.setUserAvatar(user: hproseInstance.appUser, avatar: uploaded.mid)
                    
                    await MainActor.run {
                        NSLog("🔄 [Avatar Upload] Old avatar: \(oldAvatar ?? "nil")")
                        NSLog("🔄 [Avatar Upload] New confirmed avatar: \(confirmedAvatar)")
                        
                        // Clear old avatar image cache
                        if let old = oldAvatar {
                            ImageCacheManager.shared.clearCache(for: old)
                            NSLog("🗑️ [Avatar Upload] Cleared cache for old avatar: \(old)")
                        }
                        
                        // Update appUser with server-confirmed avatar
                        hproseInstance.appUser.avatar = confirmedAvatar
                        NSLog("✅ [Avatar Upload] Updated appUser.avatar to: \(hproseInstance.appUser.avatar ?? "nil")")
                    }
                    
                    // CRITICAL: Save synchronously to ensure Core Data has new avatar
                    NSLog("💾 [Avatar Upload] Saving appUser to Core Data...")
                    TweetCacheManager.shared.saveUserAndWait(hproseInstance.appUser)
                    NSLog("✅ [Avatar Upload] Saved to Core Data (appUser IS the singleton, no need to update separately)")
                    
                    await MainActor.run {
                        NSLog("🔵 [Avatar Upload] MainActor: Stopping upload state...")
                        // Stop uploading state FIRST
                        isUploadingAvatar = false
                        NSLog("🔵 [Avatar Upload] isUploadingAvatar set to: \(isUploadingAvatar)")
                        onAvatarUploadStateChange?(false)
                        
                        // Force ProfileEditView's Avatar to recreate
                        avatarUpdateTrigger += 1
                        NSLog("🔵 [Avatar Upload] avatarUpdateTrigger incremented to: \(avatarUpdateTrigger)")
                        
                        // Broadcast notification ONCE to update all Avatar views
                        NotificationCenter.default.post(
                            name: .avatarDidChange,
                            object: nil,
                            userInfo: ["userId": hproseInstance.appUser.mid]
                        )
                        NSLog("📢 [Avatar Upload] Posted notification to update all avatars")
                        
                        // Clean up
                        selectedImage = nil
                        selectedPhoto = nil
                        NSLog("🔵 [Avatar Upload] Cleanup complete, upload state should be cleared")
                    }
                    // Notify success
                    onAvatarUploadSuccess?()
                } else {
                    NSLog("⚠️ [Avatar Upload] Upload check failed - uploaded: \(uploaded != nil), mid: \(uploaded?.mid ?? "NIL")")
                    let errorMessage = NSLocalizedString("Failed to upload avatar.", comment: "Avatar upload error")
                    await MainActor.run {
                        avatarUploadError = errorMessage
                        isUploadingAvatar = false
                        onAvatarUploadStateChange?(false)
                        selectedImage = nil
                        selectedPhoto = nil
                    }
                    onAvatarUploadFailure?(errorMessage)
                }
            } catch {
                let errorMessage = error.localizedDescription
                NSLog("⚠️ [Avatar Upload] Error: \(errorMessage)")
                await MainActor.run {
                    avatarUploadError = errorMessage
                    isUploadingAvatar = false
                    onAvatarUploadStateChange?(false)
                    selectedImage = nil
                    selectedPhoto = nil
                }
                onAvatarUploadFailure?(errorMessage)
            }
        }
    }
    
    private func handleSubmit() {
        // Prevent repeated submission
        guard !isSubmitting else { return }
        
        // Validation
        if hostId.trimmingCharacters(in: .whitespacesAndNewlines).count != 0 && hostId.trimmingCharacters(in: .whitespacesAndNewlines).count != Constants.MIMEI_ID_LENGTH {
            errorMessage = String(format: NSLocalizedString("Host ID must be %d characters if provided.", comment: "Validation error"), Constants.MIMEI_ID_LENGTH)
            return
        }
        
        // Validate cloudDrivePort
        if let port = Int(cloudDrivePort), port < 8000 || port > 9000 {
            errorMessage = NSLocalizedString("Cloud Drive Port must be between 8000 and 9000.", comment: "Validation error")
            return
        }
        
        // Password validation (optional, but if provided, must match confirm)
        if !password.isEmpty && password != confirmPassword {
            errorMessage = NSLocalizedString("Passwords do not match.", comment: "Validation error")
            return
        }
        
        errorMessage = nil
        
        // Set loading state
        isSubmitting = true
        onSubmissionStateChange?(true) // Notify parent about submission start
        
        // Call the submit function asynchronously
        Task {
            do {
                // Convert cloudDrivePort: empty string → 0 (to explicitly clear on server)
                let portValue: Int
                if cloudDrivePort.isEmpty {
                    portValue = 0  // Explicitly send 0 to clear the port
                } else {
                    portValue = Int(cloudDrivePort) ?? 0
                }
                
                try await onSubmit(
                    username,
                    password.isEmpty ? nil : password,
                    alias.isEmpty ? nil : alias,
                    profile.isEmpty ? nil : profile,
                    hostId,
                    portValue
                )
                
                // Success - update initial values and close the screen
                await MainActor.run {
                    // Update initial values to reflect the saved state
                    initialValues = [
                        "username": username,
                        "alias": alias,
                        "profile": profile,
                        "hostId": hostId,
                        "cloudDrivePort": cloudDrivePort
                    ]
                    
                    // Reset password fields since they were saved
                    password = ""
                    confirmPassword = ""
                    
                    // Reset unsaved changes flag
                    hasUnsavedChanges = false
                    
                    // Reset submission state
                    isSubmitting = false
                    onSubmissionStateChange?(false)
                    
                    // Show success toast and close the screen
                    showToastMessage(NSLocalizedString("Profile updated successfully", comment: "Success message"), type: .success)
                    
                    // Close the screen after a short delay to show the success toast
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        dismiss()
                    }
                }
            } catch {
                // Handle profile update failure with toast
                await MainActor.run {
                    let errorMessage = error.localizedDescription
                    showToastMessage(errorMessage, type: .error)
                    onProfileUpdateFailure?(errorMessage)
                    isSubmitting = false
                    onSubmissionStateChange?(false)
                }
            }
        }
    }
    
    private func showToastMessage(_ message: String, type: ToastView.ToastType) {
        toastMessage = message
        toastType = type
        showToast = true
        
        // Auto-hide toast after appropriate duration
        let duration: TimeInterval = type == .error ? 3.0 : 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            withAnimation { showToast = false }
        }
    }
    
    private func checkForChanges() {
        // Check if any field has been modified from initial state
        let hasChanges = !password.isEmpty || 
                        !confirmPassword.isEmpty || 
                        alias != initialValues["alias"] || 
                        profile != initialValues["profile"] || 
                        hostId != initialValues["hostId"] || 
                        cloudDrivePort != initialValues["cloudDrivePort"]
        
        hasUnsavedChanges = hasChanges
    }
}
