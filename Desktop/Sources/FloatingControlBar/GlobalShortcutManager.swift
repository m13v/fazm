import Carbon.HIToolbox.Events
import Cocoa

// MARK: - Global Shortcut Manager

/// Manages global keyboard shortcuts using Carbon APIs for the floating control bar.
class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()

    static let toggleFloatingBarNotification = Notification.Name("com.fazm.desktop.toggleFloatingBar")
    static let askAINotification = Notification.Name("com.fazm.desktop.askAI")
    static let newPopOutChatNotification = Notification.Name("com.fazm.desktop.newPopOutChat")

    private var hotKeyRefs: [HotKeyID: EventHotKeyRef] = [:]

    private enum HotKeyID: UInt32 {
        case toggleBar = 1
        case askFazm = 2
        case newPopOutChat = 3
    }

    private var shortcutObserver: NSObjectProtocol?
    private var popOutChatObserver: NSObjectProtocol?
    private var toggleBarObserver: NSObjectProtocol?

    private init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                return GlobalShortcutManager.shared.handleHotKeyEvent(event!)
            },
            1, &eventType, nil, nil
        )

        // Re-register Ask Fazm shortcut when user changes it in settings
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: ShortcutSettings.askFazmShortcutChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerAskFazm()
        }

        // Re-register New Pop-Out Chat shortcut when user changes it in settings
        popOutChatObserver = NotificationCenter.default.addObserver(
            forName: ShortcutSettings.newPopOutChatShortcutChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerNewPopOutChat()
        }

        // Re-register / unregister Toggle Floating Bar shortcut when toggled
        toggleBarObserver = NotificationCenter.default.addObserver(
            forName: ShortcutSettings.toggleBarShortcutChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerToggleBar()
        }
    }

    func registerShortcuts() {
        unregisterShortcuts()
        registerToggleBar()
        registerAskFazm()
        registerNewPopOutChat()
    }

    private func registerToggleBar() {
        if let ref = hotKeyRefs.removeValue(forKey: .toggleBar) {
            UnregisterEventHotKey(ref)
        }
        let enabled = MainActor.assumeIsolated { ShortcutSettings.shared.toggleBarShortcutEnabled }
        guard enabled else {
            NSLog("GlobalShortcutManager: Toggle Floating Bar shortcut disabled")
            return
        }
        // Cmd+\ (keycode 42 = backslash)
        registerHotKey(keyCode: 42, modifiers: Int(cmdKey), id: .toggleBar)
    }

    private func registerAskFazm() {
        // Unregister previous Ask Fazm hotkey if any
        if let ref = hotKeyRefs.removeValue(forKey: .askFazm) {
            UnregisterEventHotKey(ref)
        }
        let (enabled, askFazmKey) = MainActor.assumeIsolated {
            (ShortcutSettings.shared.askFazmShortcutEnabled, ShortcutSettings.shared.askFazmKey)
        }
        guard enabled else {
            NSLog("GlobalShortcutManager: Ask Fazm shortcut disabled")
            return
        }
        registerHotKey(keyCode: Int(askFazmKey.keyCode), modifiers: askFazmKey.carbonModifiers, id: .askFazm)
        NSLog("GlobalShortcutManager: Registered Ask Fazm shortcut: \(askFazmKey.rawValue)")
    }

    private func registerNewPopOutChat() {
        if let ref = hotKeyRefs.removeValue(forKey: .newPopOutChat) {
            UnregisterEventHotKey(ref)
        }
        let (enabled, popOutKey) = MainActor.assumeIsolated {
            (ShortcutSettings.shared.newPopOutChatShortcutEnabled, ShortcutSettings.shared.newPopOutChatKey)
        }
        guard enabled else {
            NSLog("GlobalShortcutManager: New Pop-Out Chat shortcut disabled")
            return
        }
        registerHotKey(keyCode: Int(popOutKey.keyCode), modifiers: popOutKey.carbonModifiers, id: .newPopOutChat)
        NSLog("GlobalShortcutManager: Registered New Pop-Out Chat shortcut: \(popOutKey.rawValue)")
    }

    private func registerHotKey(keyCode: Int, modifiers: Int, id: HotKeyID) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: FourCharCode(0x46415A4D), id: id.rawValue) // "FAZM"

        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )

        if status == noErr, let ref = hotKeyRef {
            hotKeyRefs[id] = ref
        } else {
            NSLog("GlobalShortcutManager: Failed to register hotkey (keycode \(keyCode)), error: \(status)")
        }
    }

    private func handleHotKeyEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            OSType(kEventParamDirectObject),
            OSType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr, let id = HotKeyID(rawValue: hotKeyID.id) else {
            return status
        }

        switch id {
        case .toggleBar:
            NSLog("GlobalShortcutManager: Cmd+\\ detected, toggling floating bar")
            NotificationCenter.default.post(name: GlobalShortcutManager.toggleFloatingBarNotification, object: nil)
        case .askFazm:
            NSLog("GlobalShortcutManager: Ask Fazm shortcut detected")
            DispatchQueue.main.async {
                FloatingControlBarManager.shared.openAIInput()
            }
        case .newPopOutChat:
            NSLog("GlobalShortcutManager: New Pop-Out Chat shortcut detected")
            NotificationCenter.default.post(name: GlobalShortcutManager.newPopOutChatNotification, object: nil)
        }

        return noErr
    }

    func unregisterShortcuts() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }
}
