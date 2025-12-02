//
//  Registration.swift
//  Tweet
//
//  Created by Tomás Hongo on 2025/5/24.
//

import SwiftUI
import PhotosUI

@available(iOS 16.0, *)
struct RegistrationView: View {
    @Environment(\.dismiss) private var dismiss
    var onSubmit: (String, String?, String?, String?, String?) async throws -> Void // username, password, alias, profile, hostId
    var onSubmissionStateChange: ((Bool) -> Void)? = nil // Callback for submission state
    var onRegistrationFailure: ((String) -> Void)? = nil // Callback for registration failure

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var alias: String = ""
    @State private var profile: String = ""
    @State private var hostId: String = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?
    @State private var isSubmitting = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .error
    @State private var showExitConfirmation = false
    @State private var hasUnsavedChanges = false
    @State private var hasAcceptedTerms = false
    @State private var showTermsOfService = false
    @EnvironmentObject private var hproseInstance: HproseInstance

    enum Field: Hashable {
        case username, password, confirmPassword, alias, profile, hostId
    }

    init(onSubmit: @escaping (String, String?, String?, String?, String?) async throws -> Void, onSubmissionStateChange: ((Bool) -> Void)? = nil, onRegistrationFailure: ((String) -> Void)? = nil) {
        self.onSubmit = onSubmit
        self.onSubmissionStateChange = onSubmissionStateChange
        self.onRegistrationFailure = onRegistrationFailure
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {

                    Group {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey("Username *"))
                                .font(.footnote)
                                .foregroundColor(.themeText)
                            TextField(LocalizedStringKey("Username"), text: $username)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .autocapitalization(.none)
                                .disabled(!hproseInstance.appUser.isGuest) // Username cannot be changed
                                .focused($focusedField, equals: .username)
                                .contentShape(Rectangle())
                                .onTapGesture { focusedField = .username }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey("Password *"))
                                .font(.footnote)
                                .foregroundColor(.themeText)
                            SecureField(LocalizedStringKey("Password"), text: $password)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .focused($focusedField, equals: .password)
                                .contentShape(Rectangle())
                                .onTapGesture { focusedField = .password }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey("Confirm Password"))
                                .font(.footnote)
                                .foregroundColor(.themeText)
                            SecureField(LocalizedStringKey("Confirm Password"), text: $confirmPassword)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .focused($focusedField, equals: .confirmPassword)
                                .contentShape(Rectangle())
                                .onTapGesture { focusedField = .confirmPassword }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey("Alias"))
                                .font(.footnote)
                                .foregroundColor(.themeText)
                            TextField(LocalizedStringKey("Alias"), text: $alias)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .focused($focusedField, equals: .alias)
                                .contentShape(Rectangle())
                                .onTapGesture { focusedField = .alias }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey("Profile"))
                                .font(.footnote)
                                .foregroundColor(.themeText)
                            TextEditor(text: $profile)
                                .frame(minHeight: 60, maxHeight: 120)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.themeBorder.opacity(0.3)))
                                .focused($focusedField, equals: .profile)
                                .onTapGesture { focusedField = .profile }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedStringKey("Host ID"))
                                .font(.footnote)
                                .foregroundColor(.themeText)
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
                    }

                    // Terms of Service Acceptance
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            Button(action: {
                                hasAcceptedTerms.toggle()
                            }) {
                                Image(systemName: hasAcceptedTerms ? "checkmark.square.fill" : "square")
                                    .foregroundColor(hasAcceptedTerms ? .blue : .gray)
                                    .font(.footnote)
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 0) {
                                    Text(LocalizedStringKey("I agree to the "))
                                        .font(.footnote) +
                                    Text(LocalizedStringKey("Terms of Service"))
                                        .font(.footnote)
                                        .foregroundColor(.blue)
                                        .underline() +
                                    Text(LocalizedStringKey(" and acknowledge that there is no tolerance for objectionable content or abusive users."))
                                        .font(.footnote)
                                }
                            }
                            .onTapGesture {
                                showTermsOfService = true
                            }
                        }
                        
                        if !hasAcceptedTerms && errorMessage != nil {
                            Text(LocalizedStringKey("You must accept the Terms of Service to continue."))
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 8)

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
                            Text(isSubmitting ? NSLocalizedString("Creating Account...", comment: "Account creation progress") : NSLocalizedString("Create Account", comment: "Create account button"))
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isSubmitting ? Color.themeAccent.opacity(0.6) : Color.themeAccent)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(isSubmitting)
                }
                .padding()
            }
            .navigationBarItems(trailing: Button(NSLocalizedString("Close", comment: "Close button")) { 
                if hasUnsavedChanges {
                    showExitConfirmation = true
                } else {
                    dismiss()
                }
            })
            .overlay(
                // Toast message overlay
                VStack {
                    Spacer()
                    if showToast {
                        ToastView(message: toastMessage, type: toastType)
                            .padding(.bottom, 40)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: showToast)
            )
            .onAppear {
                // No default cloudDrivePort - user must configure if needed
            }
            .onChange(of: username) { _, _ in checkForChanges() }
            .onChange(of: password) { _, _ in checkForChanges() }
            .onChange(of: confirmPassword) { _, _ in checkForChanges() }
            .onChange(of: alias) { _, _ in checkForChanges() }
            .onChange(of: profile) { _, _ in checkForChanges() }
            .onChange(of: hostId) { _, _ in checkForChanges() }
            .sheet(isPresented: $showTermsOfService) {
                TermsOfServiceView(
                    hasAcceptedTerms: $hasAcceptedTerms,
                    onAccept: {
                        // Terms accepted, no additional action needed
                    }
                )
            }
            .confirmationDialog(
                NSLocalizedString("Unsaved Changes", comment: "Confirmation dialog title"),
                isPresented: $showExitConfirmation,
                titleVisibility: .visible
            ) {
                Button(NSLocalizedString("Discard Changes", comment: "Discard changes button"), role: .destructive) {
                    dismiss()
                }
                Button(NSLocalizedString("Continue Editing", comment: "Continue editing button"), role: .cancel) {
                    // Do nothing, just dismiss the dialog
                }
            } message: {
                Text(NSLocalizedString("You have unsaved changes. Are you sure you want to exit without saving?", comment: "Confirmation dialog message"))
            }
        }
    }

    private func handleSubmit() {
        // Prevent repeated submission
        guard !isSubmitting else { return }
        
        // Validation
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = NSLocalizedString("Username is required.", comment: "Validation error")
            return
        }
        if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = NSLocalizedString("Password is required.", comment: "Validation error")
            return
        }
        if password != confirmPassword {
            errorMessage = NSLocalizedString("Passwords do not match.", comment: "Validation error")
            return
        }
        if hostId.trimmingCharacters(in: .whitespacesAndNewlines).count != 0 && hostId.trimmingCharacters(in: .whitespacesAndNewlines).count != Constants.MIMEI_ID_LENGTH {
            errorMessage = String(format: NSLocalizedString("Host ID must be %d characters if provided.", comment: "Validation error"), Constants.MIMEI_ID_LENGTH)
            return
        }
        
        // Validate terms acceptance
        if !hasAcceptedTerms {
            errorMessage = NSLocalizedString("You must accept the Terms of Service to continue.", comment: "Validation error")
            return
        }
        
        errorMessage = nil
        
        // Set loading state
        isSubmitting = true
        onSubmissionStateChange?(true) // Notify parent about submission start
        
        // Call the submit function asynchronously
        Task {
            do {
                try await onSubmit(
                    username,
                    password.isEmpty ? nil : password,
                    alias.isEmpty ? nil : alias,
                    profile.isEmpty ? nil : profile,
                    hostId
                )
                
                // Show success message and dismiss after a delay
                await MainActor.run {
                    isSubmitting = false
                    onSubmissionStateChange?(false)
                    showToastMessage(NSLocalizedString("Registration successful. Please wait a few minutes before logging in.", comment: "Registration success message with login reminder"), type: .success)
                    
                    // Dismiss after showing success message for 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        dismiss()
                    }
                }
            } catch {
                // Handle registration failure with toast
                await MainActor.run {
                    let errorMessage = ErrorMessageHelper.userFriendlyMessage(from: error)
                    showToastMessage(errorMessage, type: .error)
                    onRegistrationFailure?(errorMessage)
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
        // Success messages show for 3 seconds, error messages for 3 seconds
        let duration: TimeInterval = type == .error ? 3.0 : 3.0
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            withAnimation { showToast = false }
        }
    }
    
    private func checkForChanges() {
        // Check if any field has been modified from initial state
        let hasChanges = !username.isEmpty || 
                        !password.isEmpty || 
                        !confirmPassword.isEmpty || 
                        !alias.isEmpty || 
                        !profile.isEmpty || 
                        !hostId.isEmpty ||
                        hasAcceptedTerms
        
        hasUnsavedChanges = hasChanges
    }
}
