import Foundation

struct CapturableApplication: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let processIdentifier: pid_t
    let isBrowser: Bool

    var id: String { bundleID }
}

struct CapturedTarget: Equatable {
    let role: String?
    let subrole: String?
    let title: String?
    let identifier: String?

    var summary: String? {
        let name = title ?? identifier
        switch (role, name) {
        case let (role?, name?): return "\(role) · \(name)"
        case let (role?, nil): return role
        case let (nil, name?): return name
        case (nil, nil): return nil
        }
    }
}

struct CapturedEvent: Identifiable, Equatable {
    enum Kind: String {
        case session = "Session"
        case application = "Application"
        case window = "Window"
        case focus = "Focus"
        case keyboard = "Keyboard"
        case mouse = "Mouse"
        case selection = "Selection"
        case document = "Document"
        case browser = "Browser"
        case terminal = "Terminal"
        case axSnapshot = "AX snapshot"
        case axDiff = "AX diff"
        case diagnostic = "Diagnostic"
    }

    let id = UUID()
    let timestamp: Date
    let kind: Kind
    let applicationName: String
    let bundleID: String
    let windowTitle: String?
    let documentPath: String?
    let url: String?
    let target: CapturedTarget?
    let detail: String?
    let axText: String?

    init(
        timestamp: Date = .now,
        kind: Kind,
        applicationName: String,
        bundleID: String,
        windowTitle: String? = nil,
        documentPath: String? = nil,
        url: String? = nil,
        target: CapturedTarget? = nil,
        detail: String? = nil,
        axText: String? = nil
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.applicationName = applicationName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.documentPath = documentPath
        self.url = url
        self.target = target
        self.detail = detail
        self.axText = axText
    }

    var fingerprint: String {
        [
            kind.rawValue,
            bundleID,
            windowTitle ?? "",
            documentPath ?? "",
            url ?? "",
            target?.summary ?? "",
            detail ?? "",
            axText.map { String($0.hashValue) } ?? "",
        ].joined(separator: "\u{1f}")
    }
}
