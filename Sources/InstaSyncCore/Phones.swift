import Foundation

/// Phone number standardisation: "+63 917 123 4567", landlines "+63 2 8123 4567", US "+1 212 555 0123".
public enum Phones {
    static let letterRE = PyRegex("[A-Za-z]")

    static func digits(_ s: String) -> String { String(s.filter { $0.isASCII && $0.isNumber }) }

    /// Format a Philippine number given without its leading 0 / +63.
    static func ph(_ n: String) -> String? {
        let c = Array(n)
        func s(_ a: Int, _ b: Int? = nil) -> String { String(c[a..<(b ?? c.count)]) }
        if c.count == 10 && n.hasPrefix("9") { return "+63 \(s(0, 3)) \(s(3, 6)) \(s(6))" }  // mobile
        if c.count == 9 && n.hasPrefix("2") { return "+63 2 \(s(1, 5)) \(s(5))" }  // Metro Manila landline
        if c.count == 9 && !n.hasPrefix("9") { return "+63 \(s(0, 2)) \(s(2, 5)) \(s(5))" }  // provincial landline
        return nil
    }

    /// Standard form of a phone number, or nil to leave it as it is.
    public static func format(_ raw: String?) -> String? {
        let s = (raw ?? "").pyStrip
        if s.isEmpty || letterRE.matches(s) { return nil }  // vanity numbers like 1-800-MY-APPLE
        var d = digits(s)
        var intl = s.hasPrefix("+")
        if !intl && d.hasPrefix("00") { intl = true; d = String(d.dropFirst(2)) }
        if !intl && d.hasPrefix("63") && d.count == 12 { intl = true }  // 639171234567 written without the +
        if intl {
            if d.hasPrefix("63") { return ph(String(d.dropFirst(2))) }
            if d.hasPrefix("1") && d.count == 11 {
                let c = Array(d)
                return "+1 \(String(c[1..<4])) \(String(c[4..<7])) \(String(c[7...]))"
            }
            return nil  // other countries: leave as is
        }
        if d.hasPrefix("0") { return ph(String(d.dropFirst())) }
        if d.count == 10 && d.hasPrefix("9") { return ph(d) }
        return nil
    }

    public struct Change: Codable, Hashable, Sendable {
        public var old: String
        /// Formatted number, "" for a duplicate to remove, nil to leave unchanged.
        public var new: String?
        public var isDelete: Bool { new == "" }
    }

    public struct Plan: Hashable, Sendable {
        public var phones: [Change]
        public var skipped: [String]
        public var changed: Bool
    }

    /// The planned fix for one contact's numbers, in order.
    public static func plan(_ values: [String]) -> Plan {
        var seen = Set<String>()
        var phones: [Change] = []
        var skipped: [String] = []
        var changed = false
        for v in values {
            let new = format(v)
            let key = digits(new ?? v)
            if seen.contains(key) {
                phones.append(Change(old: v, new: ""))
                changed = true
                continue
            }
            seen.insert(key)
            if new == nil {
                skipped.append(v)
            } else if new != v {
                changed = true
            }
            phones.append(Change(old: v, new: new != v ? new : nil))
        }
        return Plan(phones: phones, skipped: skipped, changed: changed)
    }
}
