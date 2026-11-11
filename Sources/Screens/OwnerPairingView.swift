//
//  OwnerPairingView.swift
//  Tweet
//
//  Signs in the owner of a node. Someone with access to the node's machine runs
//  `tweet-owner.sh` there, which prints an identity as a QR code and writes it to
//  a file. This screen takes either one — or the pasted text — and pairs the
//  device with the node. No username or password is involved.
//

import SwiftUI
import UniformTypeIdentifiers

@available(iOS 16.0, *)
struct OwnerPairingView: View {
    /// Called once the device is paired and the owner is signed in.
    let onPaired: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hproseInstance: HproseInstance
    @State private var isPairing = false
    @State private var errorMessage: String?
    @State private var showFileImporter = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text(LocalizedStringKey("On your node, run tweet-owner.sh with a username. Then scan the code it shows."))
                    .font(.subheadline)
                    .foregroundColor(.themeSecondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                ZStack {
                    CodeScanner(isActive: !isPairing && !showFileImporter) { text in
                        pair(with: Data(text.utf8))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    if isPairing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                HStack(spacing: 12) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label(LocalizedStringKey("Import identity file"), systemImage: "doc")
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        if let text = UIPasteboard.general.string {
                            pair(with: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
                        } else {
                            errorMessage = NSLocalizedString("Nothing to paste.", comment: "Owner pairing error")
                        }
                    } label: {
                        Label(LocalizedStringKey("Paste"), systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isPairing)
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .navigationTitle(LocalizedStringKey("Pair with my node"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button(LocalizedStringKey("Close")) { dismiss() })
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json, .plainText, .data]) { result in
                guard case .success(let url) = result else { return }
                // A file picked outside the app's container is readable only inside
                // a security scope.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    errorMessage = NSLocalizedString("That file could not be read.", comment: "Owner pairing error")
                    return
                }
                pair(with: data)
            }
        }
    }

    private func pair(with identity: Data) {
        guard !isPairing else { return }
        isPairing = true
        errorMessage = nil
        Task {
            do {
                try await hproseInstance.pairOwner(identityData: identity)
                NotificationCenter.default.post(name: .userDidLogin, object: nil)
                onPaired()
            } catch {
                errorMessage = error.localizedDescription
            }
            isPairing = false
        }
    }
}
