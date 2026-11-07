import Foundation

/// Matching contacts to the Instagram accounts you follow.
public enum Matching {
    static let nonAlnumRE = PyRegex("[^a-z0-9]+")
    static let nonAlphaRE = PyRegex("[^a-z]")
    static let nonAlphaRunRE = PyRegex("[^a-z]+")

    /// Lowercase ASCII words with accents removed: "José Dela-Cruz" → ["jose", "dela", "cruz"].
    public static func tokens(_ text: String?) -> [String] {
        let decomposed = (text ?? "").decomposedStringWithCompatibilityMapping
        var kept = String.UnicodeScalarView()
        for u in decomposed.unicodeScalars where u.properties.canonicalCombiningClass.rawValue == 0 {
            kept.append(u)
        }
        let lower = String(kept).lowercased()
        return nonAlnumRE.sub(lower, " ").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// A contact's name, prepared once for scoring against many accounts.
    public struct ContactKey: Sendable {
        let first: String, lasts: [String], last: String, firsts: Set<String>
        public init(first: String, last: String, nick: String) {
            self.first = Matching.tokens(first).first ?? ""
            lasts = Matching.tokens(last)  // "Dela Cruz" → ["dela", "cruz"]
            self.last = lasts.joined()
            let n = Matching.tokens(nick).first ?? ""
            firsts = Set([self.first, n].filter { !$0.isEmpty })
        }
        public init(_ p: Person) { self.init(first: p.first, last: p.last, nick: p.nick) }
    }

    /// An account's names, prepared once.
    public struct UserKey: Sendable {
        let igName: Set<String>, handle: String, parts: Set<String>
        public init(username: String, fullName: String) {
            igName = Set(Matching.tokens(fullName))
            let raw = username.lowercased()
            handle = nonAlphaRE.sub(raw)
            parts = Set(nonAlphaRunRE.sub(raw, " ").split(separator: " ").map(String.init))
        }
        public init(_ u: FollowedUser) { self.init(username: u.username, fullName: u.fullName) }
    }

    /// 0–100: how likely an Instagram account is this contact.
    public static func score(_ c: ContactKey, _ u: UserKey) -> Int {
        let first = c.first, lasts = c.lasts, last = c.last, firsts = c.firsts
        if first.isEmpty && last.isEmpty { return 0 }  // company cards etc.
        let igName = u.igName, handle = u.handle, parts = u.parts

        // A whole part of the username (juan.cruz), or its start or end (juancruz),
        // so "ling" doesn't match inside "dustinbillings".
        func inHandle(_ word: String) -> Bool {
            word.count >= 3 && (parts.contains(word) || handle.hasPrefix(word) || handle.hasSuffix(word))
        }

        let lastInName = !lasts.isEmpty && lasts.allSatisfy { igName.contains($0) }
        let lastInHandle = inHandle(last)
        let firstInName = !firsts.isDisjoint(with: igName)
        let firstInHandle = firsts.contains(where: inHandle)

        if lastInName && firstInName { return 100 }  // "Juan Cruz" ↔ "Juan Cruz"
        if lastInHandle && firstInHandle { return 90 }  // ↔ @juan.cruz, @juancruz
        if (lastInHandle && firstInName) || (lastInName && firstInHandle) { return 80 }  // "Jo" ↔ @josantos
        if lastInHandle, let f = first.first, handle.hasPrefix(String(f)) { return 60 }  // Maria Reyes ↔ @mareyes
        if (lastInName || lastInHandle) && last.count >= 3 { return 50 }  // same surname only: could be a relative
        if last.isEmpty && first.count >= 4 && igName.contains(first) && inHandle(first) { return 40 }  // single-name contacts
        return 0
    }

    public static func score(first: String, last: String, nick: String, username: String, fullName: String) -> Int {
        score(ContactKey(first: first, last: last, nick: nick), UserKey(username: username, fullName: fullName))
    }

    public static func score(_ c: Person, _ u: FollowedUser) -> Int { score(ContactKey(c), UserKey(u)) }

    public struct Candidate: Hashable, Sendable {
        public var score: Int
        public var user: FollowedUser
    }

    public struct Row: Identifiable, Hashable, Sendable {
        public var contact: Person
        public var candidates: [Candidate]
        public var id: String { contact.id }
    }

    /// Contacts with at least one likely match, best first.
    public static func find(_ contacts: [Person], _ following: [FollowedUser], limit: Int = 5, minScore: Int = 40) -> [Row] {
        let keys = following.map { (UserKey($0), $0) }
        var out: [Row] = []
        for c in contacts {
            let ck = ContactKey(c)
            let scored = keys.map { Candidate(score: score(ck, $0.0), user: $0.1) }
                .filter { $0.score >= minScore }
                .sorted { ($0.score, $1.user.username) > ($1.score, $0.user.username) }
            let cands = Array(scored.prefix(limit))
            if !cands.isEmpty { out.append(Row(contact: c, candidates: cands)) }
        }
        return out.enumerated().sorted { a, b in
            let sa = a.element.candidates[0].score, sb = b.element.candidates[0].score
            if sa != sb { return sa > sb }
            let na = a.element.contact.name.lowercased(), nb = b.element.contact.name.lowercased()
            if na != nb { return na < nb }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Accounts you follow whose username or name contains every word of q.
    public static func search(_ q: String, in users: [FollowedUser], contact: Person?, limit: Int = 12) -> [Candidate] {
        let words = tokens(q)
        if words.isEmpty { return [] }
        let ck = contact.map(ContactKey.init)
        var hits: [Candidate] = []
        for u in users {
            let hay = u.username.lowercased() + " " + tokens(u.fullName).joined(separator: " ")
            if words.allSatisfy({ hay.contains($0) }) {
                hits.append(Candidate(score: ck.map { score($0, UserKey(u)) } ?? 0, user: u))
            }
        }
        hits.sort { ($0.score, $1.user.username) > ($1.score, $0.user.username) }
        return Array(hits.prefix(limit))
    }

    /// "Strong match" (90+), "Good match" (60+) or "Possible".
    public static func label(_ score: Int) -> String {
        score >= 90 ? "Strong match" : score >= 60 ? "Good match" : "Possible"
    }
}
