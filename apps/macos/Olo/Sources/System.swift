import AppKit
import Carbon.HIToolbox
import Network
import Security

/// The session token lives in the macOS keychain, never in a plain file.
enum Keychain {
    private static let service = "io.helius-olo.desktop"

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Whether the Mac has a usable connection, from the system (no polling).
final class Connectivity: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "olo.connectivity", qos: .utility)
    var onChange: ((Bool) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { self?.onChange?(online) }
        }
        monitor.start(queue: queue)
    }
}

/// Option+Space from any app, through the Carbon hot key API: it needs no
/// Accessibility permission and works inside the App Store sandbox.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private(set) var registeredShortcut: String?

    func registerQuickAsk() {
        guard refs.isEmpty else { return }
        installHandler()
        // Option+Space, or Option+Shift+Space if another app already holds it.
        let candidates: [(UInt32, String)] = [(UInt32(optionKey), "\u{2325}Space"), (UInt32(optionKey | shiftKey), "\u{2325}\u{21E7}Space")]
        for (mods, label) in candidates {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4F4C_4F21), id: 1) // "OLO!"
            if RegisterEventHotKey(UInt32(kVK_Space), mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                registeredShortcut = label
                return
            }
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        registeredShortcut = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), oloHotKeyHandler, 1, &spec, nil, &handler)
    }

    fileprivate func fire(_ id: UInt32) {
        if id == 1 { QuickAskController.shared.toggle() }
    }
}

private func oloHotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ user: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hk = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    guard status == noErr else { return status }
    let id = hk.id
    DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) } }
    return noErr
}
