import AppKit
import CommonCrypto
import Foundation
import Security
import SQLite3
import WebKit

/// "Log in with your browser": you log in to instagram.com in Safari or Chrome (where
/// passkeys and every two-factor method work), then Insta Sync copies that browser's
/// instagram.com cookies into its own browser storage. Only instagram.com cookies are read.
enum BrowserLogin {
    struct Browser: Identifiable, Hashable {
        enum Kind: Hashable { case safari, chromium(dir: String, keychainService: String) }
        let name: String
        let bundleID: String
        let kind: Kind
        var id: String { bundleID }

        var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
        var icon: NSImage? { appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } }
    }

    static let all: [Browser] = [
        Browser(name: "Safari", bundleID: "com.apple.Safari", kind: .safari),
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome",
                kind: .chromium(dir: "Google/Chrome", keychainService: "Chrome Safe Storage")),
        Browser(name: "Brave", bundleID: "com.brave.Browser",
                kind: .chromium(dir: "BraveSoftware/Brave-Browser", keychainService: "Brave Safe Storage")),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac",
                kind: .chromium(dir: "Microsoft Edge", keychainService: "Microsoft Edge Safe Storage")),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser",
                kind: .chromium(dir: "Arc/User Data", keychainService: "Arc Safe Storage")),
        Browser(name: "Chromium", bundleID: "org.chromium.Chromium",
                kind: .chromium(dir: "Chromium", keychainService: "Chromium Safe Storage")),
    ]

    static var installed: [Browser] { all.filter { $0.appURL != nil } }

    struct Fail: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Open the Instagram login page in that browser.
    static func openLogin(in browser: Browser) {
        guard let app = browser.appURL else { return }
        NSWorkspace.shared.open([InstagramSession.loginURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Copy the browser's instagram.com login into Insta Sync's browser. Returns the number of cookies copied.
    @MainActor
    static func importLogin(from browser: Browser) async throws -> Int {
        let cookies: [HTTPCookie] = try await Task.detached(priority: .userInitiated) {
            switch browser.kind {
            case .safari: return try safariCookies()
            case .chromium(let dir, let service): return try chromiumCookies(dir: dir, keychainService: service, browser: browser.name)
            }
        }.value
        guard cookies.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }) else {
            throw Fail(message: "\(browser.name) isn't logged in to Instagram. Log in at instagram.com in \(browser.name), then try again.")
        }
        let store = InstagramSession.dataStore.httpCookieStore
        for old in await InstagramSession.cookies() { await store.deleteCookie(old) }
        for c in cookies { await store.setCookie(c) }
        InstagramSession.shared.close()  // the hidden browser picks up the new login next time
        return cookies.count
    }

    // MARK: - Safari

    static var safariCookieFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    /// Parse Safari's Cookies.binarycookies (instagram.com cookies only).
    static func safariCookies() throws -> [HTTPCookie] {
        let data: Data
        do { data = try Data(contentsOf: safariCookieFile) } catch {
            throw Fail(message: "Insta Sync can't read Safari's cookies. Give it Full Disk Access in System Settings → Privacy & Security → Full Disk Access, then try again.")
        }
        let b = [UInt8](data)
        func be32(_ o: Int) -> Int { o + 4 <= b.count ? Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) : 0 }
        func le32(_ o: Int) -> Int { o + 4 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 : 0 }
        func leDouble(_ o: Int) -> Double {
            guard o + 8 <= b.count else { return 0 }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * UInt64(i)) }
            return Double(bitPattern: v)
        }
        func cString(_ o: Int, end: Int) -> String {
            guard o >= 0, o < end else { return "" }
            var e = o
            while e < end && b[e] != 0 { e += 1 }
            return String(decoding: b[o..<e], as: UTF8.self)
        }
        guard b.count > 8, b[0] == 0x63, b[1] == 0x6F, b[2] == 0x6F, b[3] == 0x6B else {  // "cook"
            throw Fail(message: "Safari's cookie file isn't in the expected format.")
        }
        let pages = be32(4)
        var sizes: [Int] = []
        for i in 0..<pages { sizes.append(be32(8 + 4 * i)) }
        var pageStart = 8 + 4 * pages
        var out: [HTTPCookie] = []
        for size in sizes {
            defer { pageStart += size }
            let pageEnd = min(pageStart + size, b.count)
            let n = le32(pageStart + 4)
            for i in 0..<n {
                let c = pageStart + le32(pageStart + 8 + 4 * i)
                let cSize = le32(c)
                let cEnd = min(c + cSize, pageEnd)
                guard cSize > 56, cEnd <= pageEnd else { continue }
                let flags = le32(c + 8)
                let domain = cString(c + le32(c + 16), end: cEnd)
                guard domain.hasSuffix("instagram.com") else { continue }
                let name = cString(c + le32(c + 20), end: cEnd)
                let path = cString(c + le32(c + 24), end: cEnd)
                let value = cString(c + le32(c + 28), end: cEnd)
                let expires = Date(timeIntervalSinceReferenceDate: leDouble(c + 40))
                if let cookie = makeCookie(domain: domain, name: name, value: value, path: path, expires: expires,
                                           secure: flags & 1 != 0, httpOnly: flags & 4 != 0) {
                    out.append(cookie)
                }
            }
        }
        return out
    }

    // MARK: - Chrome and friends

    static func chromiumCookies(dir: String, keychainService: String, browser: String) throws -> [HTTPCookie] {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(dir)")
        let profiles = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
        let dbs = profiles.flatMap { p in
            ["Cookies", "Network/Cookies"].map { base.appendingPathComponent(p).appendingPathComponent($0) }
        }.filter { fm.fileExists(atPath: $0.path) }
        if dbs.isEmpty { throw Fail(message: "No \(browser) profile found.") }

        let key = try chromiumKey(service: keychainService, browser: browser)
        // The profile whose Instagram session expires last is the one most recently logged in.
        var best: [HTTPCookie] = []
        var bestExpiry = Date.distantPast
        for db in dbs {
            let cookies = (try? readChromiumDB(db, key: key)) ?? []
            if let s = cookies.first(where: { $0.name == "sessionid" && !$0.value.isEmpty }),
               (s.expiresDate ?? .distantFuture) > bestExpiry {
                best = cookies
                bestExpiry = s.expiresDate ?? .distantFuture
            }
        }
        return best
    }

    /// The AES key Chrome encrypts cookies with, derived from its "Safe Storage" keychain password.
    /// macOS asks once whether Insta Sync may use it.
    static func chromiumKey(service: String, browser: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let password = item as? Data else {
            throw Fail(message: status == errSecUserCanceled || status == errSecAuthFailed
                       ? "Insta Sync needs to use “\(service)” to read \(browser)'s Instagram login. Try again and click Allow."
                       : "Couldn't read \(browser)'s “\(service)” key (error \(status)).")
        }
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let rc = key.withUnsafeMutableBytes { k in
            password.withUnsafeBytes { p in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     k.baseAddress?.assumingMemoryBound(to: UInt8.self), 16)
            }
        }
        guard rc == kCCSuccess else { throw Fail(message: "Couldn't derive \(browser)'s cookie key.") }
        return key
    }

    static func readChromiumDB(_ url: URL, key: Data) throws -> [HTTPCookie] {
        // The browser keeps the database open, so read a copy (with its write-ahead log).
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("instasync-cookies-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let copy = tmp.appendingPathComponent("Cookies")
        try fm.copyItem(at: url, to: copy)
        for ext in ["-wal", "-journal"] {
            let side = URL(fileURLWithPath: url.path + ext)
            if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + ext)) }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw Fail(message: "Couldn't open the cookie database.") }
        defer { sqlite3_close(db) }

        var version = 0
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW {
            version = Int(String(cString: sqlite3_column_text(st, 0))) ?? 0
        }
        sqlite3_finalize(st)

        let sql = """
        SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly
        FROM cookies WHERE host_key = 'instagram.com' OR host_key LIKE '%.instagram.com'
        """
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw Fail(message: "Unexpected cookie database.") }
        defer { sqlite3_finalize(st) }
        var out: [HTTPCookie] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let host = String(cString: sqlite3_column_text(st, 0))
            let name = String(cString: sqlite3_column_text(st, 1))
            var value = String(cString: sqlite3_column_text(st, 2))
            if value.isEmpty, let blob = sqlite3_column_blob(st, 3) {
                let enc = Data(bytes: blob, count: Int(sqlite3_column_bytes(st, 3)))
                guard let plain = decryptChromium(enc, key: key) else { continue }
                // Since database version 24, the value starts with a SHA-256 of the domain.
                let body = version >= 24 && plain.count >= 32 ? plain.dropFirst(32) : plain[...]
                value = String(decoding: body, as: UTF8.self)
            }
            let path = String(cString: sqlite3_column_text(st, 4))
            let expiresUTC = sqlite3_column_int64(st, 5)  // microseconds since 1601-01-01
            let expires = expiresUTC > 0 ? Date(timeIntervalSince1970: Double(expiresUTC) / 1_000_000 - 11_644_473_600) : nil
            if let c = makeCookie(domain: host, name: name, value: value, path: path, expires: expires,
                                  secure: sqlite3_column_int(st, 6) != 0, httpOnly: sqlite3_column_int(st, 7) != 0) {
                out.append(c)
            }
        }
        return out
    }

    /// "v10" + AES-128-CBC (IV of 16 spaces, PKCS#7 padding).
    static func decryptChromium(_ data: Data, key: Data) -> Data? {
        guard data.count > 3, data.prefix(3) == Data("v10".utf8) else { return nil }
        let body = data.dropFirst(3)
        let iv = Data(repeating: 0x20, count: 16)
        var out = Data(count: body.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let rc = out.withUnsafeMutableBytes { o in
            body.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress, i.baseAddress, body.count,
                                o.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard rc == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    static func makeCookie(domain: String, name: String, value: String, path: String, expires: Date?,
                           secure: Bool, httpOnly: Bool) -> HTTPCookie? {
        guard !name.isEmpty else { return nil }
        if let expires, expires < Date() { return nil }
        var props: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .name: name, .value: value, .path: path.isEmpty ? "/" : path,
        ]
        if let expires { props[.expires] = expires }
        if secure { props[.secure] = "TRUE" }
        if httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: props)
    }
}
