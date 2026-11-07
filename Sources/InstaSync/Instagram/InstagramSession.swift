import AppKit
import WebKit

/// Insta Sync's own browser for instagram.com.
///
/// Every web view uses the app's persistent website data store, so the login you do once
/// in the Instagram window (cookies) is what the hidden web view uses for lookups. The
/// hidden web view lives in an invisible, off-screen window: never shown, never in the
/// Window menu, Mission Control or Cmd-Tab, but still a real rendered page (a web view
/// without a window gets throttled and doesn't load images properly).
@MainActor
final class InstagramSession: NSObject, WKNavigationDelegate {
    static let shared = InstagramSession()

    nonisolated static let home = URL(string: "https://www.instagram.com/")!
    nonisolated static let loginURL = URL(string: "https://www.instagram.com/accounts/login/")!

    static var dataStore: WKWebsiteDataStore { .default() }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        // Instagram serves a degraded page to browsers it doesn't recognise.
        c.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        c.preferences.inactiveSchedulingPolicy = .none  // keep running while hidden
        c.mediaTypesRequiringUserActionForPlayback = .all
        c.userContentController.addUserScript(
            WKUserScript(source: noPasskeysJS, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        return c
    }

    /// Passkeys only work in apps Apple has given its web-browser entitlement, so in Insta
    /// Sync's browser a passkey prompt would spin forever. Answer every passkey request the
    /// way a person pressing Cancel would, and say this device has no built-in authenticator,
    /// so Instagram offers its other ways to confirm it's you (password, code).
    static let noPasskeysJS = """
    (function () {
      var log = function (s) { try { window.webkit.messageHandlers.instaSyncLog.postMessage(s); } catch (e) {} };
      var P = window.PublicKeyCredential;
      if (P) {
        try { P.isUserVerifyingPlatformAuthenticatorAvailable = function () { return Promise.resolve(false); }; } catch (e) {}
        try { P.isConditionalMediationAvailable = function () { return Promise.resolve(false); }; } catch (e) {}
        try { P.getClientCapabilities = function () { return Promise.resolve({}); }; } catch (e) {}
      }
      var C = window.CredentialsContainer && CredentialsContainer.prototype;
      if (!C) return;
      ['get', 'create'].forEach(function (name) {
        var orig = C[name];
        if (!orig) return;
        try {
          Object.defineProperty(C, name, {configurable: true, writable: true, value: function (o) {
            if (!(o && o.publicKey)) return orig.apply(this, arguments);
            log('passkey ' + name + ' requested @' + location.host + location.pathname + (o.mediation ? ' mediation=' + o.mediation : '') + ': answered as cancelled');
            if (o.mediation === 'conditional') return new Promise(function () {});  // autofill passkeys: never offered
            return new Promise(function (_, reject) {
              setTimeout(function () { reject(new DOMException('The operation either timed out or was not allowed.', 'NotAllowedError')); }, 400);
            });
          }});
        } catch (e) {}
      });
    })();
    """

    private var webView: WKWebView?
    private var window: NSWindow?
    private var navWaiters: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool { webView != nil }

    /// The hidden web view, created on first use.
    private func view() -> WKWebView {
        if let w = webView { return w }
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 900)
        let wv = WKWebView(frame: rect, configuration: Self.makeConfiguration())
        wv.navigationDelegate = self
        let win = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.alphaValue = 0
        win.ignoresMouseEvents = true
        win.hasShadow = false
        win.isExcludedFromWindowsMenu = true
        win.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        win.level = .init(rawValue: NSWindow.Level.normal.rawValue - 1)
        win.contentView = wv
        // Far outside every screen. Borderless windows aren't pulled back on screen.
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.orderBack(nil)
        webView = wv
        window = win
        return wv
    }

    /// Close the hidden web view (after a batch of work).
    func close() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        webView = nil
        finishNavigation()
    }

    // MARK: - navigation

    /// Load a page and wait until it has loaded (or failed, or `timeout` seconds passed).
    func load(_ url: URL, timeout: TimeInterval = 20) async {
        let wv = view()
        finishNavigation()
        let nav = wv.load(URLRequest(url: url))
        currentNav = nav
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            navWaiters.append(c)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if self?.currentNav === nav { self?.finishNavigation() }
            }
        }
    }

    private var currentNav: WKNavigation?

    private func finishNavigation() {
        currentNav = nil
        let waiters = navWaiters
        navWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func navigationEnded(_ nav: WKNavigation?) {
        // Ignore late events from an earlier page load that was replaced.
        if let nav, nav === currentNav { finishNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { navigationEnded(navigation) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { navigationEnded(navigation) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { navigationEnded(navigation) }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { close() }
    }

    var currentURL: URL? { webView?.url }

    /// Make sure the hidden page is on www.instagram.com (for same-origin API requests).
    func ensureOnInstagram() async {
        if let u = webView?.url, u.host == "www.instagram.com" { return }
        await load(Self.home)
    }

    // MARK: - JavaScript

    /// Run an async JavaScript function body in the page (`return` gives the result).
    func eval(_ body: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await view().callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
    }

    // MARK: - cookies

    static func cookies() async -> [HTTPCookie] {
        await dataStore.httpCookieStore.allCookies().filter { $0.domain.hasSuffix("instagram.com") }
    }

    /// Your Instagram user id, from the session cookie; nil when logged out.
    static func loggedInUserID() async -> String? {
        let cs = await cookies()
        guard cs.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }) else { return nil }
        return cs.first { $0.name == "ds_user_id" && !$0.value.isEmpty }?.value
    }

    /// Forget the Instagram login (cookies and site data in Insta Sync's own store).
    static func logOut() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types)
        let ig = records.filter { $0.displayName.contains("instagram") }
        await dataStore.removeData(ofTypes: types, for: ig)
        for c in await cookies() { await dataStore.httpCookieStore.deleteCookie(c) }
        shared.close()
    }
}
