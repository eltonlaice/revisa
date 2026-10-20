import AppKit
import ApplicationServices
import ServiceManagement

// MARK: - LanguageTool

struct LTMatch: Decodable {
    struct Replacement: Decodable { let value: String }
    struct Rule: Decodable { let id: String; let issueType: String }
    let message: String
    let offset: Int   // UTF-16, same as NSString/AX
    let length: Int
    let replacements: [Replacement]
    let rule: Rule
}

struct LTResponse: Decodable { let matches: [LTMatch] }

func formEncode(_ fields: [(String, String)]) -> Data {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    return Data(fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
        .joined(separator: "&").utf8)
}

enum LanguageTool {
    // defaults write com.revisa.app server http://localhost:8081
    // defaults write com.revisa.app language pt-PT   (default: auto)
    static var server: URL { URL(string: UserDefaults.standard.string(forKey: "server") ?? "http://localhost:8081")! }
    static var language: String { UserDefaults.standard.string(forKey: "language") ?? "auto" }

    static func check(_ text: String) async throws -> [LTMatch] {
        var req = URLRequest(url: server.appendingPathComponent("v2/check"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([("text", text), ("language", language)])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(LTResponse.self, from: data).matches
    }
}

// MARK: - Accessibility

enum AX {
    static let systemWide: AXUIElement = {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }()

    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    /// Focused text field in another app. Never returns password fields.
    static func focusedTextElement() -> AXUIElement? {
        guard let v = copy(systemWide, kAXFocusedUIElementAttribute),
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let el = v as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        guard pid != getpid() else { return nil }
        let role = copy(el, kAXRoleAttribute) as? String
        let subrole = copy(el, kAXSubroleAttribute) as? String
        guard role == kAXTextAreaRole || role == kAXTextFieldRole,
              subrole != kAXSecureTextFieldSubrole else { return nil }
        return el
    }

    static func text(_ el: AXUIElement) -> String? { copy(el, kAXValueAttribute) as? String }

    /// Range bounds in AX coordinates (origin at the top-left of the main screen).
    static func bounds(_ el: AXUIElement, _ r: NSRange) -> CGRect? {
        var cf = CFRange(location: r.location, length: r.length)
        guard let range = AXValueCreate(.cfRange, &cf) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(out as! AXValue, .cgRect, &rect)
        return rect.width > 0 && rect.height > 0 && rect.height < 200 ? rect : nil
    }

    static func replace(_ el: AXUIElement, _ r: NSRange, with s: String, in text: String) {
        var cf = CFRange(location: r.location, length: r.length)
        let range = AXValueCreate(.cfRange, &cf)!
        if AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, range) == .success,
           AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, s as CFString) == .success { return }
        // Fallback: rewrite the whole value (loses undo in some apps).
        let new = (text as NSString).replacingCharacters(in: r, with: s)
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, new as CFString)
    }
}

func cocoaRect(_ r: CGRect) -> NSRect {
    let h = NSScreen.screens[0].frame.height
    return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
}

func color(_ m: LTMatch) -> NSColor {
    switch m.rule.issueType {
    case "misspelling": .systemRed
    case "grammar", "typographical", "duplication": .systemOrange
    default: .systemBlue
    }
}

// MARK: - Overlay

struct Mark { let rect: NSRect; let range: NSRange; let match: LTMatch }  // rect in Cocoa screen coordinates

final class OverlayView: NSView {
    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var onClick: ((Mark, NSEvent) -> Void)?

    func local(_ r: NSRect) -> NSRect { window.map { $0.convertFromScreen(r) } ?? r }

    override func draw(_ dirty: NSRect) {
        for m in marks {
            let r = local(m.rect), c = color(m.match)
            // The faint fill is also what makes the area clickable (fully transparent pixels let clicks through).
            c.withAlphaComponent(0.12).setFill(); r.fill()
            c.setFill(); NSRect(x: r.minX, y: r.minY, width: r.width, height: 2).fill()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        if let m = marks.first(where: { local($0.rect).contains(e.locationInWindow) }) { onClick?(m, e) }
    }
}

final class BlockItem: NSMenuItem {
    let block: () -> Void
    init(_ title: String, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { block() }
}

// MARK: - App

@MainActor
final class Revisa: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let overlay = OverlayView()
    var panel: NSPanel!

    var element: AXUIElement?
    var text = ""
    var changedAt = Date()
    var checkedText: String?     // text that `matches` belongs to
    var inflight = false
    var matches: [LTMatch] = []
    var ignored = Set<String>()  // ponytail: in-memory only, persist to UserDefaults if needed
    var paused = false
    var trusted = false
    var status = "Starting…"

    func applicationDidFinishLaunching(_: Notification) {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)

        // ponytail: one panel covering all screens at launch; rebuild on didChangeScreenParameters if displays change
        let frame = NSScreen.screens.map(\.frame).reduce(NSRect.null) { $0.union($1) }
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = overlay
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        overlay.onClick = { [unowned self] in showSuggestions($0, $1) }

        statusItem.button?.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "Revisa")
        statusItem.button?.imagePosition = .imageLeading
        // Launch at login by default; the user can turn it off from the menu.
        if !UserDefaults.standard.bool(forKey: "loginItemSet") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemSet")
        }
        rebuildMenu()

        // ponytail: polling every 0.3s; switch to AXObserver if CPU cost matters
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    func tick() {
        let t = AXIsProcessTrusted()
        if t != trusted { trusted = t; rebuildMenu() }

        guard !paused, trusted, let el = AX.focusedTextElement(), let value = AX.text(el),
              value.utf16.count <= 20_000 else { return reset() }

        if element.map({ !CFEqual($0, el) }) ?? true { element = el; checkedText = nil; matches = [] }
        if value != text { text = value; changedAt = Date() }

        if value == checkedText { layout(el) } else if !overlay.marks.isEmpty { overlay.marks = [] }

        if value != checkedText, !inflight, Date().timeIntervalSince(changedAt) > 0.7,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            check(value)
        }
        updateTitle()
    }

    func reset() {
        element = nil
        text = ""
        checkedText = nil
        matches = []
        if !overlay.marks.isEmpty { overlay.marks = [] }
        updateTitle()
    }

    func check(_ t: String) {
        inflight = true
        Task {
            defer { inflight = false }
            do {
                let m = try await LanguageTool.check(t)
                status = "LanguageTool: OK"
                if t == text { matches = m; checkedText = t }
            } catch {
                status = "No response from \(LanguageTool.server.absoluteString)"
                if t == text { matches = []; checkedText = t }  // don't retry until the text changes
            }
            rebuildMenu()
        }
    }

    func key(_ m: LTMatch, _ ns: NSString) -> String {
        "\(m.rule.id)|\(ns.substring(with: NSRange(location: m.offset, length: m.length)))"
    }

    func layout(_ el: AXUIElement) {
        let ns = text as NSString
        // ponytail: an issue that wraps lines gets one union rect; split per line if it bothers
        overlay.marks = matches.compactMap { m in
            let r = NSRange(location: m.offset, length: m.length)
            guard NSMaxRange(r) <= ns.length, !ignored.contains(key(m, ns)),
                  let b = AX.bounds(el, r) else { return nil }
            return Mark(rect: cocoaRect(b), range: r, match: m)
        }
    }

    func showSuggestions(_ mark: Mark, _ event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: mark.match.message, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for rep in mark.match.replacements.prefix(6) {
            menu.addItem(BlockItem(rep.value.isEmpty ? "(remove)" : rep.value) { [unowned self] in
                guard let el = element, text == checkedText else { return }
                AX.replace(el, mark.range, with: rep.value, in: text)
                checkedText = nil
                overlay.marks = []
            })
        }
        if !mark.match.replacements.isEmpty { menu.addItem(.separator()) }
        menu.addItem(BlockItem("Ignore") { [unowned self] in
            ignored.insert(key(mark.match, text as NSString))
            if let el = element { layout(el) }
        })
        NSMenu.popUpContextMenu(menu, with: event, for: overlay)
    }

    func updateTitle() {
        let n = overlay.marks.count
        let title = n > 0 ? " \(n)" : ""
        if statusItem.button?.title != title { statusItem.button?.title = title }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        if !trusted {
            menu.addItem(BlockItem("Grant Accessibility Permission…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            })
        }
        menu.addItem(.separator())
        let login = BlockItem("Open at Login") { [unowned self] in
            let svc = SMAppService.mainApp
            if svc.status == .enabled { try? svc.unregister() } else { try? svc.register() }
            if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            rebuildMenu()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(BlockItem(paused ? "Resume" : "Pause") { [unowned self] in
            paused.toggle()
            rebuildMenu()
        })
        if !ignored.isEmpty {
            menu.addItem(BlockItem("Clear Ignored (\(ignored.count))") { [unowned self] in
                ignored = []
                rebuildMenu()
            })
        }
        menu.addItem(.separator())
        menu.addItem(BlockItem("Quit Revisa") { NSApp.terminate(nil) })
        statusItem.menu = menu
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--selftest") {
    precondition(String(decoding: formEncode([("text", "a+b & é=1"), ("language", "auto")]), as: UTF8.self)
                 == "text=a%2Bb%20%26%20%C3%A9%3D1&language=auto")
    let json = #"{"matches":[{"message":"m","offset":2,"length":3,"replacements":[{"value":"x"}],"rule":{"id":"R","issueType":"misspelling"},"extra":1}]}"#
    let m = try! JSONDecoder().decode(LTResponse.self, from: Data(json.utf8)).matches
    precondition(m.count == 1 && m[0].offset == 2 && m[0].replacements[0].value == "x")
    precondition(cocoaRect(CGRect(x: 10, y: 0, width: 5, height: 20)).maxY == NSScreen.screens[0].frame.height)
    print("selftest ok")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = Revisa()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
