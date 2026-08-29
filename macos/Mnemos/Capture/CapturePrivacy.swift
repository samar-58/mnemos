import ApplicationServices
import Foundation

enum CapturePrivacy {
    /// v3 widened the secret-keyword rule to match keywords inside longer
    /// identifiers. Rows still stamped v2 were captured under the narrower rule.
    private static let minimumRedactionPolicyVersion = 3
    private static let redactionPolicyVersionDefaultsKey = "redactionPolicyVersion"
    static var redactionPolicyVersion: Int {
        max(minimumRedactionPolicyVersion, UserDefaults.standard.integer(forKey: redactionPolicyVersionDefaultsKey))
    }
    static let customLiteralDefaultsKey = "redactionCustomLiterals"
    static let customRegexDefaultsKey = "redactionCustomRegexes"
    static let maximumCustomRules = 20

    @discardableResult
    static func advanceRedactionPolicyVersion() -> Int {
        let next = redactionPolicyVersion + 1
        UserDefaults.standard.set(next, forKey: redactionPolicyVersionDefaultsKey)
        return next
    }

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
            // The keyword may sit inside a longer identifier, as it does in
            // every shell export: AWS_SECRET_ACCESS_KEY, DB_PASSWORD, and so
            // on. Anchoring on \b(secret) alone missed all of them, because an
            // underscore is a word character.
            (
                #"(?i)\b([A-Za-z0-9_.-]*(?:api[_-]?key|secret|token|password|passwd|credential)[A-Za-z0-9_.-]*)\s*[:=]\s*[^\s,;]+"#,
                "$1=[REDACTED]"
            ),
            (#"\bsk-[A-Za-z0-9_-]{16,}\b"#, "[REDACTED API KEY]"),
            (#"\bgh[pousr]_[A-Za-z0-9]{16,}\b"#, "[REDACTED GITHUB TOKEN]"),
            (#"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#, "[REDACTED SLACK TOKEN]"),
            (#"\bAKIA[A-Z0-9]{16}\b"#, "[REDACTED AWS KEY]"),
            (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, "[REDACTED JWT]"),
            (#"(?i)\b([a-z][a-z0-9+.-]*://)[^\s/@:]+:[^\s/@]+@"#, "$1[REDACTED]@"),
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

        let defaults = UserDefaults.standard
        for literal in defaults.stringArray(forKey: customLiteralDefaultsKey)?.prefix(maximumCustomRules) ?? [] {
            guard !literal.isEmpty else { continue }
            redacted = redacted.replacingOccurrences(
                of: literal,
                with: "[REDACTED CUSTOM]",
                options: [.caseInsensitive, .literal]
            )
        }
        for pattern in defaults.stringArray(forKey: customRegexDefaultsKey)?.prefix(maximumCustomRules) ?? [] {
            guard validateCustomRegex(pattern) == nil else { continue }
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "[REDACTED CUSTOM]",
                options: .regularExpression
            )
        }

        redacted = String(redacted.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        })
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

    static func validateCustomRegex(_ pattern: String) -> String? {
        guard !pattern.isEmpty else { return "The pattern cannot be empty." }
        guard pattern.count <= 256 else { return "Patterns are limited to 256 characters." }
        let unsupported = ["(?<=", "(?<!", "*", "+"]
        if unsupported.contains(where: pattern.contains) {
            return "Use bounded quantifiers such as {1,64}; look-behind and unbounded quantifiers are not allowed."
        }
        if pattern.range(of: #"\{[0-9]+,\}"#, options: .regularExpression) != nil {
            return "Unbounded quantifiers are not allowed; provide an upper bound such as {1,64}."
        }
        if pattern.range(of: #"\\[1-9]"#, options: .regularExpression) != nil {
            return "Backreferences are not allowed."
        }
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return "The regular expression is invalid."
        }
    }

    static func redactionCategoryCounts(in values: [String?]) -> [String: Int] {
        let markers = [
            "api_key": "[REDACTED API KEY]",
            "github_token": "[REDACTED GITHUB TOKEN]",
            "slack_token": "[REDACTED SLACK TOKEN]",
            "aws_key": "[REDACTED AWS KEY]",
            "jwt": "[REDACTED JWT]",
            "private_key": "[REDACTED PRIVATE KEY]",
            "custom": "[REDACTED CUSTOM]",
            "credential": "[REDACTED]",
        ]
        var counts: [String: Int] = [:]
        for value in values.compactMap({ $0 }) {
            for (category, marker) in markers {
                var search = value.startIndex..<value.endIndex
                while let range = value.range(of: marker, range: search) {
                    counts[category, default: 0] += 1
                    search = range.upperBound..<value.endIndex
                }
            }
        }
        return counts
    }

    static func sanitizedEvent(_ event: CapturedEvent) -> CapturedEvent? {
        if isPrivateBrowserWindow(event.windowTitle) { return nil }
        if let target = event.target,
           isSecureElement(
               role: target.role,
               subrole: target.subrole,
               title: target.title,
               description: nil,
               identifier: target.identifier
           ) { return nil }
        let target = event.target.map {
            CapturedTarget(
                role: sanitize($0.role, maximumLength: 100),
                subrole: sanitize($0.subrole, maximumLength: 100),
                title: sanitize($0.title, maximumLength: 500),
                identifier: sanitize($0.identifier, maximumLength: 300)
            )
        }
        return CapturedEvent(
            id: event.id,
            timestamp: event.timestamp,
            kind: event.kind,
            applicationName: sanitize(event.applicationName, maximumLength: 200) ?? "Unknown",
            bundleID: sanitize(event.bundleID, maximumLength: 300) ?? "unknown",
            windowTitle: sanitize(event.windowTitle, maximumLength: 1_000),
            documentPath: normalizedDocumentPath(event.documentPath),
            url: sanitizedBrowserURL(event.url)?.absoluteString,
            target: target,
            detail: sanitize(event.detail, maximumLength: 2_000, preserveLines: true),
            axText: sanitize(event.axText, maximumLength: 12_000, preserveLines: true)
        )
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
