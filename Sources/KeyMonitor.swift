import Cocoa

class KeyMonitor {
    var onFnKeyDown: (() -> Void)?
    var onFnKeyUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthCheckTimer: Timer?
    private var isRecordingToggle = false

    // F5 key — reliable on all macOS versions including Tahoe (26)
    private static let hotkeyCode: UInt16 = 96

    func start() -> Bool {
        // Listen for keyDown + keyUp (F5 is a regular key, not a modifier)
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            log("ERROR: Failed to create event tap. Is Accessibility permission granted?")
            Unmanaged<KeyMonitor>.fromOpaque(selfPtr).release()
            return false
        }

        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Health check: re-enable tap if macOS disables it
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                log("Event tap was disabled, re-enabling...")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }

        log("Key monitor started successfully (hotkey: F5)")
        return true
    }

    func stop() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // If the tap gets disabled, re-enable it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // Only handle our hotkey
        guard keyCode == KeyMonitor.hotkeyCode else {
            return Unmanaged.passRetained(event)
        }

        // Toggle mode: tap F5 to start, tap again to stop
        // Only act on keyDown, ignore keyUp and key repeats
        if type == .keyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat { return nil }

            isRecordingToggle.toggle()
            if isRecordingToggle {
                DispatchQueue.main.async { [weak self] in
                    self?.onFnKeyDown?()
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.onFnKeyUp?()
                }
            }
            return nil // Suppress the F5 keystroke
        } else if type == .keyUp {
            return nil // Suppress the F5 keystroke
        }

        return Unmanaged.passRetained(event)
    }
}
