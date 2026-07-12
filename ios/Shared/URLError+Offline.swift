import Foundation

extension URLError {
    /// true when the error indicates we couldn't reach the server at all
    var isOfflineError: Bool {
        switch code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .timedOut,
             .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}
