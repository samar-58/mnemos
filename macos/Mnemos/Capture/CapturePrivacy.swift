import ApplicationServices
import Foundation

enum CapturePrivacy {
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
    ]

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "org.alacritty",
        "net.kovidgoyal.kitty",
    ]

    static func isBrowser(_ bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID)
    }

    static func isTerminal(_ bundleID: String) -> Bool {
        terminalBundleIDs.contains(bundleID)
    }

    static func isPrivateBrowserWindow(_ title: String?) -> Bool {
        guard let title = title?.lowercased() else { return false }
        return title.contains("private browsing")
            || title.contains("incognito")
            || title.contains("private window")
            || title.contains("inprivate")
    }

    static func isSecureElement(
        role: String?,
        subrole: String?,
        title: String?,
        description: String?,
        identifier: String?
    ) -> Bool {
        let attributes = [role, subrole, title, description, identifier]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return attributes.contains("secure")
            || attributes.contains("password")
            || attributes.contains("passcode")
            || attributes.contains("credit card security code")
    }

    static func sanitize(_ value: String?, maximumLength: Int, preserveLines: Bool = false) -> String? {
        guard let value else { return nil }
        var redacted = value
        let patterns: [(String, String)] = [
            (#"(?i)(authorization:\s*bearer\s+)[A-Za-z0-9._~+/=-]+"#, "$1[REDACTED]"),
            (#"(?i)\b(api[_-]?key|secret|token|password)\s*[:=]\s*[^\s,;]+"#, "$1=[REDACTED]"),
            (#"\bsk-[A-Za-z0-9_-]{16,}\b"#, "[REDACTED API KEY]"),
            (#"\bgh[pousr]_[A-Za-z0-9]{16,}\b"#, "[REDACTED GITHUB TOKEN]"),
            (#"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#, "[REDACTED SLACK TOKEN]"),
            (#"\bAKIA[A-Z0-9]{16}\b"#, "[REDACTED AWS KEY]"),
        ]
        for (pattern, replacement) in patterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        if let privateKeyStart = redacted.range(of: "-----BEGIN "),
           redacted[privateKeyStart.lowerBound...].contains("PRIVATE KEY-----") {
            redacted = String(redacted[..<privateKeyStart.lowerBound]) + "[REDACTED PRIVATE KEY]"
        }

        redacted = redacted.replacingOccurrences(of: "\u{0000}", with: "")
        let normalized: String
        if preserveLines {
            normalized = redacted
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } else {
            normalized = redacted
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maximumLength))
    }

    static func normalizedDocumentPath(_ value: String?) -> String? {
        guard let sanitized = sanitize(value, maximumLength: 1_000) else { return nil }
        if let url = URL(string: sanitized), url.isFileURL {
            return url.standardizedFileURL.path
        }
        return sanitized
    }

    static func normalizedDomain(_ value: String) -> String? {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty else { return nil }
        if !candidate.contains("://") { candidate = "https://\(candidate)" }
        guard let host = URL(string: candidate)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func sanitizedBrowserURL(_ value: String?) -> URL? {
        guard var candidate = sanitize(value, maximumLength: 4_000) else { return nil }
        if !candidate.contains("://") { candidate = "https://\(candidate)" }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        components?.user = nil
        components?.password = nil
        return components?.url
    }

    static func isAllowed(_ url: URL, domains: Set<String>) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return domains.contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }
}
