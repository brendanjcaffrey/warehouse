import SwiftUI

struct RootView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(UpdatesStore.self) private var updates

    var body: some View {
        Group {
            switch auth.phase {
            case .unauthenticated:
                AuthFormView()
            case .verifying:
                AuthVerifierView()
            case .authenticated:
                MainTabView()
            }
        }
        .task(id: auth.token) {
            // tell the updates store where to send queued plays & edits
            updates.configure(token: auth.token, baseURL: auth.baseURL())
            await updates.flush()
        }
    }
}
