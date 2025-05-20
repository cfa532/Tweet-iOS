import SwiftUI

struct AppHeaderView: View {
    @State private var isLoginSheetPresented = false
    @State private var isSettingsSheetPresented = false
    @StateObject private var hproseInstance = HproseInstance.shared
    @State private var showProfile = false
//    @EnvironmentObject private var userViewModel: UserViewModel
    
    var body: some View {
        HStack {
            // Left: User Avatar
            Button(action: {
                if hproseInstance.appUser.isGuest {
                    isLoginSheetPresented = true
                } else {
                    showProfile = true
                }
            }) {
                Avatar(user: hproseInstance.appUser, size: 32)
            }
            .background(
                NavigationLink(
                    destination: ProfileView(user: hproseInstance.appUser), // Replace [] with actual tweets
                    isActive: $showProfile
                ) {
                    EmptyView()
                }
                .hidden()
            )
            
            Spacer()
            
            // Middle: App Logo
            Image("AppIcon") // Make sure to add this to your asset catalog
                .resizable()
                .scaledToFit()
                .frame(height: 32)
            
            Spacer()
            
            // Right: Settings Button
            Button(action: {
                isSettingsSheetPresented = true
            }) {
                Image(systemName: "gearshape.fill")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundColor(.primary)
            }
        }
        .padding(.horizontal)
        .sheet(isPresented: $isLoginSheetPresented) {
            LoginView()
        }
        .sheet(isPresented: $isSettingsSheetPresented) {
            SettingsView()
        }
    }
}

struct LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var showRegistration = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Welcome to dTweet")
                    .font(.title)
                    .fontWeight(.bold)
                
                TextField("Username", text: $username)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .disabled(isLoading)
                
                SecureField("Password", text: $password)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .disabled(isLoading)
                
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
                RegistrationView()
            }
            .alert("Login Successful", isPresented: $showSuccess) {
                Button("OK") {
                    dismiss()
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
            let hproseInstance = HproseInstance.shared
            if let userId = try await hproseInstance.getUserId(username) {
                
                // retrieve user object from the net.
                if var user = try await hproseInstance.getUser(userId) {
                    user.password = password
                    let result = try await hproseInstance.login(user)
                    if result["status"] as? String == "success" {
                        showSuccess = true
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

struct RegistrationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Create Account")
                    .font(.title)
                    .fontWeight(.bold)
                
                TextField("Username", text: $username)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                
                TextField("Email", text: $email)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .keyboardType(.emailAddress)
                
                SecureField("Password", text: $password)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                SecureField("Confirm Password", text: $confirmPassword)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Button(action: {
                    // TODO: Implement registration
                }) {
                    Text("Register")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
            .padding()
            .navigationBarItems(trailing: Button("Close") {
                dismiss()
            })
        }
    }
}

#Preview {
    AppHeaderView()
        .environmentObject(UserViewModel())
} 
