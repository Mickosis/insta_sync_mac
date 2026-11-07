import Foundation

/// Old junk in contacts that every sync removes.
public enum Cleanup {
    /// Old HTC Sense phones wrote <HTCData><Facebook>id:…/friendof:…</Facebook></HTCData> into Google contact Notes.
    public static let htcRE = PyRegex("<HTCData>.*?</HTCData>", caseInsensitive: true, dotAll: true)

    public static func stripHTC(_ note: String?) -> String { htcRE.sub(note ?? "").pyStrip }

    /// Notes of two cards being merged: the destination's lines, then new lines from the source.
    public static func mergeNotes(_ dst: String?, _ src: String?) -> String {
        var lines = stripHTC(dst).pyLines
        for line in stripHTC(src).pyLines where !line.pyStrip.isEmpty && !lines.contains(line) {
            lines.append(line)
        }
        return lines.joined(separator: "\n").pyStrip
    }
}
