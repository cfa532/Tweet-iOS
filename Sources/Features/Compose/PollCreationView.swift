import SwiftUI

struct PollCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(LocalizedStringKey("Question"))) {
                    TextField(NSLocalizedString("Ask a question...", comment: "Poll question placeholder"), text: $question)
                }
                
                Section(header: Text(LocalizedStringKey("Options"))) {
                    ForEach(options.indices, id: \.self) { index in
                        TextField(String(format: NSLocalizedString("Option %d", comment: "Poll option placeholder"), index + 1), text: $options[index])
                    }
                    
                    if options.count < 4 {
                        Button(NSLocalizedString("Add Option", comment: "Add poll option button")) {
                            options.append("")
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("Create Poll", comment: "Create poll screen title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(NSLocalizedString("Cancel", comment: "Cancel button")) {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("Add", comment: "Add button")) {
                        // TODO: Implement poll creation
                        dismiss()
                    }
                    .disabled(question.isEmpty || options.contains(""))
                }
            }
        }
    }
} 