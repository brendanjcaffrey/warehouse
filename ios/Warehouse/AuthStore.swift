import Foundation
import Observation

@MainActor
@Observable
final class AuthStore {
    enum Phase {
        case unauthenticated
        case verifying
        case authenticated
    }

    private(set) var token: String?
    private(set) var verified = false
    private(set) var verifyError: String?
    var serverURL: String

    private let client: AuthClient

    private static let serverURLKey = "serverURL"

    // the parameter is here for tests
    init(session: URLSession = .shared) {
        client = AuthClient(session: session)
        if UITestSupport.enabled {
            // ui tests skip the login flow & run offline against fixtures
            token = "ui-tests"
            verified = true
            serverURL = ""
            return
        }
        token = Keychain.readToken()
        serverURL = UserDefaults.standard.string(forKey: Self.serverURLKey) ?? ""
    }

    var phase: Phase {
        if token == nil { return .unauthenticated }
        return verified ? .authenticated : .verifying
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

    func verify() async {
        guard let token else { return }

        verifyError = nil

        guard let baseURL = baseURL() else {
            logOut()
            return
        }

        do {
            switch try await client.verify(token: token, baseURL: baseURL) {
            case .token(let refreshed):
                setToken(refreshed)
                verified = true
            case .error, .empty:
                logOut()
            }
        } catch let error as URLError where error.isOfflineError {
            verified = true
        } catch {
            verifyError = "An error occurred while trying to verify authentication."
        }
    }

    func logOut() {
        setToken(nil)
        verified = false
        verifyError = nil
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
