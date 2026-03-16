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
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code 9 = 'v'
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(9), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(9), keyDown: false) else {
            NSLog("CustomWispr: Failed to create CGEvent for paste")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
