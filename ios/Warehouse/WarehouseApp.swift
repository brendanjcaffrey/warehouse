import SwiftUI

@main
struct WarehouseApp: App {
    @State private var auth = AuthStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
        }
    }
}
