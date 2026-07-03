import SwiftUI

struct AuthVerifierView: View {
    @Environment(AuthStore.self) private var auth

    var body: some View {
        Group {
            if let error = auth.verifyError {
                VStack(spacing: 16) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.red)
                    Button("Log Out") { auth.logOut() }
                        .buttonStyle(.bordered)
                }
                .padding()
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Verifying auth…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await auth.verify() }
    }
}
