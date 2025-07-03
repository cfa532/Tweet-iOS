import SwiftUI

struct PollCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(LocalizedStringKey("Question"))) {
                    TextField("Ask a question...", text: $question)
                }
                
                Section(header: Text(LocalizedStringKey("Options"))) {
                    ForEach(options.indices, id: \.self) { index in
                        TextField("Option \(index + 1)", text: $options[index])
                    }
                    
                    if options.count < 4 {
                        Button("Add Option") {
                            options.append("")
                        }
                    }
                }
            }
            .navigationTitle("Create Poll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        // TODO: Implement poll creation
                        dismiss()
                    }
                    .disabled(question.isEmpty || options.contains(""))
                }
            }
        }
    }
} 