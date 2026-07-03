import Foundation

/// A `URLProtocol` that intercepts every request on a session it's registered
/// with and answers from a test-supplied handler instead of hitting the network.
///
/// Usage:
/// ```swift
/// MockURLProtocol.requestHandler = { request in
///     (HTTPURLResponse(...), someData)
/// }
/// let session = MockURLProtocol.makeSession()
/// ```
/// The handler may also `throw` to simulate a transport failure (e.g. offline).
final class MockURLProtocol: URLProtocol {
    /// Produces the response for a given request, or throws to fail it.
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Requests seen since the last `reset()`, in order — lets tests assert on
    /// method, headers, URL, and body. Bodies are normalized so the stream that
    /// URLSession substitutes for `httpBody` is still readable here.
    private(set) static var requests: [URLRequest] = []

    static func reset() {
        requestHandler = nil
        requests = []
    }

    /// Handlers keyed by URL host, so suites that give each test a unique host
    /// can run in parallel without racing on the shared `requestHandler`.
    private static var hostHandlers: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]
    private static var hostRequests: [String: [URLRequest]] = [:]
    private static let lock = NSLock()

    static func setHandler(forHost host: String, _ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        defer { lock.unlock() }
        hostHandlers[host] = handler
        hostRequests[host] = []
    }

    static func requests(forHost host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return hostRequests[host] ?? []
    }

    private static func handler(forHost host: String?) -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        guard let host else { return nil }
        return hostHandlers[host]
    }

    private static func record(_ request: URLRequest, forHost host: String) {
        lock.lock()
        defer { lock.unlock() }
        hostRequests[host, default: []].append(request)
    }

    /// A session that routes all traffic through this protocol.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler: (URLRequest) throws -> (HTTPURLResponse, Data)
        if let host = request.url?.host, let hostHandler = Self.handler(forHost: host) {
            Self.record(Self.normalized(request), forHost: host)
            handler = hostHandler
        } else if let globalHandler = MockURLProtocol.requestHandler {
            MockURLProtocol.requests.append(Self.normalized(request))
            handler = globalHandler
        } else {
            MockURLProtocol.requests.append(Self.normalized(request))
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession moves a request's `httpBody` into `httpBodyStream` before it
    /// reaches the protocol, so recover the bytes and stash them back on
    /// `httpBody` so tests can read them directly.
    private static func normalized(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }

        var mutable = request
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }

        mutable.httpBody = data
        return mutable
    }
}
