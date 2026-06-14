import Foundation

struct AppEnvironment: Hashable {
    enum Name: String {
        case debug = "Debug"
        case staging = "Staging"
        case production = "Production"
    }

    var name: Name
    var httpAPIBaseURL: String
    var relayBaseURL: String

    static let current = AppEnvironment(bundle: .main)

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        let rawName = Self.stringValue(info["DragonRadarEnvironment"])
        let parsedName = Name(rawValue: rawName) ?? Self.defaultName
        name = parsedName

        let fallback = Self.defaults(for: parsedName)
        let http = Self.stringValue(info["DragonRadarHTTPBaseURL"])
        let relay = Self.stringValue(info["DragonRadarRelayBaseURL"])

        if parsedName == .production {
            httpAPIBaseURL = Self.secureURL(http, allowedScheme: "https") ?? fallback.http
            relayBaseURL = Self.secureURL(relay, allowedScheme: "wss") ?? fallback.relay
        } else {
            httpAPIBaseURL = http.isEmpty ? fallback.http : http
            relayBaseURL = relay.isEmpty ? fallback.relay : relay
        }
    }

    init(name: Name, httpAPIBaseURL: String, relayBaseURL: String) {
        self.name = name
        self.httpAPIBaseURL = httpAPIBaseURL
        self.relayBaseURL = relayBaseURL
    }

    var isProduction: Bool {
        name == .production
    }

    private static var defaultName: Name {
        #if DEBUG
        return .debug
        #else
        return .production
        #endif
    }

    private static func defaults(for name: Name) -> (http: String, relay: String) {
        switch name {
        case .debug:
            return ("http://139.224.41.192:8788", "ws://139.224.41.192:8787")
        case .staging:
            return ("https://staging-relay.dragon-radar.example", "wss://staging-relay.dragon-radar.example")
        case .production:
            return ("https://relay.dragon-radar.example", "wss://relay.dragon-radar.example")
        }
    }

    private static func secureURL(_ value: String, allowedScheme: String) -> String? {
        guard
            let components = URLComponents(string: value),
            components.scheme == allowedScheme,
            components.host?.isEmpty == false
        else {
            return nil
        }
        return value
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
