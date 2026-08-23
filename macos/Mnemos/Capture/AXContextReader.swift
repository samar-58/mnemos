import AppKit
import ApplicationServices
import Foundation

struct AXCaptureContext {
    let applicationName: String
    let bundleID: String
    let processIdentifier: pid_t
    let applicationElement: AXUIElement
    let windowElement: AXUIElement?
    let focusedElement: AXUIElement?
    let windowTitle: String?
    let documentPath: String?
    let browserURL: URL?
    let target: CapturedTarget?

    var eventURL: String? { browserURL?.absoluteString }
}

struct AXTreeSnapshot {
    let key: String
    let lines: [String]

    var rendered: String { lines.joined(separator: "\n") }
}

enum AXContextReader {
    private static let maximumNodes = 300
    private static let maximumDepth = 9
    private static let maximumSnapshotCharacters = 30_000

    static func frontmostContext(
        allowedBundleIDs: Set<String>,
        allowedDomains: Set<String>
    ) -> AXCaptureContext? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleID = application.bundleIdentifier,
              allowedBundleIDs.contains(bundleID),
              let applicationName = application.localizedName else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let window = elementAttribute(kAXFocusedWindowAttribute as CFString, from: applicationElement)
        let focusedElement = elementAttribute(kAXFocusedUIElementAttribute as CFString, from: applicationElement)
        let windowTitle = CapturePrivacy.sanitize(
            window.flatMap { stringAttribute(kAXTitleAttribute as CFString, from: $0) },
            maximumLength: 500
        )

        if CapturePrivacy.isBrowser(bundleID), CapturePrivacy.isPrivateBrowserWindow(windowTitle) {
            return nil
        }

        let browserURL: URL?
        if CapturePrivacy.isBrowser(bundleID) {
            guard let window,
                  let candidate = findBrowserURL(in: window),
                  CapturePrivacy.isAllowed(candidate, domains: allowedDomains) else {
                return nil
            }
            browserURL = candidate
        } else {
            browserURL = nil
        }

        let rawDocument = window.flatMap { stringAttribute(kAXDocumentAttribute as CFString, from: $0) }
            ?? stringAttribute(kAXDocumentAttribute as CFString, from: applicationElement)
        let target = focusedElement.flatMap(elementTarget)

        return AXCaptureContext(
            applicationName: applicationName,
            bundleID: bundleID,
            processIdentifier: application.processIdentifier,
            applicationElement: applicationElement,
            windowElement: window,
            focusedElement: focusedElement,
            windowTitle: windowTitle,
            documentPath: CapturePrivacy.normalizedDocumentPath(rawDocument),
            browserURL: browserURL,
            target: target
        )
    }

    static func isSecureFocusedElement(_ context: AXCaptureContext) -> Bool {
        guard let element = context.focusedElement else { return false }
        return isSecure(element)
    }

    static func selectedText(in context: AXCaptureContext) -> String? {
        guard let element = context.focusedElement, !isSecure(element) else { return nil }
        return CapturePrivacy.sanitize(
            stringAttribute(kAXSelectedTextAttribute as CFString, from: element),
            maximumLength: 2_000,
            preserveLines: true
        )
    }

    static func focusedValue(in context: AXCaptureContext, maximumLength: Int) -> String? {
        guard let element = context.focusedElement, !isSecure(element) else { return nil }
        return CapturePrivacy.sanitize(
            stringAttribute(kAXValueAttribute as CFString, from: element),
            maximumLength: maximumLength,
            preserveLines: true
        )
    }

    static func target(at point: CGPoint, expectedPID: pid_t) -> CapturedTarget? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else {
            return nil
        }
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == expectedPID else {
            return nil
        }
        return elementTarget(element)
    }

    static func snapshot(in context: AXCaptureContext) -> AXTreeSnapshot? {
        let root = context.windowElement ?? context.applicationElement
        var lines: [String] = []
        var characters = 0
        var nodes = 0

        func visit(_ element: AXUIElement, path: String, depth: Int) {
            guard nodes < maximumNodes,
                  depth <= maximumDepth,
                  characters < maximumSnapshotCharacters else {
                return
            }
            nodes += 1

            let role = stringAttribute(kAXRoleAttribute as CFString, from: element)
            let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element)
            let title = stringAttribute(kAXTitleAttribute as CFString, from: element)
            let description = stringAttribute(kAXDescriptionAttribute as CFString, from: element)
            let identifier = stringAttribute(kAXIdentifierAttribute as CFString, from: element)
            let secure = CapturePrivacy.isSecureElement(
                role: role,
                subrole: subrole,
                title: title,
                description: description,
                identifier: identifier
            )

            var components = ["[\(path)]", "role=\(role ?? "unknown")"]
            if let subrole = CapturePrivacy.sanitize(subrole, maximumLength: 120) {
                components.append("subrole=\(quoted(subrole))")
            }
            if let title = CapturePrivacy.sanitize(title, maximumLength: 300) {
                components.append("title=\(quoted(title))")
            }
            if let description = CapturePrivacy.sanitize(description, maximumLength: 300), description != title {
                components.append("description=\(quoted(description))")
            }
            if let identifier = CapturePrivacy.sanitize(identifier, maximumLength: 160) {
                components.append("id=\(quoted(identifier))")
            }
            if secure {
                components.append("value=[SECURE CONTENT OMITTED]")
            } else if let value = CapturePrivacy.sanitize(
                stringAttribute(kAXValueAttribute as CFString, from: element),
                maximumLength: 600,
                preserveLines: true
            ), value != title {
                components.append("value=\(quoted(value))")
            }

            let line = components.joined(separator: " ")
            lines.append(line)
            characters += line.count
            guard !secure else { return }

            for (index, child) in childElements(of: element).enumerated() {
                visit(child, path: "\(path).\(index)", depth: depth + 1)
                if nodes >= maximumNodes || characters >= maximumSnapshotCharacters { break }
            }
        }

        visit(root, path: "0", depth: 0)
        guard !lines.isEmpty else { return nil }
        if nodes >= maximumNodes || characters >= maximumSnapshotCharacters {
            lines.append("… snapshot truncated at the privacy and size boundary")
        }
        let key = [context.bundleID, String(context.processIdentifier), context.windowTitle ?? "untitled"]
            .joined(separator: "\u{1f}")
        return AXTreeSnapshot(key: key, lines: lines)
    }

    static func elementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func elementTarget(_ element: AXUIElement) -> CapturedTarget? {
        let role = CapturePrivacy.sanitize(
            stringAttribute(kAXRoleAttribute as CFString, from: element),
            maximumLength: 100
        )
        let subrole = CapturePrivacy.sanitize(
            stringAttribute(kAXSubroleAttribute as CFString, from: element),
            maximumLength: 100
        )
        let title = CapturePrivacy.sanitize(
            stringAttribute(kAXTitleAttribute as CFString, from: element)
                ?? stringAttribute(kAXDescriptionAttribute as CFString, from: element)
                ?? stringAttribute(kAXPlaceholderValueAttribute as CFString, from: element),
            maximumLength: 300
        )
        let identifier = CapturePrivacy.sanitize(
            stringAttribute(kAXIdentifierAttribute as CFString, from: element),
            maximumLength: 160
        )
        guard role != nil || subrole != nil || title != nil || identifier != nil else { return nil }
        return CapturedTarget(role: role, subrole: subrole, title: title, identifier: identifier)
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        CapturePrivacy.isSecureElement(
            role: stringAttribute(kAXRoleAttribute as CFString, from: element),
            subrole: stringAttribute(kAXSubroleAttribute as CFString, from: element),
            title: stringAttribute(kAXTitleAttribute as CFString, from: element),
            description: stringAttribute(kAXDescriptionAttribute as CFString, from: element),
            identifier: stringAttribute(kAXIdentifierAttribute as CFString, from: element)
        )
    }

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else {
            return []
        }
        return children
    }

    private static func findBrowserURL(in root: AXUIElement) -> URL? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        var inspected = 0

        while cursor < queue.count, inspected < 500 {
            let (element, depth) = queue[cursor]
            cursor += 1
            inspected += 1

            let role = stringAttribute(kAXRoleAttribute as CFString, from: element)?.lowercased()
            let descriptor = [
                stringAttribute(kAXDescriptionAttribute as CFString, from: element),
                stringAttribute(kAXTitleAttribute as CFString, from: element),
                stringAttribute(kAXIdentifierAttribute as CFString, from: element),
            ]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            let looksLikeAddressField = role == (kAXTextFieldRole as String).lowercased()
                && (descriptor.contains("address")
                    || descriptor.contains("location")
                    || descriptor.contains("url")
                    || descriptor.contains("search or enter"))

            if looksLikeAddressField,
               let url = CapturePrivacy.sanitizedBrowserURL(
                   stringAttribute(kAXValueAttribute as CFString, from: element)
               ) {
                return url
            }

            if depth < maximumDepth {
                queue.append(contentsOf: childElements(of: element).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
