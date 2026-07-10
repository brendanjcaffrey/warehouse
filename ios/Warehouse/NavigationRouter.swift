import SwiftUI

enum AppTab {
    case library
    case settings
    case search
}

/// a destination pushed onto the library tab's navigation stack, so the now
/// playing modal can send the user to a track's artist, album, songs or
/// playlist view on top of whatever the library tab is already showing
enum LibraryRoute: Hashable {
    case artist(Artist)
    case album(Album)
    case songs(Song)
    case playlist(PlaylistDestination)
}

/// shared navigation state: the selected tab & the library tab's stack, so
/// views outside that stack (the now playing sheet) can drive it
@MainActor
@Observable
final class NavigationRouter {
    var selectedTab: AppTab = .library
    var libraryPath = NavigationPath()

    /// switches to the library tab and pushes a destination onto its stack;
    /// callers dismiss any presented sheet themselves afterwards
    func navigate(to route: LibraryRoute) {
        selectedTab = .library
        libraryPath.append(route)
    }
}
