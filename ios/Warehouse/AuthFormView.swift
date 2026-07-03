import SwiftUI

struct AuthFormView: View {
    @Environment(AuthStore.self) private var auth

    @State private var username = ""
    @State private var password = ""
    @State private var serverURL = ""
    @State private var error = ""
    @State private var inflight = false

    @FocusState private var focusedField: Field?

    private enum Field {
        case serverURL, username, password
    }

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                Text("Warehouse")
                    .font(.title2.weight(.medium))

                if !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.red.opacity(0.12), in: .rect(cornerRadius: 8))
                }

                VStack(spacing: 12) {
                    TextField("Server URL", text: $serverURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .serverURL)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .username }

                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(submit)
                }
                .textFieldStyle(.roundedBorder)

                Button(action: submit) {
                    ZStack {
                        Text("Sign In")
                            .opacity(inflight ? 0 : 1)
                        if inflight {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(inflight || !canSubmit)
            }
            .padding(24)
            .frame(maxWidth: 400)
            Spacer()
            Spacer()
        }
        .padding()
        .onAppear { serverURL = auth.serverURL }
    }

    private var canSubmit: Bool {
        !username.isEmpty && !password.isEmpty && !serverURL.isEmpty
    }

    private func submit() {
        guard canSubmit, !inflight else { return }
        focusedField = nil
        inflight = true
        error = ""
        Task {
            let result = await auth.logIn(
                username: username,
                password: password,
                serverURL: serverURL
            )
            if let result {
                error = result
            }
            inflight = false
        }
    }
}
