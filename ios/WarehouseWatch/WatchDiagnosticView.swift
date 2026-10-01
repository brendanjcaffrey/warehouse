import SwiftUI
import WatchKit

extension EnvironmentValues {
    @Entry var diagnosticSender: WatchPhoneSession?
}

struct WatchDiagnosticView: View {
    @Environment(\.diagnosticSender) private var sender
    @State private var report: WatchDiagnosticReport?
    @State private var sending = false
    @State private var result: String?
    @State private var confirmingClear = false

    var body: some View {
        List {
            if let report {
                LabeledContent("Events", value: report.count.formatted())
                LabeledContent("Phone accepted", value: report.count(.phoneAccepted).formatted())
                LabeledContent("Phone delivered", value: report.count(.phoneDelivered).formatted())
                LabeledContent("Phone failed", value: report.count(.phoneFailed).formatted())
                LabeledContent("Playback started", value: report.count(.playbackStarted).formatted())
                LabeledContent("Stalls", value: report.count(.playbackStalled).formatted())
            }
            Button("Refresh") { refresh() }
            Button(sending ? "Sending…" : "Send to iPhone") { send() }
                .disabled(sending || report?.events.isEmpty != false)
            if let result { Text(result).font(.footnote) }
            Button("Start New Capture", role: .destructive) {
                confirmingClear = true
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear { refresh() }
        .confirmationDialog("Clear current capture?", isPresented: $confirmingClear) {
            Button("Start New Capture", role: .destructive) {
                WatchDiagnostics.shared.clear()
                result = nil
                refresh()
            }
        } message: {
            Text("Send this report to your iPhone first if you want to keep it.")
        }
    }

    private func refresh() {
        let device = WKInterfaceDevice.current()
        report = WatchDiagnostics.shared.report(deviceModel: device.model, systemVersion: device.systemVersion)
    }

    private func send() {
        refresh()
        guard let report, !report.events.isEmpty else { return }
        sending = true
        result = nil
        sender?.sendDiagnostics(report) { saved in
            sending = false
            result = saved ? "Saved on iPhone. Open Settings → Apple Watch to share."
                           : "Couldn’t send. The capture remains here; try again near your iPhone."
        }
        if sender == nil {
            sending = false
            result = "iPhone connection unavailable. Try again later."
        }
    }
}
