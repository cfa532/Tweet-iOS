import SwiftUI

struct ReportTweetView: View {
    @ObservedObject var tweet: Tweet
    @Environment(\.dismiss) private var dismiss
    @StateObject private var appUser = HproseInstance.shared.appUser
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    @State private var isSubmitting = false
    
    // Report categories
    @State private var selectedCategory: ReportCategory? = nil
    @State private var additionalComments = ""
    
    enum ReportCategory: String, CaseIterable {
        case spam = "Spam"
        case harassment = "Harassment or bullying"
        case hateContent = "Hate speech or discrimination"
        case violence = "Violence or threats"
        case adultContent = "Adult or sexual content"
        case misinformation = "Misinformation"
        case copyright = "Copyright violation"
        case other = "Other"
        
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .spam:
                return "Spam"
            case .harassment:
                return "Harassment or bullying"
            case .hateContent:
                return "Hate speech or discrimination"
            case .violence:
                return "Violence or threats"
            case .adultContent:
                return "Adult or sexual content"
            case .misinformation:
                return "Misinformation"
            case .copyright:
                return "Copyright violation"
            case .other:
                return "Other"
            }
        }
        
        var systemImage: String {
            switch self {
            case .spam:
                return "envelope.badge.fill"
            case .harassment:
                return "person.crop.circle.badge.exclamationmark"
            case .hateContent:
                return "hand.raised.fill"
            case .violence:
                return "exclamationmark.triangle.fill"
            case .adultContent:
                return "eye.slash.fill"
            case .misinformation:
                return "info.circle.fill"
            case .copyright:
                return "c.circle.fill"
            case .other:
                return "ellipsis.circle.fill"
            }
        }
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringKey("Report Tweet"))
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text(LocalizedStringKey("Help us maintain a safe community by reporting inappropriate content"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    
                    // Tweet preview
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringKey("Reported Tweet"))
                            .font(.headline)
                            .padding(.horizontal)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(tweet.author?.name ?? "Unknown User")
                                    .font(.headline)
                                Spacer()
                                Text("@\(tweet.author?.username ?? "unknown")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Text(tweet.content ?? "")
                                .font(.body)
                                .lineLimit(3)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }
                    
                    // Report categories
                    VStack(alignment: .leading, spacing: 16) {
                        Text(LocalizedStringKey("Why are you reporting this tweet?"))
                            .font(.headline)
                            .padding(.horizontal)
                        
                        LazyVStack(spacing: 0) {
                            ForEach(ReportCategory.allCases, id: \.self) { category in
                                Button(action: {
                                    selectedCategory = category
                                }) {
                                    HStack {
                                        Image(systemName: category.systemImage)
                                            .foregroundColor(selectedCategory == category ? .blue : .secondary)
                                            .frame(width: 24)
                                        
                                        Text(category.localizedTitle)
                                            .foregroundColor(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        
                                        if selectedCategory == category {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.blue)
                                        }
                                    }
                                    .padding()
                                    .background(selectedCategory == category ? Color.blue.opacity(0.1) : Color(.systemGray6))
                                }
                                .buttonStyle(PlainButtonStyle())
                                
                                if category != ReportCategory.allCases.last {
                                    Divider()
                                        .padding(.leading, 56)
                                }
                            }
                        }
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }
                    
                    // Additional comments
                    VStack(alignment: .leading, spacing: 12) {
                        Text(LocalizedStringKey("Additional Comments (Optional)"))
                            .font(.headline)
                            .padding(.horizontal)
                        
                        TextField(LocalizedStringKey("Provide additional details about this report"), text: $additionalComments, axis: .vertical)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .lineLimit(3...6)
                            .padding(.horizontal)
                    }
                    
                    // Information section
                    VStack(alignment: .leading, spacing: 12) {
                        Text(LocalizedStringKey("What happens next?"))
                            .font(.headline)
                            .padding(.horizontal)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Label(LocalizedStringKey("Our team will review your report within 24 hours"), systemImage: "clock")
                            Label(LocalizedStringKey("The content may be removed if it violates our guidelines"), systemImage: "trash")
                            Label(LocalizedStringKey("You'll receive a notification about the outcome"), systemImage: "bell")
                            Label(LocalizedStringKey("False reports may result in account restrictions"), systemImage: "exclamationmark.triangle")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button(LocalizedStringKey("Cancel")) {
                    dismiss()
                },
                trailing: Button(LocalizedStringKey("Submit Report")) {
                    submitReport()
                }
                .fontWeight(.semibold)
                .disabled(selectedCategory == nil || isSubmitting)
            )
        }
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
    }
    
    private func submitReport() {
        guard let category = selectedCategory else { return }
        
        isSubmitting = true
        
        Task {
            do {
                // Submit the report to backend
                try await hproseInstance.reportTweet(
                    tweetId: tweet.mid,
                    category: category.rawValue,
                    comments: additionalComments
                )
                
                await MainActor.run {
                    // After successful report submission, delete the tweet from the list
                    NotificationCenter.default.post(
                        name: .tweetDeleted,
                        object: nil,
                        userInfo: ["tweetId": tweet.mid]
                    )
                    print("[ReportTweetView] Posted notification to remove reported tweet: \(tweet.mid)")
                    
                    toastMessage = NSLocalizedString("Report submitted successfully. Thank you for helping keep our community safe.", comment: "Report success")
                    toastType = .success
                    showToast = true
                    isSubmitting = false
                }
                
                // Dismiss after showing success message
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    dismiss()
                }
                
            } catch {
                await MainActor.run {
                    toastMessage = NSLocalizedString("Failed to submit report. Please try again.", comment: "Report error")
                    toastType = .error
                    showToast = true
                    isSubmitting = false
                }
            }
        }
    }
}
