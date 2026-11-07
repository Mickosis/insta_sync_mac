import InstaSyncCore
import SwiftUI
import WebKit

/// The visible Instagram window: log in by hand once (or solve a security check). It uses
/// the same website data store as the hidden browser, so the login carries over.
struct InstagramWindow: View {
    private var model: AppModel { .shared }
    @Environment(\.dismissWindow) private var dismissWindow
    @ViewState private var reloadToken = 0
    /// Logged out when the window opened: close it by itself once the login completes.
    @ViewState private var closeOnLogin: Bool?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.isLoggedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                    .foregroundStyle(model.isLoggedIn ? .green : .orange)
                Text(model.isLoggedIn ? "Logged in. Insta Sync uses this login for lookups, out of sight."
                     : "Log in to Instagram. Insta Sync keeps the login in its own browser.")
                    .font(.callout)
                Spacer()
                Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
                if model.isLoggedIn {
                    Button("Log Out") { Task { await model.logOut(); reloadToken += 1 } }
                }
                Button("Done") { dismissWindow(id: "instagram") }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .padding(10)
            Divider()
            if !model.isLoggedIn {
                BrowserLoginBar { dismissWindow(id: "instagram") }
                Divider()
            }
            if closeOnLogin != nil {
                BrowserView(start: closeOnLogin == true ? InstagramSession.loginURL : InstagramSession.home,
                            reloadToken: reloadToken) {
                    Task { await loginChanged() }
                }
            } else {
                Spacer()
            }
        }
        .frame(minWidth: 760, minHeight: 640)
        .task {
            await model.refreshLogin()
            closeOnLogin = !model.isLoggedIn
        }
    }

    private func loginChanged() async {
        let was = model.isLoggedIn
        await model.refreshLogin()
        if !was && model.isLoggedIn {
            model.show("Logged in to Instagram")
            if closeOnLogin == true {
                try? await Task.sleep(for: .seconds(1.5))  // let Instagram finish setting its cookies
                dismissWindow(id: "instagram")
            }
        }
    }
}

struct BrowserView: NSViewRepresentable {
    let start: URL
    let reloadToken: Int
    let onCookiesChanged: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCookiesChanged) }

    func makeNSView(context: Context) -> WKWebView {
        let config = InstagramSession.makeConfiguration()
        BrowserLog.attach(to: config, coordinator: context.coordinator)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        #if DEBUG
        wv.isInspectable = true  // Safari → Develop → this Mac → Insta Sync (debug builds only)
        #endif
        InstagramSession.dataStore.httpCookieStore.add(context.coordinator)
        wv.load(URLRequest(url: start))
        context.coordinator.lastToken = reloadToken
        BrowserLog.write("open \(BrowserLog.clean(start) ?? "?")")
        context.coordinator.watch(wv)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.onChange = onCookiesChanged
        if context.coordinator.lastToken != reloadToken {
            context.coordinator.lastToken = reloadToken
            if wv.url == nil { wv.load(URLRequest(url: start)) } else { wv.reload() }
        }
    }

    static func dismantleNSView(_ wv: WKWebView, coordinator: Coordinator) {
        InstagramSession.dataStore.httpCookieStore.remove(coordinator)
        wv.configuration.userContentController.removeScriptMessageHandler(forName: BrowserLog.handlerName)
        wv.stopLoading()
        coordinator.closePopups()
        coordinator.stopWatching()
    }

    final class Coordinator: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var onChange: () -> Void
        var lastToken = 0
        /// Windows the login page opened (window.open), e.g. for a security step.
        private var popups: [(WKWebView, NSWindow)] = []

        init(_ onChange: @escaping () -> Void) { self.onChange = onChange }

        private var timer: Timer?
        private var lastSnapshot = ""

        /// While logged out, every few seconds log what the login page shows (buttons, links,
        /// frames), to see why a login stalls. Stops once logged in, so nothing from your
        /// feed or account is logged.
        func watch(_ wv: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self, weak wv] _ in
                Task { @MainActor in
                    guard let self, let wv else { return }
                    if await InstagramSession.loggedInUserID() != nil { return self.stopWatching() }
                    guard let s = try? await wv.evaluateJavaScript(BrowserLog.snapshotJS) as? String, s != self.lastSnapshot else { return }
                    self.lastSnapshot = s
                    BrowserLog.write("page now: \(s)")
                }
            }
        }

        func stopWatching() {
            timer?.invalidate()
            timer = nil
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            DispatchQueue.main.async { self.onChange() }
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            BrowserLog.write("page: \(message.body)")
        }

        // MARK: navigation (logged, to see where a login stalls)

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            BrowserLog.write("loaded \(BrowserLog.clean(webView.url) ?? "?")")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            BrowserLog.write("failed \(BrowserLog.clean(webView.url) ?? "?"): \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            BrowserLog.write("failed to start \(BrowserLog.clean(webView.url) ?? "?"): \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            BrowserLog.write("redirect \(BrowserLog.clean(webView.url) ?? "?")")
        }

        // MARK: popups and dialogs

        /// The page asked for a new window: open one (same login store) and keep the opener link.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            BrowserLog.write("popup \(BrowserLog.clean(action.request.url) ?? "(blank)")")
            let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: configuration)
            popup.navigationDelegate = self
            popup.uiDelegate = self
            #if DEBUG
            popup.isInspectable = true
            #endif
            let win = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                               backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.title = "Instagram"
            win.contentView = popup
            win.center()
            win.makeKeyAndOrderFront(nil)
            popups.append((popup, win))
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            BrowserLog.write("popup closed")
            if let i = popups.firstIndex(where: { $0.0 === webView }) {
                popups[i].1.orderOut(nil)
                popups.remove(at: i)
            }
        }

        func closePopups() {
            popups.forEach { $0.1.orderOut(nil) }
            popups = []
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
            BrowserLog.write("alert: \(message)")
            let a = NSAlert()
            a.messageText = message
            a.runModal()
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
            BrowserLog.write("confirm: \(message)")
            let a = NSAlert()
            a.messageText = message
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Cancel")
            completionHandler(a.runModal() == .alertFirstButtonReturn)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
            let a = NSAlert()
            a.messageText = prompt
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = defaultText ?? ""
            a.accessoryView = field
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Cancel")
            completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }
}

/// Log in with Safari or Chrome instead (passkeys and every two-factor method work there),
/// then copy that login into Insta Sync.
struct BrowserLoginBar: View {
    private var model: AppModel { .shared }
    let onDone: () -> Void
    @ViewState private var browser: BrowserLogin.Browser? =
        BrowserLogin.installed.first { $0.name != "Safari" } ?? BrowserLogin.installed.first
    @ViewState private var busy = false
    @ViewState private var message: String?
    @ViewState private var needsFullDiskAccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stuck on a passkey or security step? Log in with your browser instead: log in to instagram.com there, then import that login.")
                .font(.callout)
            HStack(spacing: 8) {
                Picker("Browser", selection: $browser) {
                    ForEach(BrowserLogin.installed) { b in
                        Text(b.name).tag(Optional(b))
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                Button("1. Open Instagram in \(browser?.name ?? "browser")") {
                    if let browser { BrowserLogin.openLogin(in: browser) }
                }
                .disabled(browser == nil)
                Button("2. Import Login") { Task { await importLogin() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(browser == nil || busy)
                if busy { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            if let message {
                HStack {
                    Text(message).font(.callout).foregroundStyle(.orange)
                    if needsFullDiskAccess {
                        Button("Open Full Disk Access Settings") { BrowserLogin.openFullDiskAccessSettings() }.controlSize(.small)
                    }
                }
            }
            Text(browser?.kind == .safari
                 ? "Safari: Insta Sync needs Full Disk Access to read Safari's instagram.com cookies."
                 : "macOS asks once to let Insta Sync use \(browser?.name ?? "the browser")'s Safe Storage key; click Allow. Only instagram.com cookies are read.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06))
    }

    private func importLogin() async {
        guard let browser else { return }
        busy = true
        message = nil
        needsFullDiskAccess = false
        defer { busy = false }
        do {
            _ = try await BrowserLogin.importLogin(from: browser)
            await model.refreshLogin()
            if model.isLoggedIn {
                model.show("Logged in to Instagram with \(browser.name)'s login")
                onDone()
            } else {
                message = "Copied, but the login looks incomplete. Log in again in \(browser.name), then import."
            }
        } catch {
            message = error.localizedDescription
            needsFullDiskAccess = browser.kind == .safari && message?.contains("Full Disk Access") == true
        }
    }
}

/// Troubleshooting log of the Instagram window: pages loaded, popups, page errors.
/// ~/Library/Application Support/Insta Sync/browser.log (no cookies or form contents).
enum BrowserLog {
    static let handlerName = "instaSyncLog"
    static let url = AppPaths.standard.base.appendingPathComponent("browser.log")

    static let captureJS = """
    (function () {
      var post = function (s) { try { window.webkit.messageHandlers.instaSyncLog.postMessage(String(s).slice(0, 500)); } catch (e) {} };
      var where = location.host + location.pathname;
      ['error', 'warn'].forEach(function (k) {
        var orig = console[k];
        console[k] = function () { post(k + ' @' + where + ': ' + [].map.call(arguments, String).join(' ')); return orig.apply(console, arguments); };
      });
      window.addEventListener('error', function (e) { post('error @' + where + ': ' + e.message); });
      window.addEventListener('unhandledrejection', function (e) { post('rejection @' + where + ': ' + (e.reason && (e.reason.name + ' ' + e.reason.message) || e.reason)); });
      var origOpen = window.open;
      window.open = function (u) { post('window.open ' + u); return origOpen.apply(window, arguments); };
    })();
    """

    static let snapshotJS = """
    (function () {
      var vis = function (e) { var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
      var txt = function (e) { return (e.innerText || e.getAttribute('aria-label') || e.value || '').trim().replace(/\\s+/g, ' ').slice(0, 60); };
      var clickable = [].slice.call(document.querySelectorAll('button, a, [role=button], [role=link], input[type=submit]'))
        .filter(vis).map(txt).filter(Boolean).slice(0, 30);
      var inputs = [].slice.call(document.querySelectorAll('input')).filter(vis).map(function (i) { return i.type + ':' + (i.name || i.getAttribute('aria-label') || ''); }).slice(0, 10);
      var frames = [].slice.call(document.querySelectorAll('iframe')).map(function (f) { return (f.src || 'about:blank').split('?')[0]; }).slice(0, 6);
      var heading = [].slice.call(document.querySelectorAll('h1, h2, [role=heading]')).filter(vis).map(txt).slice(0, 4);
      return JSON.stringify({at: location.host + location.pathname, h: heading, click: clickable, inputs: inputs, frames: frames, pk: typeof PublicKeyCredential});
    })();
    """

    static func attach(to config: WKWebViewConfiguration, coordinator: WKScriptMessageHandler) {
        config.userContentController.add(coordinator, name: handlerName)
        config.userContentController.addUserScript(
            WKUserScript(source: captureJS, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
    }

    /// A link for the log: scheme, host and path only (query strings can carry tokens).
    static func clean(_ url: URL?) -> String? {
        guard let url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.query = nil
        c.fragment = nil
        return c.string
    }

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep it small: past ~1 MB, keep only the newest half.
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 1_000_000,
           let old = try? Data(contentsOf: url) {
            try? old.suffix(size / 2).write(to: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

