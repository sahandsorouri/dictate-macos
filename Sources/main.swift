// Dictate: hold Right Option, speak, let go. The text is typed where the cursor is.
// For longer talks: press Option+Space, speak hands-free, tap Option to finish.
// Transcription is ElevenLabs Scribe v2,
// language detected by itself. The API key lives in the macOS Keychain; the last
// 100 dictations are kept on this Mac and can be copied again from the menu.
// A dictionary in iCloud Drive (so other devices can read it too) makes names come
// out right: "words" are sent to Scribe as keyterms, "fixes" are replaced after.

import AppKit
import AVFoundation
import Carbon
import Security
import ServiceManagement

let leftOptionKeyCode: UInt16 = 58
let rightOptionKeyCode: UInt16 = 61
let minSeconds = 0.4
let historyLimit = 100
let keychainService = "dictate.elevenlabs"
let sttURL = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

// MARK: Keychain

enum Keychain {
    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: keychainService]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: History

struct Entry: Codable {
    let date: Date
    let text: String
}

enum History {
    static let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func add(_ text: String) {
        var all = load()
        all.insert(Entry(date: Date(), text: text), at: 0)
        save(Array(all.prefix(historyLimit)))
    }

    static func save(_ all: [Entry]) {
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: file, options: .atomic) }
    }
}

// MARK: Dictionary

struct Fix: Codable {
    var heard: String
    var correct: String
}

struct WordList: Codable {
    var words: [String] = []
    var fixes: [Fix] = []
}

enum Words {
    /// iCloud Drive/Dictate/dictionary.json, so other devices (for example an iPhone Shortcut) can read the same list.
    static let shared = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Dictate/dictionary.json")
    /// Last good copy on this Mac, used when iCloud is slow or offline.
    static let cache = History.file.deletingLastPathComponent().appendingPathComponent("dictionary.json")

    static func load() -> WordList {
        // A file iCloud has moved to the cloud can take seconds to come back; never block on it.
        let done = DispatchSemaphore(value: 0)
        var fresh: WordList?
        DispatchQueue.global().async {
            if let data = try? Data(contentsOf: shared) { fresh = try? JSONDecoder().decode(WordList.self, from: data) }
            done.signal()
        }
        if done.wait(timeout: .now() + 2) == .success, let fresh {
            if let data = try? JSONEncoder().encode(fresh) { try? data.write(to: cache, options: .atomic) }
            return fresh
        }
        guard let data = try? Data(contentsOf: cache) else { return WordList() }
        return (try? JSONDecoder().decode(WordList.self, from: data)) ?? WordList()
    }

    static func save(_ list: WordList) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: cache, options: .atomic)
        try? FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: shared, options: .atomic)
    }

    static func add(word: String, heard: String) {
        var list = load()
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        if !list.words.contains(word) { list.words.append(word) }
        if !heard.isEmpty, heard != word {
            list.fixes.removeAll { $0.heard.lowercased() == heard.lowercased() }
            list.fixes.append(Fix(heard: heard, correct: word))
        }
        save(list)
    }

    /// Scribe takes up to 1,000 keyterms, each under 50 characters and at most 5 words.
    static func keyterms(_ list: WordList) -> [String] {
        let banned = CharacterSet(charactersIn: "<>{}[]\\")
        var seen = Set<String>()
        var out: [String] = []
        for term in list.words + list.fixes.map(\.correct) {
            let clean = term.components(separatedBy: banned).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count < 50, clean.split(separator: " ").count <= 5,
                  seen.insert(clean.lowercased()).inserted else { continue }
            out.append(clean)
        }
        return Array(out.prefix(1000))
    }

    /// Whole-word, case-insensitive replace; works for Persian and Latin script.
    static func applyFixes(_ text: String, _ list: WordList) -> String {
        var out = text
        for fix in list.fixes where !fix.heard.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: fix.heard) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: NSRegularExpression.escapedTemplate(for: fix.correct))
        }
        return out
    }
}

// MARK: Floating pill

/// Live sound bars: newest level on the right.
final class WaveView: NSView {
    var levels = [CGFloat](repeating: 0.12, count: 14) { didSet { needsDisplay = true } }
    var idle = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth: CGFloat = 3, gap: CGFloat = 3
        let total = CGFloat(levels.count) * (barWidth + gap) - gap
        var x = (bounds.width - total) / 2
        NSColor.labelColor.withAlphaComponent(idle ? 0.3 : 0.85).setFill()
        for level in levels {
            let h = max(3, min(bounds.height, bounds.height * level))
            let rect = NSRect(x: x, y: (bounds.height - h) / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            x += barWidth + gap
        }
    }

    func push(_ level: CGFloat) {
        levels.removeFirst()
        levels.append(level)
    }
}

/// The pill at the bottom of the screen: red dot + sound bars + one short line.
final class Pill {
    static let size = NSSize(width: 248, height: 40)
    static let labelFrame = NSRect(x: 126, y: 12, width: 248 - 126 - 14, height: 16)

    let panel: NSPanel
    let wave = WaveView()
    let dot = NSView()
    let label = NSTextField(labelWithString: "")

    init(renderOnly: Bool = false) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Pill.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background: NSView
        if renderOnly {
            // Offscreen renders cannot blur; a flat fill shows the layout.
            background = NSView()
            background.wantsLayer = true
            background.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            let blur = NSVisualEffectView()
            blur.material = .popover  // follows light and dark mode
            blur.blendingMode = .behindWindow
            blur.state = .active
            background = blur
        }
        background.frame = NSRect(origin: .zero, size: Pill.size)
        background.wantsLayer = true
        background.layer?.cornerRadius = Pill.size.height / 2
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = background

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4
        dot.frame = NSRect(x: 18, y: (Pill.size.height - 8) / 2, width: 8, height: 8)
        background.addSubview(dot)

        wave.frame = NSRect(x: 34, y: 10, width: 86, height: 20)
        background.addSubview(wave)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = Pill.labelFrame
        background.addSubview(label)
    }

    func show(_ text: String, recording: Bool) {
        reset()
        label.stringValue = text
        dot.isHidden = !recording
        wave.idle = !recording
        if !recording { wave.levels = wave.levels.map { _ in 0.12 } }
        position()
        panel.orderFrontRegardless()
    }

    /// A short centered note ("Copied"), gone after a moment.
    func flash(_ text: String) {
        show(text, recording: false)
        wave.isHidden = true
        label.alignment = .center
        label.frame = NSRect(x: 20, y: Pill.labelFrame.minY, width: Pill.size.width - 40, height: 16)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.hide() }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func reset() {
        wave.isHidden = false
        label.alignment = .natural
        label.frame = Pill.labelFrame
    }

    func position() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - Pill.size.width / 2, y: area.minY + 28))
    }
}

// MARK: App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State { case idle, recording, working }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let pill = Pill()
    var recorder: AVAudioRecorder?
    var meter: Timer?
    var startedAt = Date()
    var keyDown = false
    var handsFree = false
    /// Hands-free stops on a fresh Option tap, once the keys that started it are let go.
    var optionTapArmed = false
    var hotKey: EventHotKeyRef?
    var state = State.idle { didSet { DispatchQueue.main.async { self.refreshIcon() } } }
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let historyItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
    let wordsItem = NSMenuItem(title: "Dictionary", action: nil, keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        refreshIcon()
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flags($0) }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.flags($0); return $0 }
        registerHandsFreeHotKey()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        askForAccessibilityIfNeeded()
        if Keychain.read() == nil { DispatchQueue.main.async { self.setKey() } }
    }

    // MARK: Menu

    func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        historyItem.submenu = NSMenu()
        menu.addItem(historyItem)
        let words = NSMenu()
        words.addItem(withTitle: "Add to Dictionary…", action: #selector(addWord), keyEquivalent: "").target = self
        words.addItem(withTitle: "Edit Dictionary File", action: #selector(openWords), keyEquivalent: "").target = self
        wordsItem.submenu = words
        menu.addItem(wordsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Set ElevenLabs Key…", action: #selector(setKey), keyEquivalent: "").target = self
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    /// Rebuilt each time the menu opens, so the history is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let list = Words.load()
        wordsItem.title = "Dictionary (\(list.words.count) words, \(list.fixes.count) fixes)"
        guard let sub = historyItem.submenu else { return }
        sub.removeAllItems()
        let entries = History.load()
        historyItem.title = entries.isEmpty ? "Recent" : "Recent (\(entries.count))"
        if entries.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
            return
        }
        let header = NSMenuItem(title: "Click to copy", action: nil, keyEquivalent: "")
        header.isEnabled = false
        sub.addItem(header)
        let time = DateFormatter()
        time.dateFormat = "d MMM, HH:mm"
        for (i, entry) in entries.enumerated() {
            let oneLine = entry.text.replacingOccurrences(of: "\n", with: " ")
            let short = oneLine.count > 60 ? String(oneLine.prefix(60)) + "…" : oneLine
            let row = NSMenuItem(title: short, action: #selector(copyEntry(_:)), keyEquivalent: "")
            row.target = self
            row.tag = i
            row.toolTip = "\(time.string(from: entry.date))\n\n\(entry.text)"
            sub.addItem(row)
        }
        sub.addItem(.separator())
        sub.addItem(withTitle: "Clear History", action: #selector(clearHistory), keyEquivalent: "").target = self
    }

    @objc func copyEntry(_ sender: NSMenuItem) {
        let entries = History.load()
        guard entries.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entries[sender.tag].text, forType: .string)
        pill.flash("Copied")
    }

    @objc func addWord() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add to Dictionary"
        alert.informativeText = "Dictate will listen for this word. If it came out wrong before, add how it came out and it will be fixed every time."
        let (box, word, heard) = App.wordFields()
        alert.accessoryView = box
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = word
        if alert.runModal() == .alertFirstButtonReturn {
            Words.add(word: word.stringValue, heard: heard.stringValue)
            if !word.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { pill.flash("Added") }
        }
    }

    /// Two labeled fields, stacked: the right spelling, and how it came out.
    static func wordFields() -> (NSView, NSTextField, NSTextField) {
        let width: CGFloat = 300
        let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 104))
        func label(_ text: String, y: CGFloat) {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 0, y: y, width: width, height: 14)
            box.addSubview(l)
        }
        func field(_ placeholder: String, y: CGFloat) -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 0, y: y, width: width, height: 24))
            f.placeholderString = placeholder
            box.addSubview(f)
            return f
        }
        label("Write it like this", y: 88)
        let word = field("Nguyen", y: 60)
        label("It came out as (optional)", y: 34)
        let heard = field("Win", y: 6)
        word.nextKeyView = heard
        return (box, word, heard)
    }

    @objc func openWords() {
        if !FileManager.default.fileExists(atPath: Words.shared.path) { Words.save(Words.load()) }
        NSWorkspace.shared.open(Words.shared)
    }

    @objc func clearHistory() {
        History.save([])
    }

    func refreshIcon() {
        let (symbol, tip): (String, String) = {
            switch state {
            case .idle: return ("mic", "Hold Right Option, or Option+Space for long talks")
            case .recording:
                return ("mic.fill", handsFree ? "Listening… tap Option to finish" : "Listening… let go to finish")
            case .working: return ("ellipsis", "Writing…")
            }
        }()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        image?.isTemplate = state != .recording
        if state == .recording, let image {
            item.button?.image = image.tinted(.systemRed)
        } else {
            item.button?.image = image
        }
        item.button?.toolTip = tip
        statusLine.title = tip
    }

    @objc func setKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ElevenLabs API key"
        alert.informativeText = "Paste a key with Speech to Text access. It is stored in your Mac's Keychain only."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { Keychain.save(key) }
        }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("login item: \(error)")
        }
    }

    func askForAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: Hot keys

    /// Option+Space as a system hot key: the app swallows it, so no space lands in the text.
    func registerHandsFreeHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { delegate.optionSpace() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x44494354), id: 1)  // "DICT"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func optionSpace() {
        switch state {
        case .idle:
            handsFree = true
            optionTapArmed = false
            start()
            if state != .recording { handsFree = false }
        case .recording where !handsFree:
            // Right Option went down first and started hold-to-talk: switch to hands-free.
            handsFree = true
            optionTapArmed = false
            keyDown = false
            showListening()
            refreshIcon()
        case .recording:
            stop()
        case .working:
            break
        }
    }

    func flags(_ event: NSEvent) {
        let optionDown = event.modifierFlags.contains(.option)
        if handsFree {
            if !optionDown {
                optionTapArmed = true
            } else if optionTapArmed && (event.keyCode == leftOptionKeyCode || event.keyCode == rightOptionKeyCode) {
                stop()
            }
            return
        }
        guard event.keyCode == rightOptionKeyCode else { return }
        if optionDown && !keyDown {
            keyDown = true
            start()
        } else if !optionDown && keyDown {
            keyDown = false
            stop()
        }
    }

    // MARK: Recording

    func showListening() {
        pill.show(handsFree ? "Tap ⌥ to finish" : "Listening", recording: true)
    }

    func start() {
        guard state == .idle else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictate.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.isMeteringEnabled = true
            guard recorder?.record() == true else { return }
            startedAt = Date()
            state = .recording
            NSSound(named: "Tink")?.play()
            showListening()
            meter = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                guard let self, let rec = self.recorder else { return }
                rec.updateMeters()
                // -50 dB (quiet room) to 0 dB, eased so normal speech fills the bars.
                let db = CGFloat(rec.averagePower(forChannel: 0))
                let level = pow(max(0, min(1, (db + 50) / 50)), 1.6)
                self.pill.wave.push(0.1 + level * 0.9)
            }
        } catch {
            NSLog("record: \(error)")
        }
    }

    func stop() {
        guard state == .recording, let recorder else { return }
        recorder.stop()
        meter?.invalidate()
        handsFree = false
        keyDown = false
        let seconds = Date().timeIntervalSince(startedAt)
        guard seconds >= minSeconds else { state = .idle; pill.hide(); return }
        NSSound(named: "Pop")?.play()
        state = .working
        pill.show("Writing…", recording: false)
        let url = recorder.url
        Task {
            let list = Words.load()
            let text = await transcribe(url, keyterms: Words.keyterms(list)).map { Words.applyFixes($0, list) }
            await MainActor.run {
                if let text, !text.isEmpty {
                    self.type(text)
                    History.add(text)
                    self.pill.hide()
                } else {
                    self.pill.flash("Didn't catch that")
                }
                self.state = .idle
            }
        }
    }

    func transcribe(_ file: URL, keyterms: [String]) async -> String? {
        guard let key = Keychain.read(), let audio = try? Data(contentsOf: file) else { return nil }
        let boundary = "dictate-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model_id", "scribe_v2")
        field("tag_audio_events", "false")
        // One form field per term (a JSON array is rejected).
        for term in keyterms { field("keyterms", term) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictate.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        // Long hands-free talks take ElevenLabs a while; wait up to 10 minutes.
        var request = URLRequest(url: sttURL, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await URLSession.shared.upload(for: request, from: body)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                NSLog("stt: \(String(data: data, encoding: .utf8) ?? "")")
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("stt: \(error)")
            return nil
        }
    }

    // MARK: Typing

    /// Paste the text at the cursor, then put the old clipboard back.
    func type(_ text: String) {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { old -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for kind in old.types { if let data = old.data(forType: kind) { copy.setData(data, forType: kind) } }
            return copy
        } ?? []
        board.clearContents()
        board.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

// MARK: Design check

/// `Dictate --render <dir>` draws the pill in each state, light and dark, to PNGs.
func renderPills(to dir: String) {
    let states: [(String, String, Bool)] = [
        ("listening", "Listening", true),
        ("handsfree", "Tap ⌥ to finish", true),
        ("writing", "Writing…", false),
    ]
    for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        let appearance = NSAppearance(named: look)!
        for (state, text, recording) in states {
            appearance.performAsCurrentDrawingAppearance {
                let pill = Pill(renderOnly: true)
                let view = pill.panel.contentView!
                view.appearance = appearance
                view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                view.layer?.borderColor = NSColor.separatorColor.cgColor
                pill.label.stringValue = text
                pill.dot.isHidden = !recording
                pill.wave.idle = !recording
                pill.wave.levels = recording
                    ? [0.15, 0.3, 0.55, 0.8, 0.6, 0.4, 0.7, 0.95, 0.65, 0.35, 0.5, 0.75, 0.4, 0.2]
                    : pill.wave.levels.map { _ in 0.12 }
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                let png = rep.representation(using: .png, properties: [:])!
                try? png.write(to: URL(fileURLWithPath: "\(dir)/pill-\(state)-\(name).png"))
            }
        }
    }
}

func renderWordFields(to dir: String) {
    for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
        let appearance = NSAppearance(named: look)!
        appearance.performAsCurrentDrawingAppearance {
            let (box, _, _) = App.wordFields()
            box.appearance = appearance
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            let rep = box.bitmapImageRepForCachingDisplay(in: box.bounds)!
            box.cacheDisplay(in: box.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/add-word-\(name).png"))
        }
    }
}

/// `Dictate --fix-test <text>` runs the fix list on a sample, for checks without the mic.
let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > i + 1 {
    renderPills(to: CommandLine.arguments[i + 1])
    renderWordFields(to: CommandLine.arguments[i + 1])
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--fix-test"), CommandLine.arguments.count > i + 1 {
    let list = WordList(words: ["Nguyen"], fixes: [Fix(heard: "تحران", correct: "تهران"), Fix(heard: "win", correct: "Nguyen")])
    print(Words.applyFixes(CommandLine.arguments[i + 1], list))
    print(Words.keyterms(WordList(words: ["Kubernetes", "a [bad] one", "Kubernetes", "x y z w v u"], fixes: list.fixes)))
    exit(0)
}
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
