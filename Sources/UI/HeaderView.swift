import SwiftUI

struct HeaderView: View {
    @State private var isLoginSheetPresented = false
    @State private var isSettingsSheetPresented = false
    @EnvironmentObject private var userViewModel: UserViewModel
    
    let appUser = HproseInstance.shared.appUser
    
    var body: some View {
        HStack {
            // Left: User Avatar
            Button(action: {
                if userViewModel.isLoggedIn {
                    // TODO: Navigate to profile
                } else {
                    isLoginSheetPresented = true
                }
            }) {
                if let avatarURL = appUser.avatarUrl {
                    AsyncImage(url: URL(string: avatarURL)) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .foregroundColor(.gray)
                }
            }
            
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
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Welcome to dTweet")
                    .font(.title)
                    .fontWeight(.bold)
                
                TextField("Username", text: $username)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                
                SecureField("Password", text: $password)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Button(action: {
                    // TODO: Implement login
                }) {
                    Text("Login")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                
                Button("Don't have an account? Register") {
                    showRegistration = true
                }
                .foregroundColor(.blue)
            }
            .padding()
            .navigationBarItems(trailing: Button("Close") {
                dismiss()
            })
            .sheet(isPresented: $showRegistration) {
                RegistrationView()
            }
        }
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

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var userViewModel: UserViewModel
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Account")) {
                    if userViewModel.isLoggedIn {
                        Button("Logout") {
                            // TODO: Implement logout
                        }
                        .foregroundColor(.red)
                    }
                }
                
                Section(header: Text("App Settings")) {
                    Toggle("Dark Mode", isOn: .constant(false))
                    Toggle("Notifications", isOn: .constant(true))
                }
                
                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
        }
    }
}

#Preview {
    HeaderView()
        .environmentObject(UserViewModel())
} 
