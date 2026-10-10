import Foundation
import CFNetwork
import SystemConfiguration

nonisolated struct SystemProxyInfo: Equatable, Sendable {
    var server: String
    var bypass: String
    var isSocks: Bool
}

nonisolated enum SystemProxyDetector {
    static func detect() -> SystemProxyInfo? {
        guard let proxyDictionary = SCDynamicStoreCopyProxies(nil) as NSDictionary? else {
            return nil
        }
        var rawDictionary: [String: Any] = [:]
        for (key, value) in proxyDictionary {
            guard let key = key as? String else { continue }
            rawDictionary[key] = value
        }
        return proxyInfo(from: rawDictionary)
    }

    static func proxyInfo(from dictionary: [String: Any]) -> SystemProxyInfo? {
        if boolValue(dictionary, key: kSCPropNetProxiesHTTPEnable) {
            if let info = buildProxyInfo(
                dictionary,
                hostKey: kSCPropNetProxiesHTTPProxy,
                portKey: kSCPropNetProxiesHTTPPort,
                scheme: "http",
                isSocks: false
            ) {
                return info
            }
        }

        if boolValue(dictionary, key: kSCPropNetProxiesHTTPSEnable) {
            if let info = buildProxyInfo(
                dictionary,
                hostKey: kSCPropNetProxiesHTTPSProxy,
                portKey: kSCPropNetProxiesHTTPSPort,
                scheme: "http",
                isSocks: false
            ) {
                return info
            }
        }

        if boolValue(dictionary, key: kSCPropNetProxiesSOCKSEnable) {
            if let info = buildProxyInfo(
                dictionary,
                hostKey: kSCPropNetProxiesSOCKSProxy,
                portKey: kSCPropNetProxiesSOCKSPort,
                scheme: "socks5",
                isSocks: true
            ) {
                return info
            }
        }

        return nil
    }

    private static func buildProxyInfo(
        _ dictionary: [String: Any],
        hostKey: CFString,
        portKey: CFString,
        scheme: String,
        isSocks: Bool
    ) -> SystemProxyInfo? {
        guard let host = stringValue(dictionary, key: hostKey), !host.isEmpty else { return nil }
        guard let port = intValue(dictionary, key: portKey), (1...65_535).contains(port) else { return nil }
        return SystemProxyInfo(
            server: "\(scheme)://\(host):\(port)",
            bypass: bypassList(from: dictionary),
            isSocks: isSocks
        )
    }

    private static func bypassList(from dictionary: [String: Any]) -> String {
        var entries: [String] = []
        if let exceptions = dictionary[kSCPropNetProxiesExceptionsList as String] as? [String] {
            for exception in exceptions {
                let trimmed = exception.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !entries.contains(trimmed) {
                    entries.append(trimmed)
                }
            }
        }

        if boolValue(dictionary, key: kSCPropNetProxiesExcludeSimpleHostnames),
           !entries.contains("<local>") {
            entries.append("<local>")
        }
        return entries.joined(separator: ",")
    }

    private static func boolValue(_ dictionary: [String: Any], key: CFString) -> Bool {
        intValue(dictionary, key: key) == 1
    }

    private static func intValue(_ dictionary: [String: Any], key: CFString) -> Int? {
        if let value = dictionary[key as String] as? Int {
            return value
        }
        if let value = dictionary[key as String] as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private static func stringValue(_ dictionary: [String: Any], key: CFString) -> String? {
        (dictionary[key as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
