import Foundation
import Observation

@MainActor
@Observable
final class AuthStore {
    enum Phase {
        case unauthenticated
        case authenticated
    }

    private(set) var token: String?
    var serverURL: String

    private let client: AuthClient

    private static let serverURLKey = "serverURL"

    // the parameter is here for tests
    init(session: URLSession = .shared) {
        client = AuthClient(session: session)
        if UITestSupport.enabled {
            // ui tests skip the login flow & run offline against fixtures
            token = "ui-tests"
            serverURL = ""
            return
        }
        serverURL = UserDefaults.standard.string(forKey: Self.serverURLKey) ?? ""

        // a stored token is trusted on sight so the app opens without waiting on the
        // network. a token we can't use is dropped here, still without a request: it's
        // expired, or it outlived the server url (the keychain survives a reinstall,
        // user defaults doesn't) & only the login form can set that back
        if let stored = Keychain.readToken() {
            if JWT.isExpired(stored) || baseURL() == nil {
                Keychain.setToken(nil)
            } else {
                token = stored
            }
        }
    }

    var phase: Phase {
        token == nil ? .unauthenticated : .authenticated
    }

    func logIn(username: String, password: String, serverURL: String) async -> String? {
        setServerURL(serverURL)

        guard let baseURL = baseURL() else {
            return "Please enter a valid server URL."
        }

        do {
            switch try await client.logIn(username: username, password: password, baseURL: baseURL) {
            case .token(let token):
                setToken(token)
                return nil
            case .error(let error):
                return error
            case .empty:
                return "An error occurred while trying to authenticate. Please try again."
            }
        } catch {
            return "An error occurred while trying to authenticate. Please try again."
        }
    }

    /// refreshes the stored token in the background. this never gates the ui: the only
    /// thing it can do is end the session, & only when the server explicitly rejects us
    func refresh() async {
        guard let token, let baseURL = baseURL() else { return }

        do {
            switch try await client.verify(token: token, baseURL: baseURL) {
            case .token(let refreshed):
                setToken(refreshed)
            case .error:
                logOut()
            case .empty:
                // an answer we can't read, leave the session alone
                break
            }
        } catch {
            // couldn't reach the server. the local library still works, stay logged in
        }
    }

    func logOut() {
        setToken(nil)
    }

    private func setToken(_ token: String?) {
        self.token = token
        Keychain.setToken(token)
    }

    private func setServerURL(_ url: String) {
        serverURL = url
        UserDefaults.standard.set(url, forKey: Self.serverURLKey)
    }

    func baseURL() -> URL? {
        var trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), url.host != nil else { return nil }
        return url
    }
}
