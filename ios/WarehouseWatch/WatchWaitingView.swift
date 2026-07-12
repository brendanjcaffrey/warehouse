import SwiftUI

struct WatchWaitingView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open Warehouse on your iPhone and pick playlists to sync in Settings.")
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
