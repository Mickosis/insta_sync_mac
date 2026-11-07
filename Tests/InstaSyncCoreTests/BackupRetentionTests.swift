import Foundation
import Testing
@testable import InstaSyncCore

/// One version per letter, oldest first; returns the positions that would be deleted.
private func deleted(_ letters: String) -> [Int] {
    let versions = letters.enumerated().map { i, c in
        BackupRetention.Version(url: URL(fileURLWithPath: "/\(i)"), hash: String(c))
    }
    return BackupRetention.filesToDelete(versions).compactMap { Int($0.url.lastPathComponent) }.sorted()
}

@Test func keepsOnlyBackup() { #expect(deleted("A") == []) }

@Test func repeatsCollapseToOne() { #expect(deleted("AAAA") == [1, 2, 3]) }

@Test func changedBackIsADifferentVersion() { #expect(deleted("ABA") == []) }

@Test func keepsOldestAndNewestTwo() { #expect(deleted("ABCDE") == [1, 2]) }

@Test func oldestStaysWhenLaterVersionMatchesIt() { #expect(deleted("ABCDA") == [1, 2]) }

@Test func pruneOnDisk() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("backups-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    func put(_ folder: String, _ name: String, _ text: String) throws {
        let dir = root.appendingPathComponent(folder)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try put("2026-01-01_000000", "a.vcf", "one")
    try put("2026-01-02_000000", "a.vcf", "one")       // repeat: deleted, folder goes too
    try put("2026-01-03_000000", "a.vcf", "two")
    try put("2026-01-03_000000", "b.vcf", "one")       // other contact, same bytes: kept
    try put("2026-01-04_000000", "a.vcf", "two")       // repeat, but folder has another file
    try put("2026-01-04_000000", "readme.txt", "keep")
    try put("imported", "a.vcf", "one")                // not a dated folder: left alone

    let result = BackupRetention.prune(in: root)

    #expect(result.files == 2)
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("2026-01-02_000000").path))
    #expect(fm.fileExists(atPath: root.appendingPathComponent("2026-01-01_000000/a.vcf").path))
    #expect(fm.fileExists(atPath: root.appendingPathComponent("2026-01-03_000000/b.vcf").path))
    #expect(fm.fileExists(atPath: root.appendingPathComponent("2026-01-04_000000/readme.txt").path))
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("2026-01-04_000000/a.vcf").path))
    #expect(fm.fileExists(atPath: root.appendingPathComponent("imported/a.vcf").path))
    #expect(BackupRetention.latest(named: "a.vcf", in: root)?.path.contains("2026-01-03_000000") == true)
}
