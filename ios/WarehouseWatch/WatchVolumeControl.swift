import SwiftUI
import WatchKit

/// swiftui has no volume view on watchos & system volume can't be set
/// programmatically, so wrap watchkit's control — focus() is what points the
/// digital crown at it instead of at whatever else would take crown input
struct WatchVolumeControl: WKInterfaceObjectRepresentable {
    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: .local)
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        control.focus()
    }
}
