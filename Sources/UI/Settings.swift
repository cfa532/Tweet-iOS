//
//  Settings.swift
//  Tweet
//
//  Created by 超方 on 2025/5/20.
//

import SwiftUI


struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hproseInstance: HproseInstance
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Account")) {
                    if !hproseInstance.appUser.isGuest {
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

