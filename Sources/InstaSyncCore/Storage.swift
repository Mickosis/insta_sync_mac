import Foundation

/// Insta Sync's files in ~/Library/Application Support/Insta Sync/. Same JSON shapes as the
/// old Python version's data/ folder, so that folder can be imported as is.
public struct AppPaths: Sendable {
    public let base: URL

    public init(base: URL) { self.base = base }

    public static var standard: AppPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(base: support.appendingPathComponent("Insta Sync", isDirectory: true))
    }

    public var following: URL { base.appendingPathComponent("following.json") }
    public var syncState: URL { base.appendingPathComponent("sync_state.json") }
    public var none: URL { base.appendingPathComponent("none.json") }
    public var backups: URL { base.appendingPathComponent("backups", isDirectory: true) }
    public var thumbs: URL { base.appendingPathComponent("thumbs", isDirectory: true) }

    public func ensure() {
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    /// A new timestamped backup folder: backups/<yyyy-MM-dd_HHmmss>/ (created on first use).
    public func newBackupFolder(_ date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return backups.appendingPathComponent(f.string(from: date), isDirectory: true)
    }
}

/// The accounts you follow, cached for 7 days.
public struct FollowingCache: Codable, Sendable {
    public var fetchedAt: Double
    public var users: [FollowedUser]

    public static let maxAge: Double = 7 * 24 * 3600

    public init(fetchedAt: Double, users: [FollowedUser]) {
        self.fetchedAt = fetchedAt
        self.users = users
    }

    enum CodingKeys: String, CodingKey { case fetchedAt = "fetched_at", users }

    public var isStale: Bool { Date().timeIntervalSince1970 - fetchedAt > Self.maxAge }
}

/// When each handle's photo was last synced. Keyed by lowercase handle (ids change on moves, handles don't).
public struct SyncRecord: Codable, Hashable, Sendable {
    public var syncedAt: Double
    public var w: Int
    public var h: Int
    enum CodingKeys: String, CodingKey { case syncedAt = "synced_at", w, h }
    public init(syncedAt: Double, w: Int, h: Int) {
        self.syncedAt = syncedAt
        self.w = w
        self.h = h
    }
}

public final class Storage: @unchecked Sendable {
    public let paths: AppPaths
    private let lock = NSLock()

    public init(paths: AppPaths = .standard) {
        self.paths = paths
        paths.ensure()
    }

    private func read<T: Decodable>(_ url: URL, as: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        paths.ensure()
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    public func loadFollowing() -> FollowingCache? { read(paths.following, as: FollowingCache.self) }
    public func saveFollowing(_ f: FollowingCache) throws { try write(f, to: paths.following) }

    public func loadSyncState() -> [String: SyncRecord] {
        lock.lock(); defer { lock.unlock() }
        return read(paths.syncState, as: [String: SyncRecord].self) ?? [:]
    }

    public func recordSync(handle: String, w: Int, h: Int) {
        lock.lock(); defer { lock.unlock() }
        var state = read(paths.syncState, as: [String: SyncRecord].self) ?? [:]
        state[handle.lowercased()] = SyncRecord(syncedAt: Date().timeIntervalSince1970, w: w, h: h)
        try? write(state, to: paths.syncState)
    }

    /// Contact ids you answered "None" for in Find matches.
    public func loadNone() -> Set<String> { Set(read(paths.none, as: [String].self) ?? []) }
    public func saveNone(_ ids: Set<String>) { try? write(ids.sorted(), to: paths.none) }

    /// Import the old Python version's data/ folder (following list, sync history, None answers, backups).
    /// Returns what was copied.
    @discardableResult
    public func importLegacy(from dataDir: URL) -> [String] {
        let fm = FileManager.default
        paths.ensure()
        var copied: [String] = []
        for name in ["following.json", "sync_state.json", "none.json"] {
            let src = dataDir.appendingPathComponent(name), dst = paths.base.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) && !fm.fileExists(atPath: dst.path) {
                if (try? fm.copyItem(at: src, to: dst)) != nil { copied.append(name) }
            }
        }
        let oldBackups = dataDir.appendingPathComponent("backups")
        if let folders = try? fm.contentsOfDirectory(at: oldBackups, includingPropertiesForKeys: nil) {
            try? fm.createDirectory(at: paths.backups, withIntermediateDirectories: true)
            var n = 0
            for f in folders where f.hasDirectoryPath {
                let dst = paths.backups.appendingPathComponent(f.lastPathComponent)
                if !fm.fileExists(atPath: dst.path), (try? fm.copyItem(at: f, to: dst)) != nil { n += 1 }
            }
            if n > 0 { copied.append("\(n) backup folder(s)") }
        }
        return copied
    }

    public var hasData: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: paths.following.path) || fm.fileExists(atPath: paths.syncState.path)
    }
}
