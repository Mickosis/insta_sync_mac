import Foundation

/// Instagram usernames: parsing what people type or paste.
public enum Handles {
    static let usernameRE = PyRegex(#"instagram\.com/(?:_u/)?([A-Za-z0-9._]+)"#, caseInsensitive: true)
    static let validRE = PyRegex(#"[A-Za-z0-9._]{1,30}"#)

    public static let reservedPaths: Set<String> = ["p", "reel", "reels", "stories", "explore", "accounts", "direct", "tv"]

    /// A username from "@user", "user" or an instagram.com profile link; nil if it isn't one.
    public static func username(from text: String) -> String? {
        let t = text.pyStrip
        let name: String
        if let m = usernameRE.search(t), let g = m[1] {
            name = g
        } else {
            name = String(t.drop(while: { $0 == "@" }))
        }
        guard validRE.fullMatch(name), !reservedPaths.contains(name.lowercased()) else { return nil }
        return name
    }

    public static func profileURL(_ handle: String) -> String { "https://www.instagram.com/\(handle)/" }
}
