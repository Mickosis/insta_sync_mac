import CryptoKit
import Foundation

/// Which `.vcf` backups to keep. A contact's versions share a filename (`Name_<id prefix>.vcf`)
/// across the timestamped folders. A card moved to iCloud gets a new id and counts as a separate
/// contact, so two people with the same name never share a group.
public enum BackupRetention {
    /// How many of the latest different versions to keep, besides the oldest.
    public static let newestKept = 2

    public struct Version: Hashable, Sendable {
        public var url: URL
        public var hash: String
        public init(url: URL, hash: String) {
            self.url = url
            self.hash = hash
        }
    }

    /// The versions of one contact to delete, given oldest first: repeats of the version before
    /// them, then everything between the oldest and the newest few.
    public static func filesToDelete(_ versions: [Version]) -> [Version] {
        var distinct: [Version] = []
        var delete: [Version] = []
        for v in versions {
            if distinct.last?.hash == v.hash { delete.append(v) } else { distinct.append(v) }
        }
        if distinct.count > newestKept + 1 {
            delete += distinct[1..<(distinct.count - newestKept)]
        }
        return delete
    }

    /// Timestamped backup folders in `root`, oldest first. Anything else is left alone.
    static func folders(in root: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.hasDirectoryPath && $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}_\d{6}$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The newest backup with this filename, if any.
    public static func latest(named name: String, in root: URL) -> URL? {
        folders(in: root).reversed().lazy
            .map { $0.appendingPathComponent(name) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Delete what `filesToDelete` picks for every contact, then any folder left empty.
    /// A file that can't be read is kept. Returns how much was removed.
    @discardableResult
    public static func prune(in root: URL) -> (files: Int, bytes: Int) {
        let fm = FileManager.default
        let dirs = folders(in: root)
        var groups: [String: [Version]] = [:]
        for dir in dirs {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "vcf" {
                guard let data = try? Data(contentsOf: file) else { continue }
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                groups[file.lastPathComponent, default: []].append(Version(url: file, hash: hash))
            }
        }
        var files = 0, bytes = 0
        for versions in groups.values {
            for v in filesToDelete(versions) {
                let size = (try? v.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if (try? fm.removeItem(at: v.url)) != nil {
                    files += 1
                    bytes += size
                }
            }
        }
        for dir in dirs where ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"]).filter({ $0 != ".DS_Store" }).isEmpty {
            try? fm.removeItem(at: dir)
        }
        return (files, bytes)
    }
}
