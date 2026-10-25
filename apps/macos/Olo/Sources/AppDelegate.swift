import AppKit
import OloKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // "Ask Olo" in the Services menu of every app (selected text) and of Finder (files).
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        Task { @MainActor in
            if UserDefaults.standard.object(forKey: Prefs.hotKeyEnabled) as? Bool ?? true {
                HotKeyCenter.shared.registerQuickAsk()
            }
        }
    }

    /// Closing the window keeps Olo in the menu bar, ready for Option+Space.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Task { @MainActor in AppModel.shared.showMainWindow() } }
        return true
    }

    /// olo://ask?q=... and olo://chat/42
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let link = LinkPolicy.parse(url) else { continue }
            Task { @MainActor in
                switch link {
                case .ask(let q): QuickAskController.shared.show(question: q)
                case .conversation(let id): AppModel.shared.openServerConversation(id); AppModel.shared.showMainWindow()
                case .home: AppModel.shared.showMainWindow()
                }
            }
        }
    }
}

/// The Services menu entries declared in Info.plist (NSServices).
final class ServiceProvider: NSObject {
    @objc(askOlo:userData:error:)
    func askOlo(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let text = pboard.string(forType: .string) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "No text was selected." as NSString
            return
        }
        Task { @MainActor in
            QuickAskController.shared.show(attachments: [Attachment(kind: .selection, name: "Selected text", text: text)])
        }
    }

    @objc(askOloAboutFiles:userData:error:)
    func askOloAboutFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files were selected." as NSString
            return
        }
        Task.detached(priority: .userInitiated) {
            let attachments = urls.prefix(10).compactMap { FileExtractor.attachment(for: $0) }
            await MainActor.run {
                if attachments.isEmpty {
                    QuickAskController.shared.show(notice: "Olo could not read text from \(urls.count == 1 ? "that file" : "those files").")
                } else {
                    QuickAskController.shared.show(attachments: attachments)
                }
            }
        }
    }
}

enum Prefs {
    static let hotKeyEnabled = "hotKeyEnabled"
    static let askPendingWhenOnline = "askPendingWhenOnline"
    static let searchWebByDefault = "searchWebByDefault"
    static let useFoldersByDefault = "useFoldersByDefault"
    static let offlineOnly = "offlineOnly"
    /// Show contradicted, not covered and unchecked sentences in answers without pressing the button.
    static let showUnverified = "showUnverified"
    /// "Use my conversations to improve Olo and train Zeus": off until the person ticks it.
    static let trainingConsent = "trainingConsent"
}
