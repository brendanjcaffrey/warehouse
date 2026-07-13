import SwiftUI

/// shows what the relay is actually doing: whether the phone is in range, how
/// long since anything last landed, and a running feed of every request &
/// arrival. a sync can go minutes between files, so without this the progress
/// view is indistinguishable from a dead one
struct WatchSyncDetailView: View {
    @Environment(SyncStore.self) private var sync
    @Environment(SyncActivityLog.self) private var activity

    @State private var storage: StorageSummary?

    var body: some View {
        // one timeline for the whole list, so the heartbeat & the feed's
        // relative times tick together without a timer per row
        TimelineView(.periodic(from: .now, by: 1)) { context in
            List {
                phoneSection(now: context.date)
                storageSection
                activitySection(now: context.date)
            }
        }
        .navigationTitle("Sync")
        .task(id: [sync.completedSyncs, sync.downloadRefreshTicks]) {
            // rescan after syncs and periodically while files download
            let stats = await Task.detached(priority: .utility) { [sync] in
                sync.downloadStats()
            }.value
            storage = StorageSummary(stats: stats, storage: FileStore.deviceStorage())
        }
    }

    @ViewBuilder
    private func phoneSection(now: Date) -> some View {
        Section("iPhone") {
            let status = activity.status(now: now)
            Label {
                Text(status.isPhoneReachable ? "Reachable" : "Not reachable")
            } icon: {
                Image(systemName: status.isPhoneReachable
                    ? "iphone.radiowaves.left.and.right"
                    : "iphone.slash")
                    .foregroundStyle(status.isPhoneReachable ? .green : .orange)
            }
            if let heartbeat = SyncActivityFormatting.heartbeat(status) {
                Text(heartbeat)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        Section("On This Watch") {
            if let storage {
                LabeledContent("Tracks", value: storage.trackCount.formatted())
                LabeledContent("Artwork", value: storage.artworkCount.formatted())
                LabeledContent("Size", value: storage.usedText)
                if let freeText = storage.freeText {
                    LabeledContent("Free", value: freeText)
                }
            } else {
                HStack {
                    Text("Calculating…")
                    Spacer()
                    ProgressView()
                }
            }
        }
    }

    @ViewBuilder
    private func activitySection(now: Date) -> some View {
        Section("Activity") {
            if activity.events.isEmpty {
                Text("Nothing yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(activity.events) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Label(event.kind.message, systemImage: event.kind.symbol)
                        .font(.footnote)
                        .foregroundStyle(color(for: event.kind.tone))
                    Text("\(SyncActivityFormatting.elapsed(now.timeIntervalSince(event.at))) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func color(for tone: SyncActivityEvent.Tone) -> Color {
        switch tone {
        case .normal: return .primary
        case .good: return .green
        case .warning: return .orange
        case .bad: return .red
        }
    }
}
