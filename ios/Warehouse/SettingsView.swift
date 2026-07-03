import SwiftUI

struct SettingsView: View {
    @Environment(AuthStore.self) private var auth

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("URL", value: auth.serverURL)
                }

                Section {
                    Button(role: .destructive) {
                        auth.logOut()
                    } label: {
                        Label {
                            Text("Log Out")
                        } icon: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
