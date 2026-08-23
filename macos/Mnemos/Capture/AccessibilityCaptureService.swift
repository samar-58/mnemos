import AppKit
import ApplicationServices
import Foundation

struct CapturableApplication: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let processIdentifier: pid_t
    let isBrowser: Bool

    var id: String { bundleID }
}

struct CapturedEvent: Identifiable, Equatable {
    enum Kind: String {
        case application = "Application"
        case window = "Window"
        case selection = "Selection"
    }

    let id = UUID()
    let timestamp: Date
    let kind: Kind
    let applicationName: String
    let bundleID: String
    let windowTitle: String?
    let detail: String?

    var fingerprint: String {
        [bundleID, windowTitle ?? "", detail ?? ""].joined(separator: "\u{1f}")
    }
}

@MainActor
final class AccessibilityCaptureService {
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
    ]

    private var lastFingerprint: String?

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    static func runningApplications(excludingBundleID: String?) -> [CapturableApplication] {
        let applications = NSWorkspace.shared.runningApplications.compactMap { application -> CapturableApplication? in
            guard application.activationPolicy == .regular,
                  !application.isTerminated,
                  let bundleID = application.bundleIdentifier,
                  bundleID != excludingBundleID,
                  let name = application.localizedName else {
                return nil
            }
            return CapturableApplication(
                bundleID: bundleID,
                name: name,
                processIdentifier: application.processIdentifier,
                isBrowser: browserBundleIDs.contains(bundleID)
            )
        }

        return Dictionary(grouping: applications, by: \.bundleID)
            .compactMap { $0.value.first }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func captureFrontmostApplication(allowedBundleIDs: Set<String>) -> CapturedEvent? {
        guard Self.isTrusted,
              let application = NSWorkspace.shared.frontmostApplication,
              let bundleID = application.bundleIdentifier,
              allowedBundleIDs.contains(bundleID),
              let applicationName = application.localizedName else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let window = Self.elementAttribute(kAXFocusedWindowAttribute as CFString, from: applicationElement)
        let windowTitle = window.flatMap { Self.stringAttribute(kAXTitleAttribute as CFString, from: $0) }

        var kind = CapturedEvent.Kind.window
        var detail: String?

        // Browser page content and addresses need a separate domain allowlist, so the
        // prototype intentionally records only the browser window title.
        if !Self.browserBundleIDs.contains(bundleID),
           let focusedElement = Self.elementAttribute(kAXFocusedUIElementAttribute as CFString, from: applicationElement) {
            let role = Self.stringAttribute(kAXRoleAttribute as CFString, from: focusedElement)
            guard !Self.isSecureRole(role) else { return nil }

            if let selectedText = Self.stringAttribute(kAXSelectedTextAttribute as CFString, from: focusedElement) {
                detail = Self.sanitize(selectedText, maximumLength: 1_000)
                if detail != nil { kind = .selection }
            }

            if detail == nil, !Self.isEditableTextRole(role) {
                let description = Self.stringAttribute(kAXDescriptionAttribute as CFString, from: focusedElement)
                    ?? Self.stringAttribute(kAXHelpAttribute as CFString, from: focusedElement)
                    ?? Self.stringAttribute(kAXTitleAttribute as CFString, from: focusedElement)
                detail = Self.sanitize(description, maximumLength: 500)
            }
        }

        let event = CapturedEvent(
            timestamp: .now,
            kind: windowTitle == nil && detail == nil ? .application : kind,
            applicationName: applicationName,
            bundleID: bundleID,
            windowTitle: Self.sanitize(windowTitle, maximumLength: 500),
            detail: detail
        )

        guard event.windowTitle != nil || event.detail != nil else { return nil }
        guard event.fingerprint != lastFingerprint else { return nil }
        lastFingerprint = event.fingerprint
        return event
    }

    private static func elementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func isSecureRole(_ role: String?) -> Bool {
        guard let role = role?.lowercased() else { return false }
        return role.contains("secure") || role.contains("password")
    }

    private static func isEditableTextRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
    }

    private static func sanitize(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\u{0000}", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(maximumLength))
    }
}
