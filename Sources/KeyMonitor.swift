import Cocoa
import Carbon

class KeyMonitor {
    var onFnKeyDown: (() -> Void)?
    var onFnKeyUp: (() -> Void)?
    /// F6: open the feedback window for the last dictation.
    var onFeedbackKey: (() -> Void)?
    var isRecordingToggle = false

    private var hotKeyRef: EventHotKeyRef?
    private var feedbackHotKeyRef: EventHotKeyRef?
    private var altHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    // F5 = kVK_F5 = 0x60 = 96; F6 = kVK_F6 = 0x61
    private static let hotKeyCode: UInt32 = 0x60
    private static let feedbackKeyCode: UInt32 = 0x61
    // ⌘⌥Space: second record toggle for the built-in MacBook keyboard, where the top row
    // sends media functions and fn+F5 does not reach us. Needs "Show Finder search window"
    // (System Settings → Keyboard → Keyboard Shortcuts → Spotlight) unticked, or macOS eats it.
    private static let altKeyCode: UInt32 = 0x31   // kVK_Space
    private static let altModifiers: UInt32 = UInt32(cmdKey | optionKey)
    private static let hotKeySignature: FourCharCode = 0x43575052 // 'CWPR'

    func start() -> Bool {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        let handlerProc: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let ptr = userData else { return noErr }
            let monitor = Unmanaged<KeyMonitor>.fromOpaque(ptr).takeUnretainedValue()
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            if status == noErr, pressed.id == 2 {
                monitor.handleFeedbackKeyPress()
            } else {
                monitor.handleHotKeyPress(via: status == noErr && pressed.id == 3 ? "⌘⌥Space" : "F5")
            }
            return noErr
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handlerProc,
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            log("ERROR: Failed to install Carbon event handler: \(installStatus)")
            Unmanaged<KeyMonitor>.fromOpaque(selfPtr).release()
            return false
        }

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = KeyMonitor.hotKeySignature
        hotKeyID.id = 1

        let registerStatus = RegisterEventHotKey(
            KeyMonitor.hotKeyCode,
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus == noErr {
            log("Key monitor started successfully (F5 trigger)")
            var feedbackID = EventHotKeyID()
            feedbackID.signature = KeyMonitor.hotKeySignature
            feedbackID.id = 2
            let fbStatus = RegisterEventHotKey(KeyMonitor.feedbackKeyCode, 0, feedbackID,
                                               GetApplicationEventTarget(), 0, &feedbackHotKeyRef)
            if fbStatus == noErr {
                log("Feedback hot key registered (F6)")
            } else {
                log("WARNING: Failed to register F6 feedback hot key: \(fbStatus) (menu item still works)")
            }
            var altID = EventHotKeyID()
            altID.signature = KeyMonitor.hotKeySignature
            altID.id = 3
            let altStatus = RegisterEventHotKey(KeyMonitor.altKeyCode, KeyMonitor.altModifiers, altID,
                                                GetApplicationEventTarget(), 0, &altHotKeyRef)
            if altStatus == noErr {
                log("Alternate record hot key registered (⌘⌥Space)")
            } else {
                log("WARNING: Failed to register ⌘⌥Space hot key: \(altStatus)")
            }
            return true
        } else {
            log("ERROR: Failed to register hot key: \(registerStatus)")
            if let ref = eventHandlerRef { RemoveEventHandler(ref) }
            eventHandlerRef = nil
            Unmanaged<KeyMonitor>.fromOpaque(selfPtr).release()
            return false
        }
    }

    private func handleHotKeyPress(via key: String) {
        isRecordingToggle.toggle()
        if isRecordingToggle {
            log("\(key) pressed — starting recording")
            DispatchQueue.main.async { [weak self] in self?.onFnKeyDown?() }
        } else {
            log("\(key) pressed — stopping recording")
            DispatchQueue.main.async { [weak self] in self?.onFnKeyUp?() }
        }
    }

    private func handleFeedbackKeyPress() {
        log("F6 pressed — opening feedback")
        DispatchQueue.main.async { [weak self] in self?.onFeedbackKey?() }
    }

    func stop() {
        if let ref = altHotKeyRef {
            UnregisterEventHotKey(ref)
            altHotKeyRef = nil
        }
        if let ref = feedbackHotKeyRef {
            UnregisterEventHotKey(ref)
            feedbackHotKeyRef = nil
        }
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }
}
