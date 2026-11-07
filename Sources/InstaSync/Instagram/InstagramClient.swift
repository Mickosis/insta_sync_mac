import Foundation
import ImageIO
import InstaSyncCore
import UniformTypeIdentifiers

enum InstaError: LocalizedError, Equatable {
    case loginRequired
    case rateLimited
    case challenge
    case notFound
    case noHDPhoto
    case other(String)

    var errorDescription: String? {
        switch self {
        case .loginRequired: return "You're not logged into Instagram in Insta Sync. Log in, then try again."
        case .rateLimited: return "Instagram says to wait a few minutes. Try again later."
        case .challenge: return "Instagram wants a security check. Open the Instagram window, complete it, then try again."
        case .notFound: return "That Instagram account doesn't exist."
        case .noHDPhoto: return "Instagram didn't give the HD picture."
        case .other(let s): return s
        }
    }

    /// Errors that should stop a whole batch (the rest would fail the same way).
    var stopsBatch: Bool { self == .loginRequired || self == .rateLimited || self == .challenge }
}

/// Instagram lookups, run in the hidden web view with your Insta Sync login.
@MainActor
enum InstagramClient {
    static let appID = "936619743392459"  // Instagram web app id, sent by instagram.com itself
    nonisolated static let hdMinPx = 321  // Instagram's small versions are 150 and 320px; anything bigger is the full-size picture
    static let pageTimeout: TimeInterval = 20

    static var session: InstagramSession { .shared }

    // Reads the profile picture the loaded profile page shows. The page renders the
    // full-size (usually 1080px) picture itself, so no API endpoint is needed.
    static let picJS = #"""
    var p = location.pathname.toLowerCase();
    if (p.indexOf('/accounts/login') === 0) return '{"login":1}';
    if (p.indexOf('/challenge') === 0) return '{"challenge":1}';
    var txt = document.body ? document.body.innerText.slice(0, 3000) : '';
    if (txt.indexOf('Please wait a few minutes') >= 0) return '{"limited":1}';
    if (p !== '/' + u.toLowerCase() + '/') return '{}';
    if (/Sorry, this page isn.t available/.test(txt)) return '{"notfound":1}';
    var want = u.toLowerCase() + "'s profile picture", best = null;
    [].forEach.call(document.images, function (i) {
      if ((i.alt || '').toLowerCase() === want && i.complete && i.naturalWidth > 0 && (!best || i.naturalWidth > best.naturalWidth)) best = i;
    });
    var og = document.querySelector('meta[property="og:title"]');
    var m = ((og && og.content) || document.title).match(/^(.*?) \(@/);
    var r = {name: m ? m[1] : ''};
    if (best) {
      r.src = best.currentSrc || best.src; r.w = best.naturalWidth;
      (best.getAttribute('srcset') || '').split(',').forEach(function (c) {
        var m = c.trim().match(/^(\S+)\s+(\d+)w$/);
        if (m && +m[2] > r.w) { r.src = m[1]; r.w = +m[2]; }
      });
    }
    return JSON.stringify(r);
    """#

    struct Profile {
        var username: String
        var fullName: String
        var photoURL: URL
        /// Instagram itself says this is the biggest version it has (its "HD" picture URL),
        /// so a small picture is the original upload, not a reduced copy.
        var largestAvailable = false
    }

    /// Load the profile page and return its full-size photo URL.
    ///
    /// The page normally shows the full-size picture. If it only shows a small one, the
    /// profile's HD picture URL is asked for through the same logged-in page instead: that's
    /// the biggest version Instagram has, even if the person uploaded a small picture.
    /// Throws noHDPhoto when neither gives a confirmed full-size picture.
    static func lookupProfile(_ username: String) async throws -> Profile {
        let path = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        await session.load(URL(string: "https://www.instagram.com/\(path)/")!)
        try await Task.sleep(for: .seconds(1.5))
        let deadline = Date().addingTimeInterval(pageTimeout)
        var smallSeen = 0
        var name = ""
        var lastRaw = ""
        while Date() < deadline {
            try Task.checkCancellation()
            let raw = (try? await session.eval(picJS, ["u": username])) as? String ?? "{}"
            let r = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
            if r["login"] != nil { throw InstaError.loginRequired }
            if r["challenge"] != nil { throw InstaError.challenge }
            if r["limited"] != nil { throw InstaError.rateLimited }
            if r["notfound"] != nil { throw InstaError.notFound }
            if let n = r["name"] as? String, !n.isEmpty { name = n }
            if raw != lastRaw {
                lastRaw = raw
                BrowserLog.write("lookup @\(username) page \(session.currentURL?.path ?? "?"): w=\(r["w"] ?? "none") src=\(BrowserLog.clean((r["src"] as? String).flatMap(URL.init(string:))) ?? "none")")
            }
            if let src = r["src"] as? String, let w = r["w"] as? Int, let url = URL(string: src) {
                if w >= hdMinPx { return Profile(username: username, fullName: name, photoURL: url) }
                if isOriginalSize(url, width: w) {
                    BrowserLog.write("lookup @\(username): \(w)px is the original upload (stp=\(sizeToken(url) ?? "none"))")
                    return Profile(username: username, fullName: name, photoURL: url, largestAvailable: true)
                }
                smallSeen += 1
                if smallSeen == 3, let hd = await loggedHDPictureURL(username) {
                    return Profile(username: username, fullName: name, photoURL: hd, largestAvailable: true)
                }
            }
            try await Task.sleep(for: .seconds(0.7))
        }
        if smallSeen < 3, let hd = await loggedHDPictureURL(username) {
            return Profile(username: username, fullName: name, photoURL: hd, largestAvailable: true)
        }
        throw InstaError.noHDPhoto
    }

    /// The "sWxH" resize tag in an Instagram picture link (stp=dst-jpg_s150x150_…), if any.
    static func sizeToken(_ url: URL) -> String? {
        let stp = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "stp" }?.value ?? ""
        guard let r = stp.range(of: #"s\d+x\d+"#, options: .regularExpression) else { return nil }
        return String(stp[r])
    }

    /// A small picture is the original upload (not a reduced copy) when its link asks for no
    /// particular size, or asks for a bigger size than it got (asked 320, got 300).
    static func isOriginalSize(_ url: URL, width: Int) -> Bool {
        guard let token = sizeToken(url) else { return true }
        let asked = Int(token.dropFirst().split(separator: "x").first ?? "") ?? 0
        return asked > width
    }

    /// hdPictureURL, with the outcome written to the browser log.
    static func loggedHDPictureURL(_ username: String) async -> URL? {
        do {
            let url = try await hdPictureURL(username)
            BrowserLog.write("lookup @\(username) HD request: \(url.map { BrowserLog.clean($0) ?? "?" } ?? "no picture URL in the answer")")
            return url
        } catch {
            BrowserLog.write("lookup @\(username) HD request failed: \(error.detail)")
            return nil
        }
    }

    /// The profile's HD picture URL from Instagram's web profile API (same logged-in page).
    static func hdPictureURL(_ username: String) async throws -> URL? {
        let q = username.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? username
        let data = try await api("/users/web_profile_info/?username=\(q)")
        guard let user = (data["data"] as? [String: Any])?["user"] as? [String: Any] else { return nil }
        if let info = user["hd_profile_pic_url_info"] as? [String: Any], let s = info["url"] as? String { return URL(string: s) }
        return (user["profile_pic_url_hd"] as? String).flatMap(URL.init(string:))
    }

    /// GET https://www.instagram.com/api/v1<path> from the logged-in page; return parsed JSON.
    static func api(_ path: String) async throws -> [String: Any] {
        await session.ensureOnInstagram()
        if let p = session.currentURL?.path, p.hasPrefix("/accounts/login") { throw InstaError.loginRequired }
        if let p = session.currentURL?.path, p.hasPrefix("/challenge") { throw InstaError.challenge }
        let js = """
        try {
          const r = await fetch(path, {credentials: 'include', headers: {'X-IG-App-ID': appID, 'X-Requested-With': 'XMLHttpRequest'}});
          return JSON.stringify({s: r.status, u: r.url, b: await r.text()});
        } catch (e) { return JSON.stringify({s: 0, u: '', b: String(e)}); }
        """
        let raw = try await session.eval(js, ["path": "/api/v1" + path, "appID": appID]) as? String ?? ""
        guard let wrap = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw InstaError.other("Unexpected browser result: \(raw.prefix(200))")
        }
        let status = wrap["s"] as? Int ?? 0
        let body = wrap["b"] as? String ?? ""
        let finalURL = wrap["u"] as? String ?? ""
        if body.contains("\"require_login\":true") || body.contains("login_required") || finalURL.contains("/accounts/login") {
            throw InstaError.loginRequired
        }
        if body.contains("checkpoint_required") || body.contains("challenge_required") { throw InstaError.challenge }
        if status == 429 || body.contains("Please wait a few minutes") { throw InstaError.rateLimited }
        if status == 404 { throw InstaError.notFound }
        if status != 200 { throw InstaError.other("HTTP \(status) for \(path): \(body.prefix(200))") }
        guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            throw InstaError.other("Instagram sent something unexpected for \(path).")
        }
        return json
    }

    /// Everyone you follow, in pages of 50 with pauses like someone scrolling.
    static func fetchFollowing(progress: (String) -> Void) async throws -> FollowingCache {
        guard let uid = await InstagramSession.loggedInUserID() else { throw InstaError.loginRequired }
        var users: [String: FollowedUser] = [:]
        var order: [String] = []
        var seen = Set<String>()
        var maxID = ""
        while true {
            try Task.checkCancellation()
            var q = "count=50"
            if !maxID.isEmpty { q += "&max_id=" + (maxID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? maxID) }
            let data = try await api("/friendships/\(uid)/following/?\(q)")
            for u in data["users"] as? [[String: Any]] ?? [] {
                guard let name = u["username"] as? String, !name.isEmpty else { continue }
                if users[name] == nil { order.append(name) }
                users[name] = FollowedUser(username: name, fullName: u["full_name"] as? String ?? "",
                                           profilePicURL: u["profile_pic_url"] as? String ?? "")
            }
            progress("Following list: \(users.count) accounts…")
            let next = data["next_max_id"].map { "\($0)" } ?? ""
            if next.isEmpty || next == "<null>" || seen.contains(next) { break }  // done, or a pagination loop
            seen.insert(next)
            maxID = next
            try await Task.sleep(for: .seconds(Double.random(in: 1.0...2.5)))
        }
        return FollowingCache(fetchedAt: Date().timeIntervalSince1970, users: order.compactMap { users[$0] })
    }
}

/// Downloading a profile picture and making it a contact photo.
enum PhotoPipeline {
    static let maxPx = 1080

    struct Photo {
        var jpeg: Data
        var width: Int
        var height: Int
    }

    static func download(_ url: URL) async throws -> Photo {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw InstaError.other("Photo download failed (HTTP \(http.statusCode)).")
        }
        return try prepare(data)
    }

    /// Size the picture for Contacts (max 1080px). A JPEG that already fits is used as is.
    static func prepare(_ data: Data) throws -> Photo {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw InstaError.other("That isn't an image.")
        }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let isJPEG = (CGImageSourceGetType(src) as String?) == UTType.jpeg.identifier
        if isJPEG && max(w, h) <= maxPx { return Photo(jpeg: data, width: w, height: h) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPx,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw InstaError.other("Couldn't resize the photo.")
        }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw InstaError.other("Couldn't encode the photo.")
        }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw InstaError.other("Couldn't encode the photo.") }
        return Photo(jpeg: out as Data, width: w, height: h)
    }
}
