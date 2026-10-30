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
        return prefix.isEmpty ? found : "\(prefix): \(found)"
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

/// Why a run ended without an answer, as the error card says it: durable's `pi.live.runFailure`, a reason and a
/// detail. Nil for what the user did (Stop, a new context), which needs no card.
enum RunFailureText {
    static func card(reason: String, detail: String?) -> (title: String, text: String)? {
        let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch reason {
        case "aborted", "reset":
            return nil
        case "model_error":
            return ("The model failed", detail.map(ModelErrorText.clean) ?? "The model returned an error.")
        case "no_model":
            return ("No model", (detail ?? "The chat's model is not available") + ". Choose another one in the chat's settings.")
        case "interrupted":
            return ("The answer was cut off", "The server stopped while the model was answering.")
        case "restart_limit":
            return ("The run kept stopping", "The server stopped too many times while it ran.")
        case "turn_limit":
            return ("Turn limit reached", detail.map { "The agent stopped after \($0)." } ?? "The agent stopped after its last turn.")
        case "orphaned":
            let why: String
            switch detail {
            case "missing_task":
                why = "something it needs is not installed"
            case "task_too_old":
                why = "a newer server started it"
            case "migration_failed":
                why = "its saved state could not be read"
            default:
                why = detail ?? "it cannot be run here"
            }
            return ("The run could not go on", "This server cannot run it: \(why).")
        case "faulted":
            return ("Something went wrong", detail ?? "The run hit an error on the server.")
        case "nothing_to_answer":
            return ("Nothing to answer", "The model has answered the last message.")
        default:
            return ("The run stopped", detail ?? "It ended without an answer.")
        }
    }

    /// Whether continuing could give an answer: not when the context ends in one.
    static func canContinue(reason: String) -> Bool {
        return reason != "nothing_to_answer" && reason != "aborted" && reason != "reset"
    }
}

private extension String {
    var nilIfEmpty: String? {
        return self.isEmpty ? nil : self
    }
}
