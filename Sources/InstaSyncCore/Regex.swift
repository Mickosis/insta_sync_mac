import Foundation

/// Small wrapper over NSRegularExpression (ICU) with Python `re`-style helpers, so the
/// patterns ported from the Python version behave the same (Unicode \w, \s, lookbehind).
public struct PyRegex: @unchecked Sendable {
    public let re: NSRegularExpression

    public init(_ pattern: String, caseInsensitive: Bool = false, dotAll: Bool = false) {
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        if dotAll { opts.insert(.dotMatchesLineSeparators) }
        re = try! NSRegularExpression(pattern: pattern, options: opts)
    }

    private func all(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }

    /// First match: whole match and capture groups (nil for groups that didn't take part).
    public func search(_ s: String) -> [String?]? {
        guard let m = re.firstMatch(in: s, range: all(s)) else { return nil }
        return groups(m, in: s)
    }

    public func matches(_ s: String) -> Bool { re.firstMatch(in: s, range: all(s)) != nil }

    public func findAll(_ s: String) -> [[String?]] {
        re.matches(in: s, range: all(s)).map { groups($0, in: s) }
    }

    /// Like Python's re.fullmatch.
    public func fullMatch(_ s: String) -> Bool {
        guard let m = re.firstMatch(in: s, options: [.anchored], range: all(s)) else { return false }
        return m.range.location == 0 && m.range.length == (s as NSString).length
    }

    public func sub(_ s: String, _ template: String = "") -> String {
        re.stringByReplacingMatches(in: s, range: all(s), withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    private func groups(_ m: NSTextCheckingResult, in s: String) -> [String?] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
            return String(s[rr])
        }
    }
}

extension String {
    /// Python's str.strip().
    public var pyStrip: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Python's str.splitlines(): no trailing empty line, "" gives [].
    public var pyLines: [String] {
        var lines = split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }
}
