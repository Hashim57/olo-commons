import AppKit
import SwiftUI
import WebKit
import OloKit

/// What the built-in browser should open: a web address, or a page Olo built, run as a visitor
/// would see it (scripts on, the network on).
enum BrowserRequest: Equatable {
    case url(URL)
    case artifact(Artifact)
}

/// One line from the page's console, or an uncaught error.
struct ConsoleLine: Identifiable, Equatable {
    let id = UUID()
    let level: String
    let text: String
    let at = Date()
}

/// The built-in browser: Olo's own place to run and test a website, beside the conversation, the
/// way Claude previews what it builds. It runs on this Mac's WebKit, in the app's sandbox, with
/// its own cookies and storage that are thrown away when Olo quits (nothing is shared with Safari).
/// Built pages run with scripts and the network on; the console captures log, warn, error and
/// uncaught errors so a broken page says why; the width switch shows the page as a phone or a
/// tablet would.
@MainActor @Observable
final class BrowserController: NSObject, WKNavigationDelegate, WKUIDelegate {
    @ObservationIgnored let webView: WKWebView
    var address = ""
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var loading = false
    var progress = 0.0
    var console: [ConsoleLine] = []
    /// The page Olo built that is running now, for "Run again".
    var running: Artifact?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: BrowserController.consoleBridge, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        controller.add(ConsoleRelay(owner: self), name: "oloConsole")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] v, _ in Task { @MainActor in self?.progress = v.estimatedProgress } },
            webView.observe(\.isLoading) { [weak self] v, _ in Task { @MainActor in self?.loading = v.isLoading } },
            webView.observe(\.title) { [weak self] v, _ in Task { @MainActor in self?.title = v.title ?? "" } },
            webView.observe(\.canGoBack) { [weak self] v, _ in Task { @MainActor in self?.canGoBack = v.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] v, _ in Task { @MainActor in self?.canGoForward = v.canGoForward } },
            webView.observe(\.url) { [weak self] v, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let u = v.url, u.scheme == "http" || u.scheme == "https" { self.address = u.absoluteString }
                }
            },
        ]
    }

    /// Forwards console calls and uncaught errors to the app. Runs in every frame before the page's own scripts.
    static let consoleBridge = """
    (function () {
      if (window.__oloConsole) return; window.__oloConsole = true;
      var send = function (level, args) {
        try {
          var text = Array.prototype.map.call(args, function (a) {
            if (a instanceof Error) return a.name + ': ' + a.message;
            if (typeof a === 'object') { try { return JSON.stringify(a); } catch (e) { return String(a); } }
            return String(a);
          }).join(' ');
          window.webkit.messageHandlers.oloConsole.postMessage({ level: level, text: text.slice(0, 2000) });
        } catch (e) {}
      };
      ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
        var original = console[level];
        console[level] = function () { send(level, arguments); if (original) original.apply(console, arguments); };
      });
      window.addEventListener('error', function (e) {
        send('error', [(e.message || 'Error') + (e.filename ? ' (' + e.filename.split('/').pop() + ':' + e.lineno + ')' : '')]);
      });
      window.addEventListener('unhandledrejection', function (e) {
        send('error', ['Unhandled promise rejection: ' + (e.reason && e.reason.message ? e.reason.message : String(e.reason))]);
      });
    })();
    """

    func handle(_ request: BrowserRequest) {
        switch request {
        case .url(let u): open(u)
        case .artifact(let a): run(a)
        }
    }

    /// Opens what was typed: a full address, or a bare domain (https is added). Only web addresses.
    func go(_ typed: String) {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let u = URL(string: t), let s = u.scheme?.lowercased(), s == "http" || s == "https" { open(u); return }
        if !t.contains(" "), t.contains("."), let u = URL(string: "https://" + t) { open(u); return }
        // Anything else is a search, sent to a search page rather than guessed at.
        var c = URLComponents(string: "https://duckduckgo.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: t)]
        if let u = c.url { open(u) }
    }

    func open(_ url: URL) {
        running = nil
        console.removeAll()
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    /// Runs a page Olo built, with scripts and the network on, as it will behave once deployed.
    func run(_ artifact: Artifact) {
        running = artifact
        console.removeAll()
        address = ""
        title = artifact.title
        webView.loadHTMLString(ArtifactPreview.document(for: artifact), baseURL: nil)
    }

    func reload() {
        if let a = running { run(a) } else { webView.reload() }
    }

    func log(_ level: String, _ text: String) {
        console.append(ConsoleLine(level: level, text: text))
        if console.count > 500 { console.removeFirst(console.count - 500) }
    }

    // MARK: WKNavigationDelegate, WKUIDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("error", "The page did not finish loading: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("error", "The page could not be opened: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if ["http", "https", "about", "data", "blob"].contains(scheme) { return .allow }
        // mailto:, tel: and the like belong to other apps.
        NSWorkspace.shared.open(url)
        return .cancel
    }

    /// A link that asks for a new window opens here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url { webView.load(URLRequest(url: u)) }
        return nil
    }
}

/// Holds the controller weakly, so the content controller does not keep the browser alive.
private final class ConsoleRelay: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserController?
    init(owner: BrowserController) { self.owner = owner }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let level = body["level"] as? String ?? "log"
        let text = body["text"] as? String ?? ""
        Task { @MainActor in self.owner?.log(level, text) }
    }
}

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var browser = BrowserController()
    @State private var typed = ""
    @State private var showConsole = true
    @State private var width: PageWidth = .full
    @FocusState private var addressFocused: Bool

    enum PageWidth: String, CaseIterable, Identifiable {
        case full = "Full", tablet = "Tablet", phone = "Phone"
        var id: String { rawValue }
        var points: CGFloat? { self == .tablet ? 820 : self == .phone ? 390 : nil }
        var symbol: String { self == .full ? "desktopcomputer" : self == .tablet ? "ipad" : "iphone" }
    }

    private var errorCount: Int { browser.console.filter { $0.level == "error" }.count }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if browser.loading {
                ProgressView(value: browser.progress).progressViewStyle(.linear).frame(height: 2)
            } else {
                Divider()
            }
            page
            if showConsole {
                Divider()
                consolePane.frame(height: 150)
            }
        }
        .onAppear { take(model.browserRequest) }
        .onChange(of: model.browserRequest) { take(model.browserRequest) }
        .onChange(of: browser.address) { if !addressFocused { typed = browser.address } }
    }

    private func take(_ request: BrowserRequest?) {
        guard let request else { return }
        browser.handle(request)
        model.browserRequest = nil
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!browser.canGoBack).help("Back")
            Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!browser.canGoForward).help("Forward")
            Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help(browser.running == nil ? "Reload" : "Run the page again")
            if let a = browser.running {
                Label(a.suggestedFilename, systemImage: "hammer").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                    .help("A page Olo built, running with scripts and the network on")
            }
            TextField("Search or enter a web address", text: $typed)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit { browser.go(typed); addressFocused = false }
            Picker("Width", selection: $width) {
                ForEach(PageWidth.allCases) { w in Image(systemName: w.symbol).tag(w).help(w.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("See the page at desktop, tablet or phone width")
            Button { showConsole.toggle() } label: {
                Label(errorCount > 0 ? "\(errorCount)" : "Console", systemImage: errorCount > 0 ? "exclamationmark.triangle" : "terminal")
            }
            .foregroundStyle(errorCount > 0 ? Color.red : Color.primary)
            .help("Show or hide the page's console")
            Button {
                if let u = browser.webView.url, u.scheme == "http" || u.scheme == "https" { NSWorkspace.shared.open(u) }
            } label: { Image(systemName: "arrow.up.right.square") }
                .disabled(browser.running != nil || browser.webView.url == nil)
                .help("Open this page in your default browser")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    @ViewBuilder
    private var page: some View {
        if browser.webView.url == nil && browser.running == nil && !browser.loading {
            VStack(spacing: 10) {
                Image(systemName: "safari").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Olo's browser").font(.title3.weight(.semibold))
                Text("Run a page Olo built (the Run button on its card, or the browser button in the Olo Sample) to test it with scripts and the network on, at desktop, tablet or phone width, with its console below. Or type a web address above.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                if let a = model.sample, a.isPreviewable {
                    Button("Run \(a.suggestedFilename)") { browser.run(a) }.buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            BrowserWebView(webView: browser.webView)
                .frame(maxWidth: width.points ?? .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private var consolePane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Console").font(.caption.weight(.semibold))
                Text(browser.console.isEmpty ? "nothing logged" : "\(browser.console.count) lines, \(errorCount) errors")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(browser.console.map { "[\($0.level)] \($0.text)" }.joined(separator: "\n"), forType: .string)
                }
                .disabled(browser.console.isEmpty)
                Button("Clear") { browser.console.removeAll() }.disabled(browser.console.isEmpty)
            }
            .buttonStyle(.borderless).font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(browser.console) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: line.level == "error" ? "xmark.octagon" : line.level == "warn" ? "exclamationmark.triangle" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(line.level == "error" ? Color.red : line.level == "warn" ? Color.orange : Color.secondary)
                                Text(line.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(line.id)
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 6)
                }
                .onChange(of: browser.console.count) {
                    if let last = browser.console.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }
}

/// Hosts the controller's web view; the same view survives SwiftUI updates.
struct BrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
