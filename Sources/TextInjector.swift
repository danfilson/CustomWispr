import Cocoa
import Carbon.HIToolbox

class TextInjector {
    func inject(text: String) {
        let pasteboard = NSPasteboard.general

        log("Injecting text: \(text.prefix(100))...")

        // Save current clipboard contents
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
            guard let type = item.types.first,
                  let data = item.data(forType: type) else { return nil }
            return (type.rawValue, data)
        } ?? []

        // Write our text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Delay to ensure clipboard is ready
        usleep(100_000) // 100ms

        // Simulate Cmd+V
        simulatePaste()

        // Restore clipboard after a longer delay to ensure paste completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            pasteboard.clearContents()
            for (typeRaw, data) in savedItems {
                let type = NSPasteboard.PasteboardType(typeRaw)
                pasteboard.setData(data, forType: type)
            }
        }
    }

    private func simulatePaste() {
        // Try CGEvent first; fall back to AppleScript if it fails (broken on macOS 26 Tahoe)
        if !simulatePasteCGEvent() {
            log("CGEvent paste failed, falling back to AppleScript")
            simulatePasteAppleScript()
        }
    }

    private func simulatePasteCGEvent() -> Bool {
        guard AXIsProcessTrusted() else {
            log("CGEvent paste skipped — Accessibility not trusted")
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(9), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(9), keyDown: false) else {
            log("ERROR: Failed to create CGEvent for paste")
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        log("CGEvent Cmd+V posted")
        return true
    }

    private func simulatePasteAppleScript() {
        let src = """
            tell application "System Events"
                keystroke "v" using command down
            end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&error)
        if let err = error {
            log("AppleScript paste error: \(err)")
        } else {
            log("AppleScript Cmd+V executed")
        }
    }
}
