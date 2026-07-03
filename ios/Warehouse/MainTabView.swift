import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
    }
}
