import Foundation
import CryptoKit

/// AWS Signature V4 query-string presigning for one object (S3, Cloudflare R2, MinIO ...).
public enum SigV4 {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    static func encode(_ s: String, keepSlash: Bool = false) -> String {
        var allowed = unreserved
        if keepSlash { allowed.insert("/") }
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func hmac(_ key: Data, _ msg: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
    }

    private static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 {
        d.map { String(format: "%02x", $0) }.joined()
    }

    public static func presign(method: String, host: String, path: String, accessKey: String, secretKey: String,
                               region: String, expires: Int = 900, now: Date = Date(),
                               service: String = "s3") throws -> String {
        guard path.hasPrefix("/") else { throw IGPubError("path must start with /") }
        guard (1...604_800).contains(expires) else { throw IGPubError("expires must be 1..604800") }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = fmt.string(from: now)
        let stamp = String(amzDate.prefix(8))
        let scope = "\(stamp)/\(region)/\(service)/aws4_request"
        let params: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(accessKey)/\(scope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expires)),
            ("X-Amz-SignedHeaders", "host"),
        ]
        let query = params.sorted { $0.0 < $1.0 }.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        let uri = encode(path, keepSlash: true)
        let canonical = [method, uri, query, "host:\(host)\n", "host", "UNSIGNED-PAYLOAD"].joined(separator: "\n")
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope,
                      hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        var key = hmac(Data("AWS4\(secretKey)".utf8), stamp)
        for part in [region, service, "aws4_request"] { key = hmac(key, part) }
        let signature = hex(hmac(key, toSign))
        return "https://\(host)\(uri)?\(query)&X-Amz-Signature=\(signature)"
    }
}
