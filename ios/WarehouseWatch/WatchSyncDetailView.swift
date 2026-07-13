import SwiftUI

/// shows what the bundle downloader is actually doing: how long since
/// anything last landed, and a running feed of every request, bundle &
/// arrival. an overnight sync can go a while between bundles, so without
/// this the progress view is indistinguishable from a dead one
struct WatchSyncDetailView: View {
    @Environment(SyncStore.self) private var sync
    @Environment(SyncActivityLog.self) private var activity

    @State private var storage: StorageSummary?

    var body: some View {
        // one timeline for the whole list, so the heartbeat & the feed's
        // relative times tick together without a timer per row
        TimelineView(.periodic(from: .now, by: 1)) { context in
            List {
                syncSection(now: context.date)
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
    private func syncSection(now: Date) -> some View {
        let status = activity.status(now: now)
        if let heartbeat = SyncActivityFormatting.heartbeat(status) {
            Section("Sync") {
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
