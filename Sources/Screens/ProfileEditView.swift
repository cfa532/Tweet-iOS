//
//  ProfileEditView.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/5/24.
//

import SwiftUI
import PhotosUI

@available(iOS 16.0, *)
struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    var onSubmit: (String, String?, String?, String?, String?, Int, String?) async throws -> Void // username, password, alias, profile, hostId, cloudDrivePort, domainToShare
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
    @State private var domainToShare: String = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?
    @State private var avatarId: String? = nil
    @State private var isUploadingAvatar = false
    @State private var avatarUploadError: String? = nil
    @State private var isSubmitting = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .error
    @State private var showExitConfirmation = false
    @State private var hasUnsavedChanges = false
    @State private var initialValues: [String: String] = [:]
    @State private var originalHostId: String? = nil
    @State private var originalCloudDrivePort: Int = 0
    @State private var originalDomainToShare: String? = nil
    @State private var avatarUpdateTrigger = 0 // Force avatar view update
    @State private var showImageCropper = false
    @State private var showAgentTokenSheet = false
    @State private var agentToken: String = ""
    @State private var isGeneratingToken = false
    @State private var showTokenCopiedAlert = false
    @State private var showRevokeConfirmation = false
    @EnvironmentObject private var hproseInstance: HproseInstance

    enum Field: Hashable {
        case password, confirmPassword, alias, profile, hostId, cloudDrivePort, shareDomain
    }

    init(onSubmit: @escaping (String, String?, String?, String?, String?, Int, String?) async throws -> Void, onSubmissionStateChange: ((Bool) -> Void)? = nil, onAvatarUploadStateChange: ((Bool) -> Void)? = nil, onAvatarUploadSuccess: (() -> Void)? = nil, onAvatarUploadFailure: ((String) -> Void)? = nil, onProfileUpdateFailure: ((String) -> Void)? = nil) {
        self.onSubmit = onSubmit
        self.onSubmissionStateChange = onSubmissionStateChange
        self.onAvatarUploadStateChange = onAvatarUploadStateChange
        self.onAvatarUploadSuccess = onAvatarUploadSuccess
        self.onAvatarUploadFailure = onAvatarUploadFailure
        self.onProfileUpdateFailure = onProfileUpdateFailure
    }

    private var shareDomainPlaceholder: String {
        // Use backend domain from check_upgrade (not user's override) for placeholder
        let domain = hproseInstance.backendDomainToShare
        if domain.isEmpty {
            return ""
        }
        if domain.hasPrefix("https://") {
            return String(domain.dropFirst("https://".count))
        } else if domain.hasPrefix("http://") {
            return String(domain.dropFirst("http://".count))
        }
        return domain
    }
    
    private var hostIdPlaceholder: String {
        return hproseInstance.appUser.hostIds?.first ?? ""
    }
    
    private var cloudDrivePortPlaceholder: String {
        let port = hproseInstance.appUser.cloudDrivePort
        return (port != 0) ? String(port) : ""
    }
    
    private var profilePlaceholder: String {
        return hproseInstance.appUser.profile ?? ""
    }
    
    private var aliasPlaceholder: String {
        return hproseInstance.appUser.name ?? ""
    }
    
    private var avatarSection: some View {
        VStack {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    Avatar(user: hproseInstance.appUser, size: 80)
                        .id("profile_avatar_\(avatarUpdateTrigger)")
                    
                    // Upload progress overlay
                    if isUploadingAvatar {
                        ZStack {
                            Color.black.opacity(0.7)
                                .clipShape(Circle())
                            
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.2)
                        }
                        .frame(width: 80, height: 80)
                        .transition(.opacity)
                    }
                }
                .onTapGesture { 
                    if !isUploadingAvatar {
                        showImageCropper = true
                    }
                }
                
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
    }
    
    private var formFields: some View {
        VStack(spacing: 20) {
            avatarSection

            // Username display (read-only)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(LocalizedStringKey("Username"))
                        .font(.caption)
                        .foregroundColor(.themeText)
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
                        .foregroundColor(.themeText)
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
                        .foregroundColor(.themeText)
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
                    .foregroundColor(.themeText)
                TextField(LocalizedStringKey("Alias"), text: $alias)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .focused($focusedField, equals: .alias)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .alias }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("Profile"))
                    .font(.caption)
                    .foregroundColor(.themeText)
                TextEditor(text: $profile)
                    .frame(minHeight: 60, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.themeBorder.opacity(0.3)))
                    .focused($focusedField, equals: .profile)
                    .onTapGesture { focusedField = .profile }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("Host ID"))
                    .font(.caption)
                    .foregroundColor(.themeText)
                TextField("", text: $hostId, prompt: Text(hostIdPlaceholder))
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
                    .foregroundColor(.themeText)
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

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("Share Domain"))
                    .font(.caption)
                    .foregroundColor(.themeText)
                TextField("", text: $domainToShare, prompt: Text(shareDomainPlaceholder))
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.URL)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .shareDomain)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .shareDomain }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("AI Agent Access"))
                    .font(.caption)
                    .foregroundColor(.themeText)
                Button {
                    showAgentTokenSheet = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey("Agent Token"))
                                .foregroundColor(.primary)
                            Text(hproseInstance.appUser.agentPublicKey != nil
                                 ? LocalizedStringKey("Token configured")
                                 : LocalizedStringKey("Not configured"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                }
            }

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            DebounceButton(
                cooldownDuration: 1.0,
                enableHaptic: false
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
        .sheet(isPresented: $showAgentTokenSheet) {
            AgentTokenView(
                agentToken: $agentToken,
                isGenerating: $isGeneratingToken,
                showCopiedAlert: $showTokenCopiedAlert,
                showRevokeConfirmation: $showRevokeConfirmation,
                hproseInstance: hproseInstance
            )
        }
        .onAppear(perform: loadInitialData)
        .onChange(of: password) { _, _ in checkForChanges() }
        .onChange(of: confirmPassword) { _, _ in checkForChanges() }
        .onChange(of: alias) { _, _ in checkForChanges() }
        .onChange(of: profile) { _, _ in checkForChanges() }
        .onChange(of: hostId) { _, _ in checkForChanges() }
        .onChange(of: cloudDrivePort) { _, _ in checkForChanges() }
        .onChange(of: domainToShare) { _, _ in checkForChanges() }
        .interactiveDismissDisabled(hasUnsavedChanges)
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
            checkForChanges() // Ensure we have the latest change state
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
        CircularImageCropperView(
            onCrop: { croppedImage in
                print("✅ [Avatar] User tapped Done, cropping image")
                showImageCropper = false
                uploadCroppedImage(croppedImage)
            },
            onCancel: {
                print("❌ [Avatar] User cancelled crop")
                showImageCropper = false
            }
        )
        .onAppear {
            print("🎨 [Avatar] Presenting CircularImageCropperView")
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
            print("🔄 [Avatar] showImageCropper changed to: \(newValue)")
        }
        .onChange(of: showExitConfirmation) { _, newValue in
            // When confirmation dialog is dismissed without action, ensure we check changes again
            if !newValue {
                checkForChanges()
            }
        }
    }
    
    private func loadInitialData() {
        let appUser = hproseInstance.appUser
        username = appUser.username ?? ""
        alias = appUser.name ?? "" // Show existing name in the field
        profile = appUser.profile ?? "" // Show existing profile in the field
        hostId = "" // Always leave hostId empty when profile editor opens
        avatarId = appUser.avatar
        cloudDrivePort = (appUser.cloudDrivePort == 0) ? "" : appUser.cloudDrivePort.description // Show existing cloudDrivePort value in the field
        // Show appUser.domainToShare if not empty, otherwise leave empty (placeholder will show system default)
        if let userDomain = appUser.domainToShare?.trimmingCharacters(in: .whitespacesAndNewlines), !userDomain.isEmpty {
            domainToShare = userDomain
        } else {
            domainToShare = ""
        }
        
        // Store original values to send if user doesn't provide new input
        originalHostId = appUser.hostIds?.first
        originalCloudDrivePort = appUser.cloudDrivePort
        originalDomainToShare = appUser.domainToShare
        
        // Store initial values for change detection
        initialValues = [
            "username": username,
            "alias": alias,
            "profile": profile,
            "hostId": hostId,
            "cloudDrivePort": cloudDrivePort,
            "domainToShare": domainToShare // This will be the user's domainToShare if not empty, or empty string
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
                
                print("DEBUG: [Avatar Upload] uploadToIPFS returned - uploaded: \(uploaded?.mid ?? "NIL"), isEmpty: \(uploaded?.mid.isEmpty ?? true)")
                
                if let uploaded = uploaded, !uploaded.mid.isEmpty {
                    print("DEBUG: [Avatar Upload] Starting avatar update process")
                    
                    let oldAvatar = await MainActor.run { hproseInstance.appUser.avatar }
                    
                    // Wait for server to confirm avatar update
                    let confirmedAvatar = try await hproseInstance.setUserAvatar(user: hproseInstance.appUser, avatar: uploaded.mid)
                    
                    await MainActor.run {
                        print("🔄 [Avatar Upload] Old avatar: \(oldAvatar ?? "nil")")
                        print("🔄 [Avatar Upload] New confirmed avatar: \(confirmedAvatar)")
                        
                        // Clear old avatar image cache
                        if let old = oldAvatar {
                            ImageCacheManager.shared.clearCache(for: old)
                            print("🗑️ [Avatar Upload] Cleared cache for old avatar: \(old)")
                        }
                        
                        // Update appUser with server-confirmed avatar
                        hproseInstance.appUser.avatar = confirmedAvatar
                        print("✅ [Avatar Upload] Updated appUser.avatar to: \(hproseInstance.appUser.avatar ?? "nil")")
                    }
                    
                    // Pre-cache the uploaded image locally so Avatar doesn't show spinner
                    let avatarAttachment = MimeiFileType(mid: confirmedAvatar, mediaType: .image)
                    _ = ImageCacheManager.shared.cacheImageData(data, for: avatarAttachment)
                    print("✅ [Avatar Upload] Pre-cached new avatar image locally")
                    
                    // Update UI state
                    await MainActor.run {
                        isUploadingAvatar = false
                        onAvatarUploadStateChange?(false)
                        avatarUpdateTrigger += 1
                        
                        // Broadcast to all avatars
                        NotificationCenter.default.post(
                            name: .avatarDidChange,
                            object: nil,
                            userInfo: ["userId": hproseInstance.appUser.mid]
                        )
                        print("✅ [Avatar Upload] Complete")
                    }
                    onAvatarUploadSuccess?()
                } else {
                    let errorMessage = NSLocalizedString("Failed to upload avatar.", comment: "Avatar upload error")
                    await MainActor.run {
                        avatarUploadError = errorMessage
                        isUploadingAvatar = false
                        onAvatarUploadStateChange?(false)
                        avatarUpdateTrigger += 1
                    }
                    onAvatarUploadFailure?(errorMessage)
                }
            } catch {
                let errorMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
                await MainActor.run {
                    avatarUploadError = errorMessage
                    isUploadingAvatar = false
                    onAvatarUploadStateChange?(false)
                    avatarUpdateTrigger += 1
                }
                onAvatarUploadFailure?(errorMessage)
            }
        }
    }
    
    private func handleSubmit() {
        // Prevent repeated submission
        guard !isSubmitting else { return }
        
        // Validation: if hostId is provided, it must be exactly 27 characters
        let trimmedHostId = hostId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHostId.isEmpty && trimmedHostId.count != Constants.MIMEI_ID_LENGTH {
            errorMessage = String(format: NSLocalizedString("Host ID must be %d characters if provided.", comment: "Validation error"), Constants.MIMEI_ID_LENGTH)
            return
        }
        
        // Validate cloudDrivePort: must be empty or a valid positive integer
        let trimmedPort = cloudDrivePort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPort.isEmpty {
            if Int(trimmedPort) == nil {
                errorMessage = NSLocalizedString("Cloud Drive Port must be a valid number.", comment: "Validation error")
                return
            }
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
                // For hostId, cloudDrivePort, and domainToShare:
                // If user provided input, use it; otherwise use original value
                let trimmedHostId = hostId.trimmingCharacters(in: .whitespacesAndNewlines)
                let hostIdValue = trimmedHostId.isEmpty ? originalHostId : trimmedHostId
                
                // For domainToShare: if empty, send empty string (will be converted to nil and excluded from JSON)
                let trimmedShareDomain = domainToShare.trimmingCharacters(in: .whitespacesAndNewlines)
                let shareDomainValue = trimmedShareDomain.isEmpty ? "" : trimmedShareDomain
                
                // For cloudDrivePort: if empty, use original value (or 0 if original was 0); if provided, use it
                let trimmedPort = cloudDrivePort.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalPortValue: Int
                if trimmedPort.isEmpty {
                    finalPortValue = originalCloudDrivePort
                } else {
                    finalPortValue = Int(trimmedPort) ?? originalCloudDrivePort
                }
                
                try await onSubmit(
                    username,
                    password.isEmpty ? nil : password,
                    alias.isEmpty ? nil : alias,
                    profile.isEmpty ? nil : profile,
                    hostIdValue,
                    finalPortValue,
                    shareDomainValue
                )
                
                // Success - update initial values and close the screen
                await MainActor.run {
                    // Update initial values to reflect the saved state
                    initialValues = [
                        "username": username,
                        "alias": alias,
                        "profile": profile,
                        "hostId": hostId,
                        "cloudDrivePort": cloudDrivePort,
                        "domainToShare": shareDomainValue
                    ]
                    
                    // Reset password fields since they were saved
                    password = ""
                    confirmPassword = ""
                    
                    // Reset unsaved changes flag
                    hasUnsavedChanges = false
                    
                    // Reset submission state
                    isSubmitting = false
                    onSubmissionStateChange?(false)
                    
                    // Normalize share domain field to trimmed value
                    domainToShare = shareDomainValue
                    
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
                    let errorMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
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
        // Normalize domainToShare for comparison (trim whitespace, treat empty as nil)
        let currentShareDomain = domainToShare.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialShareDomain = (initialValues["domainToShare"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrent = currentShareDomain.isEmpty ? "" : currentShareDomain
        let normalizedInitial = initialShareDomain.isEmpty ? "" : initialShareDomain
        
        // Check if any field has been modified from initial state
        let hasChanges = !password.isEmpty || 
                        !confirmPassword.isEmpty || 
                        alias != initialValues["alias"] || 
                        profile != initialValues["profile"] || 
                        hostId != initialValues["hostId"] || 
                        cloudDrivePort != initialValues["cloudDrivePort"] ||
                        normalizedCurrent != normalizedInitial
        
        hasUnsavedChanges = hasChanges
    }
}
