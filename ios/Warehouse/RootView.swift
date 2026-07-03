import SwiftUI

struct RootView: View {
    @Environment(AuthStore.self) private var auth

    var body: some View {
        switch auth.phase {
        case .unauthenticated:
            AuthFormView()
        case .verifying:
            AuthVerifierView()
        case .authenticated:
            MainTabView()
        }
    }
}
