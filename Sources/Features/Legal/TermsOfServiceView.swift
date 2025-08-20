import SwiftUI

struct TermsOfServiceView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var hasAcceptedTerms: Bool
    let onAccept: () -> Void
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringKey("Terms of Service"))
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text("Last updated: \(Date().formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.bottom, 10)
                    
                    // Terms content
                    VStack(alignment: .leading, spacing: 16) {
                        Group {
                            Text("1. Acceptance of Terms")
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            Text("By using this application, you agree to be bound by these Terms of Service. If you do not agree to these terms, please do not use the application.")
                            
                            Text("2. User Conduct and Content Policy")
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            Text("We have a zero-tolerance policy for objectionable content and abusive behavior. Users must not:")
                                .fontWeight(.medium)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("• Post, share, or promote content that is illegal, harmful, threatening, abusive, harassing, defamatory, vulgar, obscene, or otherwise objectionable")
                                Text("• Impersonate others or provide false information")
                                Text("• Engage in cyberbullying, hate speech, or discrimination")
                                Text("• Share private or confidential information without consent")
                                Text("• Use the platform for spam, scams, or fraudulent activities")
                                Text("• Violate intellectual property rights")
                                Text("• Attempt to gain unauthorized access to accounts or systems")
                            }
                            .padding(.leading, 16)
                            
                            Text("3. Content Moderation")
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            Text("We reserve the right to remove any content that violates these terms and to suspend or terminate accounts of users who engage in prohibited behavior. We may also report illegal activities to appropriate authorities.")
                            
                            Text("4. User Responsibilities")
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            Text("You are responsible for all content you post and all activities that occur under your account. You must maintain the security of your account credentials and report any unauthorized use immediately.")
                            
                            Text("5. Privacy and Data")
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            Text("Your privacy is important to us. We collect and process your data in accordance with our Privacy Policy. By using this application, you consent to such processing.")
                            
                            Text("6. Termination")
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            Text("We may terminate or suspend your account at any time for violations of these terms or for any other reason at our sole discretion.")
                            
                            Text("7. Changes to Terms")
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            Text("We may update these terms from time to time. Continued use of the application after changes constitutes acceptance of the new terms.")
                            
                            Text("8. Contact")
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            Text("If you have questions about these terms or need to report violations, please contact us through the app's support channels.")
                        }
                    }
                    
                    Spacer(minLength: 40)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(LocalizedStringKey("Cancel")) {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(LocalizedStringKey("Accept")) {
                        hasAcceptedTerms = true
                        onAccept()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(.blue)
                }
            }
        }
    }
}

#Preview {
    TermsOfServiceView(
        hasAcceptedTerms: .constant(false),
        onAccept: {}
    )
}
