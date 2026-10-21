import Foundation

/// Provider errors as people read them. They come as the provider's text, often an HTTP status and a JSON body
/// (`529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}`).
enum ModelErrorText {
    /// The message itself: a JSON body's innermost `message`, with its status before it.
    static func clean(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let brace = text.firstIndex(of: "{"), let data = String(text[brace...]).data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else {
            return text
        }
        func message(_ value: Any) -> String? {
            if let object = value as? [String: Any] {
                if let inner = object["error"], let found = message(inner) {
                    return found
                }
                if let text = object["message"] as? String, !text.isEmpty {
                    return text
                }
            }
            if let text = value as? String, !text.isEmpty {
                return text
            }
            return nil
        }
        guard let found = message(json) else {
            return text
        }
        let prefix = text[..<brace].trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? found : "\(prefix) · \(found)"
    }

    private static let kinds: [(pattern: String, reason: String)] = [
        ("overloaded|at capacity|high demand|server_busy|servers are currently busy", "overloaded"),
        ("rate.?limit|too many requests|\\b429\\b|resourceexhausted", "rate limited"),
        ("timed? ?out|timeout", "timed out"),
        ("network|connection|socket|fetch failed|econn|enotfound|eai_again|getaddrinfo|other side closed|websocket|terminated|stream (was interrupted|ended)|ended without", "connection lost"),
        ("\\b5\\d\\d\\b|server.?error|internal.?error|unavailable|upstream|provider returned", "server error"),
    ]

    /// A few words for a status line: what kind of error, or the start of the message.
    static func reason(_ raw: String) -> String {
        let lowered = raw.lowercased()
        for kind in self.kinds where lowered.range(of: kind.pattern, options: .regularExpression) != nil {
            return kind.reason
        }
        let cleaned = self.clean(raw)
        return cleaned.count > 40 ? String(cleaned.prefix(39)) + "…" : cleaned
    }
}
