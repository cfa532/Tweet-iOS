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
    @EnvironmentObject private var appUserStore: AppUserStore
    @State private var isGuest: Bool = true
    
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Account")) {
                    if !isGuest {
                        Button("Logout") {
                            Task {
                                await hproseInstance.logout()
                                NotificationCenter.default.post(name: .userDidLogout, object: nil)
                                dismiss()
                            }
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
            .task {
                let user = await appUserStore.getAppUser()
                isGuest = user.isGuest
            }
        }
    }
}

