//
//  Registration.swift
//  Tweet
//
//  Created by 超方 on 2025/5/24.
//

import SwiftUI

struct RegistrationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @FocusState private var focusedField: Field?
    
    enum Field: Hashable {
        case username
        case email
        case password
        case confirmPassword
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Create Account")
                    .font(.title)
                    .fontWeight(.bold)
                
                Group {
                    TextField("Username", text: $username)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .focused($focusedField, equals: .username)
                        .contentShape(Rectangle())
                        .onTapGesture { focusedField = .username }
                    
                    TextField("Email", text: $email)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .keyboardType(.emailAddress)
                        .focused($focusedField, equals: .email)
                        .contentShape(Rectangle())
                        .onTapGesture { focusedField = .email }
                    
                    SecureField("Password", text: $password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused($focusedField, equals: .password)
                        .contentShape(Rectangle())
                        .onTapGesture { focusedField = .password }
                    
                    SecureField("Confirm Password", text: $confirmPassword)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .focused($focusedField, equals: .confirmPassword)
                        .contentShape(Rectangle())
                        .onTapGesture { focusedField = .confirmPassword }
                }
                
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

