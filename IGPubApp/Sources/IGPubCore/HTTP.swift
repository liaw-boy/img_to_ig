import Foundation

/// Every network call goes through this protocol so tests can replace it with a fake.
public protocol HTTPClient: Sendable {
    func send(_ method: String, _ url: URL, body: Data?, headers: [String: String]) async throws -> (status: Int, body: Data)
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    // A redirect could leak a signed URL or token elsewhere.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct URLSessionHTTP: HTTPClient {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.httpCookieStorage = nil
        return URLSession(configuration: cfg, delegate: NoRedirect(), delegateQueue: nil)
    }()
    static let maxResponse = 5_000_000

    public init() {}

    public func send(_ method: String, _ url: URL, body: Data?, headers: [String: String]) async throws
        -> (status: Int, body: Data) {
        guard url.scheme?.lowercased() == "https" else { throw IGPubError("只允許 https 網址") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (bytes, resp) = try await Self.session.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if resp.expectedContentLength > Self.maxResponse { bytes.task.cancel(); throw IGPubError("伺服器回應過大") }
        var data = Data()
        for try await b in bytes {
            data.append(b)
            if data.count > Self.maxResponse { bytes.task.cancel(); throw IGPubError("伺服器回應過大") }
        }
        return (status, data)
    }
}

public func redact(_ text: String, _ secrets: String...) -> String {
    var out = text
    for s in secrets where s.count >= 6 { out = out.replacingOccurrences(of: s, with: "***") }
    return out
}
