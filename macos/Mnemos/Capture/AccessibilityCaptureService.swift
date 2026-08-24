import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

private struct CapturedInputSignal: Sendable {
    enum Kind: Sendable {
        case keyDown
        case mouseDown
        case mouseUp
        case tapDisabled
    }

    let kind: Kind
    let keyCode: Int64
    let text: String?
    let flags: UInt64
    let locationX: Double
    let locationY: Double
    let mouseButton: Int64
    let clickCount: Int64
}

private func mnemosAXObserverCallback(
    _: AXObserver,
    _: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let serviceAddress = UInt(bitPattern: refcon)
    let notificationName = notification as String
    Task { @MainActor in
        guard let pointer = UnsafeMutableRawPointer(bitPattern: serviceAddress) else { return }
        let service = Unmanaged<AccessibilityCaptureService>.fromOpaque(pointer).takeUnretainedValue()
        service.handleAXNotification(notificationName)
    }
}

private func mnemosEventTapCallback(
    _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }

    let kind: CapturedInputSignal.Kind
    switch type {
    case .keyDown:
        kind = .keyDown
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
        kind = .mouseDown
    case .leftMouseUp, .rightMouseUp, .otherMouseUp:
        kind = .mouseUp
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        kind = .tapDisabled
    default:
        return Unmanaged.passUnretained(event)
    }

    var text: String?
    if type == .keyDown {
        var buffer = [UniChar](repeating: 0, count: 64)
        var length = 0
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        if length > 0 {
            text = String(utf16CodeUnits: buffer, count: length)
        }
    }

    let location = event.location
    let signal = CapturedInputSignal(
        kind: kind,
        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
        text: text,
        flags: event.flags.rawValue,
        locationX: location.x,
        locationY: location.y,
        mouseButton: event.getIntegerValueField(.mouseEventButtonNumber),
        clickCount: event.getIntegerValueField(.mouseEventClickState)
    )
    let serviceAddress = UInt(bitPattern: refcon)
    Task { @MainActor in
        guard let pointer = UnsafeMutableRawPointer(bitPattern: serviceAddress) else { return }
        let service = Unmanaged<AccessibilityCaptureService>.fromOpaque(pointer).takeUnretainedValue()
        service.handleInput(signal)
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
final class AccessibilityCaptureService {
    private struct TextBuffer {
        let context: AXCaptureContext
        var text: String
    }

    private struct MouseDownState {
        let target: CapturedTarget?
        let point: CGPoint
        let button: Int64
        let clickCount: Int64
    }

    private var isRunning = false
    private var allowedBundleIDs: Set<String> = []
    private var allowedDomains: Set<String> = []
    private var eventSink: ((CapturedEvent) -> Void)?

    private var workspaceActivationObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var axObserver: AXObserver?
    private var axRegistrations: [(element: AXUIElement, notification: String)] = []
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?

    private var textBuffer: TextBuffer?
    private var textFlushTask: Task<Void, Never>?
    private var mouseDownState: MouseDownState?
    private var snapshotTask: Task<Void, Never>?
    private var previousSnapshots: [String: [String]] = [:]
    private var previousTerminalValues: [String: String] = [:]
    private var recentFingerprints: [String: Date] = [:]

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
                isBrowser: CapturePrivacy.isBrowser(bundleID)
            )
        }

        return Dictionary(grouping: applications, by: \.bundleID)
            .compactMap { $0.value.first }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func start(
        allowedBundleIDs: Set<String>,
        allowedDomains: Set<String>,
        onEvent: @escaping (CapturedEvent) -> Void
    ) -> Bool {
        stop(emitSessionEvent: false)
        guard Self.isTrusted else { return false }

        self.allowedBundleIDs = allowedBundleIDs
        self.allowedDomains = allowedDomains
        eventSink = onEvent
        isRunning = true

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.bindToFrontmostApplication(reason: "Frontmost application changed")
            }
        }
        registerLifecycleObservers()

        let inputMonitoringAvailable = installEventTap()
        bindToFrontmostApplication(reason: "Capture session started")
        return inputMonitoringAvailable
    }

    func updatePolicy(allowedBundleIDs: Set<String>, allowedDomains: Set<String>) {
        self.allowedBundleIDs = allowedBundleIDs
        self.allowedDomains = allowedDomains
        guard isRunning else { return }
        flushTextBuffer()
        bindToFrontmostApplication(reason: "Observation policy changed")
    }

    func stop(emitSessionEvent: Bool = true) {
        guard isRunning || eventSink != nil else { return }
        flushTextBuffer()
        if emitSessionEvent, let context = currentContext() {
            emit(makeEvent(kind: .session, context: context, detail: "Capture session paused"), dedupeWindow: 0)
        }
        isRunning = false

        if let observer = workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceActivationObserver = nil
        for observer in lifecycleObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
        removeAXObserver()
        removeEventTap()
        textFlushTask?.cancel()
        snapshotTask?.cancel()
        textBuffer = nil
        mouseDownState = nil
        eventSink = nil
    }

    func handleAXNotification(_ notification: String) {
        guard isRunning else { return }
        if notification == (kAXFocusedUIElementChangedNotification as String)
            || notification == (kAXFocusedWindowChangedNotification as String)
            || notification == (kAXWindowCreatedNotification as String) {
            bindAXNotificationsForCurrentElements()
        }

        guard let context = currentContext(), !AXContextReader.isSecureFocusedElement(context) else {
            textBuffer = nil
            return
        }

        switch notification {
        case kAXFocusedWindowChangedNotification,
             kAXWindowCreatedNotification,
             kAXTitleChangedNotification:
            emit(makeEvent(kind: .window, context: context, detail: notificationLabel(notification)))
        case kAXFocusedUIElementChangedNotification:
            flushTextBuffer()
            emit(makeEvent(kind: .focus, context: context, detail: "Focused element changed"), dedupeWindow: 0.25)
        case kAXSelectedTextChangedNotification:
            if let selectedText = AXContextReader.selectedText(in: context) {
                emit(makeEvent(kind: .selection, context: context, detail: selectedText), dedupeWindow: 0.25)
            }
        case kAXValueChangedNotification:
            captureTerminalChangeIfNeeded(context)
        default:
            break
        }

        scheduleAXSnapshot()
    }

    fileprivate func handleInput(_ signal: CapturedInputSignal) {
        guard isRunning else { return }
        if signal.kind == .tapDisabled {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        guard let context = currentContext(),
              !AXContextReader.isSecureFocusedElement(context),
              !IsSecureEventInputEnabled() else {
            textBuffer = nil
            return
        }

        switch signal.kind {
        case .keyDown:
            captureKeyboard(signal, context: context)
        case .mouseDown:
            flushTextBuffer()
            let point = CGPoint(x: signal.locationX, y: signal.locationY)
            mouseDownState = MouseDownState(
                target: AXContextReader.target(at: point, expectedPID: context.processIdentifier),
                point: point,
                button: signal.mouseButton,
                clickCount: signal.clickCount
            )
        case .mouseUp:
            captureMouseUp(signal, currentContext: context)
        case .tapDisabled:
            break
        }
    }

    private func bindToFrontmostApplication(reason: String) {
        removeAXObserver()
        guard isRunning,
              let application = NSWorkspace.shared.frontmostApplication,
              let bundleID = application.bundleIdentifier,
              allowedBundleIDs.contains(bundleID) else {
            return
        }

        var observer: AXObserver?
        guard AXObserverCreate(application.processIdentifier, mnemosAXObserverCallback, &observer) == .success,
              let observer else {
            return
        }
        axObserver = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        bindAXNotificationsForCurrentElements()

        guard let context = currentContext() else { return }
        emit(makeEvent(kind: .application, context: context, detail: reason), dedupeWindow: 0)
        if context.browserURL != nil {
            emit(makeEvent(kind: .browser, context: context, detail: "Allowed browser context"), dedupeWindow: 0)
        } else if context.documentPath != nil {
            emit(makeEvent(kind: .document, context: context, detail: "Document context"), dedupeWindow: 0)
        }
        captureAXSnapshot()
    }

    private func bindAXNotificationsForCurrentElements() {
        guard let observer = axObserver,
              let application = NSWorkspace.shared.frontmostApplication,
              let bundleID = application.bundleIdentifier,
              allowedBundleIDs.contains(bundleID) else {
            return
        }

        clearAXRegistrations(observer: observer)
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        addNotifications(
            [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification, kAXWindowCreatedNotification],
            to: applicationElement,
            observer: observer
        )

        if let window = AXContextReader.elementAttribute(kAXFocusedWindowAttribute as CFString, from: applicationElement) {
            addNotifications(
                [kAXTitleChangedNotification, kAXMovedNotification, kAXResizedNotification],
                to: window,
                observer: observer
            )
        }
        if let focused = AXContextReader.elementAttribute(kAXFocusedUIElementAttribute as CFString, from: applicationElement) {
            addNotifications(
                [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXUIElementDestroyedNotification],
                to: focused,
                observer: observer
            )
        }
    }

    private func addNotifications(_ notifications: [String], to element: AXUIElement, observer: AXObserver) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in notifications {
            let result = AXObserverAddNotification(observer, element, notification as CFString, refcon)
            if result == .success {
                axRegistrations.append((element, notification))
            }
            if result != .success && result != .notificationAlreadyRegistered && result != .notificationUnsupported {
                emitDiagnostic("AX notification registration failed: \(notification) (\(result.rawValue))")
            }
        }
    }

    private func removeAXObserver() {
        if let observer = axObserver {
            clearAXRegistrations(observer: observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        axObserver = nil
    }

    private func clearAXRegistrations(observer: AXObserver) {
        for registration in axRegistrations {
            AXObserverRemoveNotification(observer, registration.element, registration.notification as CFString)
        }
        axRegistrations.removeAll(keepingCapacity: true)
    }

    private func installEventTap() -> Bool {
        let eventTypes: [CGEventType] = [
            .keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { partial, eventType in
            partial | (CGEventMask(1) << eventType.rawValue)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: mnemosEventTapCallback,
            userInfo: refcon
        ) else {
            emitDiagnostic("Keyboard and mouse event tap is unavailable; AX events will continue.")
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeEventTap() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        eventTapSource = nil
        eventTap = nil
    }

    private func captureKeyboard(_ signal: CapturedInputSignal, context: AXCaptureContext) {
        let flags = CGEventFlags(rawValue: signal.flags)
        let shortcutModifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        let equivalent = keyEquivalent(keyCode: signal.keyCode, text: signal.text, flags: flags)

        if !shortcutModifiers.isEmpty || equivalent != nil {
            flushTextBuffer()
            emit(makeEvent(kind: .keyboard, context: context, detail: equivalent ?? modifierDescription(flags: flags)), dedupeWindow: 0)
            scheduleAXSnapshot()
            return
        }

        guard let text = signal.text, !text.isEmpty else {
            return
        }
        let printable = String(text.filter { character in
            character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        })
        guard !printable.isEmpty else { return }

        if textBuffer?.context.bundleID != context.bundleID
            || textBuffer?.context.windowTitle != context.windowTitle
            || textBuffer?.context.target != context.target {
            flushTextBuffer()
        }
        if textBuffer == nil {
            textBuffer = TextBuffer(context: context, text: "")
        }
        textBuffer?.text.append(printable)
        if (textBuffer?.text.count ?? 0) >= 500 {
            flushTextBuffer()
        } else {
            scheduleTextFlush()
        }
    }

    private func scheduleTextFlush() {
        textFlushTask?.cancel()
        textFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.flushTextBuffer()
        }
    }

    private func flushTextBuffer() {
        textFlushTask?.cancel()
        textFlushTask = nil
        guard let buffer = textBuffer else { return }
        textBuffer = nil
        guard let text = CapturePrivacy.sanitize(buffer.text, maximumLength: 1_000, preserveLines: true) else {
            return
        }
        emit(makeEvent(kind: .keyboard, context: buffer.context, detail: text), dedupeWindow: 0)
        scheduleAXSnapshot()
    }

    private func captureMouseUp(_ signal: CapturedInputSignal, currentContext: AXCaptureContext) {
        guard let down = mouseDownState else { return }
        mouseDownState = nil
        let point = CGPoint(x: signal.locationX, y: signal.locationY)
        let distance = hypot(point.x - down.point.x, point.y - down.point.y)
        let target = AXContextReader.target(at: point, expectedPID: currentContext.processIdentifier) ?? down.target
        let button = mouseButtonName(down.button)
        let detail: String
        if distance > 6 {
            detail = "\(button) drag · \(Int(distance.rounded())) pt"
        } else if down.clickCount > 1 {
            detail = "\(button) \(down.clickCount)x click"
        } else {
            detail = "\(button) click"
        }
        emit(
            CapturedEvent(
                kind: .mouse,
                applicationName: currentContext.applicationName,
                bundleID: currentContext.bundleID,
                windowTitle: currentContext.windowTitle,
                documentPath: currentContext.documentPath,
                url: currentContext.eventURL,
                target: target,
                detail: detail
            ),
            dedupeWindow: 0
        )
        scheduleAXSnapshot()
    }

    private func scheduleAXSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.captureAXSnapshot()
        }
    }

    private func captureAXSnapshot() {
        guard isRunning,
              let context = currentContext(),
              !AXContextReader.isSecureFocusedElement(context),
              let snapshot = AXContextReader.snapshot(in: context) else {
            return
        }

        let previous = previousSnapshots[snapshot.key]
        previousSnapshots[snapshot.key] = snapshot.lines
        if previous == nil {
            emit(makeEvent(kind: .axSnapshot, context: context, detail: "Initial bounded Accessibility tree", axText: snapshot.rendered), dedupeWindow: 0)
            return
        }
        guard let previous, previous != snapshot.lines else { return }
        let diff = renderDiff(old: previous, new: snapshot.lines)
        guard !diff.isEmpty else { return }
        emit(makeEvent(kind: .axDiff, context: context, detail: "Meaningful Accessibility tree changes", axText: diff), dedupeWindow: 0)
    }

    private func renderDiff(old: [String], new: [String]) -> String {
        let oldSet = Set(old)
        let newSet = Set(new)
        let removed = old.filter { !newSet.contains($0) }.prefix(80).map { "- \($0)" }
        let added = new.filter { !oldSet.contains($0) }.prefix(80).map { "+ \($0)" }
        let changes = removed + added
        guard !changes.isEmpty else { return "" }
        let suffix = changes.count >= 160 ? "\n… diff truncated" : ""
        return changes.joined(separator: "\n") + suffix
    }

    private func captureTerminalChangeIfNeeded(_ context: AXCaptureContext) {
        guard CapturePrivacy.isTerminal(context.bundleID),
              let value = AXContextReader.focusedValue(in: context, maximumLength: 15_000) else {
            return
        }
        let key = [context.bundleID, context.windowTitle ?? "untitled"].joined(separator: "\u{1f}")
        let previous = previousTerminalValues[key]
        previousTerminalValues[key] = value

        let delta: String
        if let previous, value.hasPrefix(previous) {
            delta = String(value.dropFirst(previous.count))
        } else {
            delta = value.components(separatedBy: .newlines).suffix(20).joined(separator: "\n")
        }
        guard let detail = CapturePrivacy.sanitize(delta, maximumLength: 2_000, preserveLines: true) else { return }
        emit(makeEvent(kind: .terminal, context: context, detail: detail), dedupeWindow: 0)
    }

    private func currentContext() -> AXCaptureContext? {
        AXContextReader.frontmostContext(allowedBundleIDs: allowedBundleIDs, allowedDomains: allowedDomains)
    }

    private func registerLifecycleObservers() {
        let boundaries: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "System sleep"),
            (NSWorkspace.screensDidSleepNotification, "Screen sleep"),
            (NSWorkspace.sessionDidResignActiveNotification, "Screen locked"),
        ]
        for (name, detail) in boundaries {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.emitSystemBoundary(detail) }
            }
            lifecycleObservers.append(observer)
        }
    }

    private func emitSystemBoundary(_ detail: String) {
        guard isRunning else { return }
        flushTextBuffer()
        emit(
            CapturedEvent(
                kind: .session,
                applicationName: "macOS",
                bundleID: "com.apple.system",
                detail: detail
            ),
            dedupeWindow: 0
        )
    }

    private func makeEvent(
        kind: CapturedEvent.Kind,
        context: AXCaptureContext,
        detail: String? = nil,
        axText: String? = nil
    ) -> CapturedEvent {
        CapturedEvent(
            kind: kind,
            applicationName: context.applicationName,
            bundleID: context.bundleID,
            windowTitle: context.windowTitle,
            documentPath: context.documentPath,
            url: context.eventURL,
            target: context.target,
            detail: CapturePrivacy.sanitize(detail, maximumLength: 2_000, preserveLines: true),
            axText: axText
        )
    }

    private func emit(_ event: CapturedEvent, dedupeWindow: TimeInterval = 1) {
        let now = Date.now
        recentFingerprints = recentFingerprints.filter { now.timeIntervalSince($0.value) < 300 }
        if dedupeWindow > 0,
           let lastSeen = recentFingerprints[event.fingerprint],
           now.timeIntervalSince(lastSeen) < dedupeWindow {
            return
        }
        recentFingerprints[event.fingerprint] = now
        eventSink?(event)
    }

    private func emitDiagnostic(_ detail: String) {
        let application = NSWorkspace.shared.frontmostApplication
        emit(
            CapturedEvent(
                kind: .diagnostic,
                applicationName: application?.localizedName ?? "Mnemos",
                bundleID: application?.bundleIdentifier ?? Bundle.main.bundleIdentifier ?? "dev.mnemos.app",
                detail: detail
            ),
            dedupeWindow: 5
        )
    }

    private func notificationLabel(_ notification: String) -> String {
        switch notification {
        case kAXFocusedWindowChangedNotification: "Focused window changed"
        case kAXWindowCreatedNotification: "Window created"
        case kAXTitleChangedNotification: "Window title changed"
        default: notification
        }
    }

    private func keyEquivalent(keyCode: Int64, text: String?, flags: CGEventFlags) -> String? {
        let modifiers = modifierDescription(flags: flags)
        let special: [Int64: String] = [
            36: "Return", 48: "Tab", 51: "Delete", 53: "Escape", 76: "Enter",
            117: "Forward Delete", 123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
        ]
        if let key = special[keyCode] { return modifiers + key }
        guard !modifiers.isEmpty else { return nil }
        let key = text?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return modifiers + (key?.isEmpty == false ? key! : "Key \(keyCode)")
    }

    private func modifierDescription(flags: CGEventFlags) -> String {
        var result = ""
        if flags.contains(.maskControl) { result += "⌃" }
        if flags.contains(.maskAlternate) { result += "⌥" }
        if flags.contains(.maskShift) { result += "⇧" }
        if flags.contains(.maskCommand) { result += "⌘" }
        return result
    }

    private func mouseButtonName(_ number: Int64) -> String {
        switch number {
        case 0: "Left"
        case 1: "Right"
        default: "Button \(number + 1)"
        }
    }
}
