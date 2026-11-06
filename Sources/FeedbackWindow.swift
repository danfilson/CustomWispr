import Cocoa

/// F6 / menu: lets Daniel annotate a recent dictation (what went wrong, free-text notes,
/// optionally the text he actually wanted). Saved onto the history entry; read by the
/// monthly health check and promoted into the A/B set by the harness. Nothing here
/// leaves the machine.
final class FeedbackWindow: NSObject, NSWindowDelegate {
    static let tags: [(key: String, title: String)] = [
        ("wrong-words", "Wrong words / names"),
        ("dropped-content", "Dropped something I said"),
        ("over-cleaned", "Over-cleaned / changed meaning"),
        ("under-cleaned", "Under-cleaned / fillers left"),
        ("choppy", "Choppy / bad stitching"),
        ("slow", "Too slow"),
        ("hung", "Hung or lost the dictation"),
        ("punctuation", "Punctuation / formatting"),
    ]

    private var window: NSWindow?
    private var entries: [HistoryEntry] = []
    private var picker: NSPopUpButton!
    private var metaLabel: NSTextField!
    private var outputView: NSTextView!
    private var checkboxes: [NSButton] = []
    private var notesView: NSTextView!
    private var correctedView: NSTextView!

    func show() {
        entries = Array(HistoryManager.shared.entries.prefix(8))
        guard !entries.isEmpty else {
            log("Feedback requested but history is empty")
            return
        }
        if window == nil { build() }
        picker.removeAllItems()
        let df = DateFormatter(); df.dateFormat = "HH:mm"
        for e in entries {
            let preview = e.cleanedText.replacingOccurrences(of: "\n", with: " ")
            let short = preview.count > 70 ? String(preview.prefix(70)) + "…" : preview
            let flag = e.feedback != nil ? " ✎" : ""
            picker.addItem(withTitle: "\(df.string(from: e.timestamp)) · \(e.style ?? "?")\(flag) · \(short)")
        }
        picker.selectItem(at: 0)
        for cb in checkboxes { cb.state = .off }
        notesView.string = ""
        correctedView.string = ""
        entryChanged()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(notesView)
    }

    // MARK: - Layout

    private let W: CGFloat = 640
    private let H: CGFloat = 660

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Dictation feedback"
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.delegate = self
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        win.contentView = v

        func y(_ top: CGFloat, _ h: CGFloat) -> CGFloat { H - top - h }
        func label(_ text: String, top: CGFloat, bold: Bool = false, small: Bool = false) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = small ? NSFont.systemFont(ofSize: 11) : (bold ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13))
            if small { l.textColor = .secondaryLabelColor }
            l.frame = NSRect(x: 20, y: y(top, 18), width: W - 40, height: 18)
            v.addSubview(l)
            return l
        }
        func textArea(top: CGFloat, height: CGFloat, editable: Bool) -> NSTextView {
            let scroll = NSScrollView(frame: NSRect(x: 20, y: y(top, height), width: W - 40, height: height))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let tv = NSTextView(frame: scroll.bounds)
            tv.isEditable = editable
            tv.isRichText = false
            tv.font = NSFont.systemFont(ofSize: 13)
            tv.textContainerInset = NSSize(width: 4, height: 4)
            tv.autoresizingMask = [.width]
            tv.isVerticallyResizable = true
            tv.textContainer?.widthTracksTextView = true
            if !editable { tv.backgroundColor = .windowBackgroundColor }
            scroll.documentView = tv
            v.addSubview(scroll)
            return tv
        }

        label("Dictation", top: 20, bold: true)
        picker = NSPopUpButton(frame: NSRect(x: 110, y: y(16, 26), width: W - 130, height: 26), pullsDown: false)
        picker.target = self
        picker.action = #selector(entryChanged)
        v.addSubview(picker)

        metaLabel = label("", top: 50, small: true)
        outputView = textArea(top: 72, height: 110, editable: false)

        label("What went wrong? (tick any)", top: 194, bold: true)
        let colW = (W - 40) / 2
        for (i, tag) in FeedbackWindow.tags.enumerated() {
            let cb = NSButton(checkboxWithTitle: tag.title, target: nil, action: nil)
            let col = CGFloat(i % 2), row = CGFloat(i / 2)
            cb.frame = NSRect(x: 20 + col * colW, y: y(218 + row * 24, 20), width: colW, height: 20)
            cb.identifier = NSUserInterfaceItemIdentifier(tag.key)
            v.addSubview(cb)
            checkboxes.append(cb)
        }

        label("Notes — choppy, slow, lost, what it should have said, anything", top: 322, bold: true)
        notesView = textArea(top: 344, height: 110, editable: true)

        label("Corrected text (optional) — what you actually wanted pasted", top: 466, bold: true)
        let pasteBtn = NSButton(title: "Paste from clipboard", target: self, action: #selector(pasteCorrected))
        pasteBtn.bezelStyle = .rounded
        pasteBtn.controlSize = .small
        pasteBtn.font = NSFont.systemFont(ofSize: 11)
        pasteBtn.frame = NSRect(x: W - 20 - 150, y: y(462, 24), width: 150, height: 24)
        v.addSubview(pasteBtn)
        correctedView = textArea(top: 490, height: 100, editable: true)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: W - 20 - 200, y: 16, width: 90, height: 32)
        v.addSubview(cancel)

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = [.command]
        save.frame = NSRect(x: W - 20 - 100, y: 16, width: 100, height: 32)
        v.addSubview(save)

        let hint = NSTextField(labelWithString: "⌘↩ saves · esc cancels · F6 reopens")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 20, y: 22, width: 300, height: 18)
        v.addSubview(hint)

        window = win
    }

    // MARK: - Actions

    @objc private func entryChanged() {
        let i = picker.indexOfSelectedItem
        guard i >= 0, i < entries.count else { return }
        let e = entries[i]
        outputView.string = e.cleanedText
        var bits: [String] = []
        if let m = e.meta {
            if let app = m.app { bits.append(app.components(separatedBy: ".").last ?? app) }
            if let model = m.model { bits.append(model) } else if m.cleanupMode != nil { bits.append("no LLM") }
            if let c = m.chunks { bits.append("\(c) chunk\(c == 1 ? "" : "s")") }
            if let r = m.recordingSec { bits.append(String(format: "spoke %.0fs", r)) }
            if let t = m.totalSec { bits.append(String(format: "processed %.1fs", t)) }
            if let w = m.whisperWaitSec, let c = m.cleanupSec {
                bits.append(String(format: "(whisper %.1fs, cleanup %.1fs)", w, c))
            }
            if let wu = m.warmUp { bits.append("warm-up \(wu)") }
            if let c = m.costUSD { bits.append(String(format: "$%.4f%@", c, (m.cachedTokens ?? 0) > 0 ? " cached" : "")) }
            if let f = m.fallbackReason { bits.append("⚠ \(f)") }
        } else {
            bits.append("no pipeline metadata (recorded before 2026-11-06)")
        }
        if let raw = e.rawText { bits.append("raw \(raw.count) → \(e.cleanedText.count) chars") }
        metaLabel.stringValue = bits.joined(separator: " · ")
        if let fb = e.feedback {
            for cb in checkboxes { cb.state = fb.tags.contains(cb.identifier?.rawValue ?? "") ? .on : .off }
            notesView.string = fb.note
            correctedView.string = fb.correctedText ?? ""
        }
    }

    @objc private func pasteCorrected() {
        if let s = NSPasteboard.general.string(forType: .string) { correctedView.string = s }
    }

    @objc private func cancel() { window?.orderOut(nil) }

    @objc private func save() {
        let i = picker.indexOfSelectedItem
        guard i >= 0, i < entries.count else { return }
        let entry = entries[i]
        let tags = checkboxes.filter { $0.state == .on }.compactMap { $0.identifier?.rawValue }
        let note = notesView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = correctedView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tags.isEmpty || !note.isEmpty || !corrected.isEmpty else {
            NSSound.beep()
            return
        }
        let fb = DictationFeedback(timestamp: Date(), tags: tags, note: note,
                                   correctedText: corrected.isEmpty ? nil : corrected)
        let ok = HistoryManager.shared.setFeedback(id: entry.id, feedback: fb)
        // Tags are categories, not content; the note itself never goes to the log.
        log("Feedback \(ok ? "saved" : "FAILED") for dictation \(entry.id.uuidString.prefix(8)): tags [\(tags.joined(separator: ", "))], note \(note.count) chars, corrected \(corrected.isEmpty ? "no" : "yes")")
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
