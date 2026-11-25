import Foundation

// A server's address as typed, and as the app connects to it. Pure, so TauTests compiles it in.

/// The address a field holds, as the app connects to it, or nil when it is none:
/// - no scheme (`my-mac.example.ts.net`): `ws://` and tau's port, 7878, unless it says one;
/// - a scheme: its own default port unless it says one, `ws://` 80 and `wss://` 443 (a TLS reverse proxy);
/// - `https://` and `http://`, as a browser's address bar has them: `wss://` and `ws://`.
func normalizedServerAddress(_ text: String) -> String? {
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
        return nil
    }
    let hasScheme = text.contains("://")
    if !hasScheme {
        text = "ws://" + text
    }
    guard var components = URLComponents(string: text), var scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty else {
        return nil
    }
    switch scheme {
    case "https":
        scheme = "wss"
    case "http":
        scheme = "ws"
    case "ws", "wss":
        break
    default:
        return nil
    }
    components.scheme = scheme
    if components.port == nil && !hasScheme {
        components.port = 7878
    }
    // A pasted page's trailing slash says nothing.
    if components.path == "/" {
        components.path = ""
    }
    return components.string
}

/// The address as a server's page shows it: without `ws://` where that loses nothing (it has a port, as one typed
/// without a scheme gets), whole otherwise, so a `ws://` on port 80 is not mistaken for tau's port.
func displayedServerAddress(_ address: String) -> String {
    guard address.hasPrefix("ws://"), let components = URLComponents(string: address), components.port != nil else {
        return address
    }
    return String(address.dropFirst("ws://".count))
}
