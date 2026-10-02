import SwiftUI

struct PairingSheet: View {
    @EnvironmentObject private var store: ConsoleStore
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selection: DiscoveredConsole.ID?
    @State private var code = ""
    @State private var working = false
    @State private var failure: String?
    @State private var signingIn = false

    private var target: DiscoveredConsole? {
        store.discovered.first { $0.id == selection } ?? store.discovered.first
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if prefs.accountID == nil {
                        LabeledContent("PlayStation Network") {
                            Button("Sign In…") { signingIn = true }
                        }
                    } else {
                        LabeledContent("PlayStation Network", value: "Signed In")
                    }
                } footer: {
                    Text("Your account is only used to identify you to the console.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    if store.discovered.isEmpty {
                        LabeledContent("Console") {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Looking for consoles…").foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Picker("Console", selection: Binding(get: { target?.id }, set: { selection = $0 })) {
                            ForEach(store.discovered) { console in
                                Text(console.name).tag(Optional(console.id))
                            }
                        }
                    }
                    TextField("Code", text: $code, prompt: Text("8 digits"))
                        .onChange(of: code) { _, value in
                            code = String(value.filter(\.isNumber).prefix(8))
                        }
                } footer: {
                    Text("On the console, open Settings > System > Remote Play > Link Device and enter the code it shows.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) {
                    store.cancelPairing()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Pair") { pair() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || target == nil || code.count != 8 || prefs.accountID == nil)
            }
            .padding()
        }
        .frame(width: 440)
        .sheet(isPresented: $signingIn) {
            SignInSheet()
        }
    }

    private func pair() {
        guard let target else { return }
        working = true
        failure = nil
        store.pair(target, pin: code) { error in
            working = false
            if let error {
                failure = error
            } else {
                dismiss()
            }
        }
    }
}
