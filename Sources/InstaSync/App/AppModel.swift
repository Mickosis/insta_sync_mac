import AppKit
import Foundation
import InstaSyncCore
import Observation

enum Section: String, CaseIterable, Identifiable {
    case contacts, matches, add, cleanup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .contacts: return "Contacts"
        case .matches: return "Find matches"
        case .add: return "Add"
        case .cleanup: return "Cleanup & backups"
        }
    }
    var icon: String {
        switch self {
        case .contacts: return "person.crop.circle"
        case .matches: return "sparkle.magnifyingglass"
        case .add: return "plus.circle"
        case .cleanup: return "wand.and.stars"
        }
    }
}

/// The app's state: contacts, accounts, following list, matches, login, jobs.
@MainActor @Observable
final class AppModel {
    /// The one app state. Views read it directly (not through the SwiftUI environment, which
    /// isn't always passed into table cells and other hosted views).
    static let shared = AppModel()

    let engine = Engine()
    let jobs = JobQueue()
    let images: ImageCache

    var section: Section = .contacts
    /// Every contact card, as read from Contacts.
    var allPeople: [Person] = []
    /// Show (and Sync all) only contacts with at least one phone number. Remembered.
    var onlyWithPhones: Bool = UserDefaults.standard.object(forKey: "onlyWithPhones") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(onlyWithPhones, forKey: "onlyWithPhones")
            recomputeMatches()
        }
    }
    /// The contacts the app shows.
    var people: [Person] { onlyWithPhones ? allPeople.filter { !$0.phones.isEmpty } : allPeople }
    var accounts: [String: Account] = [:]
    var iCloudID: String?
    var loading = false
    var loaded = false
    var loadError: String?

    var following: FollowingCache?
    var syncState: [String: SyncRecord] = [:]
    var noneIDs: Set<String> = []
    /// Goes up when old backups are deleted, so the list on screen can refresh.
    var backupsTrimmed = 0

    /// Find matches rows (nil while computing).
    var matchRows: [Matching.Row]?
    /// Rows answered or linked since the last reload.
    var dismissedMatches: Set<String> = []
    /// Contact id → chosen username, kept while switching sections.
    var picks: [String: String] = [:]

    /// Instagram user id when logged in to Insta Sync's browser.
    var instagramUserID: String?
    var loginChecked = false

    var toast: String?
    private var toastTask: Task<Void, Never>?

    private init() {
        images = ImageCache(engine: engine)
        jobs.onFinish = { [weak self] job in self?.jobFinished(job) }
    }

    var storage: Storage { engine.storage }
    var isLoggedIn: Bool { instagramUserID != nil }

    // MARK: - loading

    func start() async {
        loadFiles()
        await pruneBackups()
        await refreshLogin()
        do {
            try await engine.contacts.requestAccess()
        } catch {
            loadError = error.localizedDescription
            return
        }
        await reload()
    }

    func loadFiles() {
        following = storage.loadFollowing()
        syncState = storage.loadSyncState()
        noneIDs = storage.loadNone()
    }

    func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let engine = self.engine
        let result = await Task.detached(priority: .userInitiated) { () -> Result<([Person], [String: Account], String?), Error> in
            Result {
                let people = try engine.people()
                let accounts = try engine.contacts.accounts()
                return (people, accounts, try? engine.contacts.iCloudContainerID())
            }
        }.value
        switch result {
        case .success(let (people, accounts, icloud)):
            self.allPeople = people.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.accounts = accounts
            self.iCloudID = icloud
            loadError = nil
            loaded = true
        case .failure(let e):
            loadError = e.localizedDescription
        }
        loadFiles()
        dismissedMatches = []
        images.forgetContacts()
        recomputeMatches()
    }

    func recomputeMatches() {
        guard let f = following else { matchRows = []; return }
        let untagged = people.filter { $0.handle == nil && !noneIDs.contains($0.id) }
        matchRows = nil
        let users = f.users
        Task {
            let rows = await Task.detached(priority: .userInitiated) { Matching.find(untagged, users) }.value
            self.matchRows = rows
            let ids = Set(rows.map(\.id))
            self.picks = self.picks.filter { ids.contains($0.key) }
        }
    }

    func refreshLogin() async {
        instagramUserID = await InstagramSession.loggedInUserID()
        loginChecked = true
    }

    func logOut() async {
        await InstagramSession.logOut()
        await refreshLogin()
        show("Logged out of Instagram")
    }

    private func jobFinished(_ job: Job) {
        if job.status == .done, let s = job.summary { show(s) }
        Task {
            await pruneBackups()
            await refreshLogin()
            await reload()
        }
    }

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: - derived views

    var tagged: [Person] { people.filter { $0.handle != nil } }

    func account(_ id: String) -> String { accounts[id]?.name ?? "?" }
    func isICloud(_ id: String) -> Bool { iCloudID != nil && accounts[id]?.id == iCloudID }
    func syncRecord(_ p: Person) -> SyncRecord? { p.handle.flatMap { syncState[$0.lowercased()] } }

    var lastSync: Date? {
        tagged.compactMap { syncRecord($0)?.syncedAt }.max().map { Date(timeIntervalSince1970: $0) }
    }

    var visibleMatches: [Matching.Row]? { matchRows?.filter { !dismissedMatches.contains($0.id) } }

    var phoneRows: [PhoneRow] { Engine.phoneRows(people, accounts: accounts, iCloudID: iCloudID) }

    func searchFollowing(_ q: String, for contact: Person?) -> [Matching.Candidate] {
        Matching.search(q, in: following?.users ?? [], contact: contact)
    }

    // MARK: - jobs

    func sync(ids: Set<String>? = nil) {
        // Sync all = every contact shown (with the phone filter on, only those with a number).
        let ids = ids ?? (onlyWithPhones ? Set(tagged.map(\.id)) : nil)
        let engine = self.engine
        let title = ids == nil || (onlyWithPhones && ids?.count == tagged.count) ? "Sync all contacts" : "Sync \(ids!.count) contact(s)"
        jobs.submit(kind: "sync", title: title) { ctx in
            let run = engine.run(ctx)
            let people = try engine.people()
            let rows = people.filter { $0.handle != nil && (ids == nil || ids!.contains($0.id)) }
            run.say("Syncing \(rows.count) contact(s)…", done: 0, total: rows.count)
            let r = try await run.sync(rows)
            _ = try run.fixPhones(try run.currentPhoneRows())
            let text = "Done: \(r.done) of \(r.total) photos synced" + (r.moved.isEmpty ? "" : ", \(r.moved.count) moved to iCloud")
                + (r.failed.isEmpty ? "" : ". \(r.failed.count) not updated.")
            run.say(text)
            ctx.summary(text)
        }
    }

    func link(_ p: Person, handle typed: String, kind: String = "link") {
        guard let handle = Handles.username(from: typed) else {
            show("That isn't a valid Instagram username or profile link.")
            return
        }
        let engine = self.engine
        jobs.submit(kind: kind, title: "\(p.name) → @\(handle)") { ctx in
            let run = engine.run(ctx)
            run.say("Linking \(p.name) to @\(handle)…", done: 0, total: 1)
            let (_, summary) = try await run.link(p.id, name: p.name, handle: handle)
            run.say(summary, done: 1, total: 1)
            ctx.summary("\(p.name): \(summary)")
        }
        dismissedMatches.insert(p.id)
        picks[p.id] = nil
    }

    /// A photo chosen by hand in Add: dropped image data, or a link to download.
    enum PhotoSource: Sendable {
        case data(Data)
        case link(URL)
    }

    /// The typed photo link, or nil (with a message) if it can't be used. Only https: the app
    /// has no App Transport Security exception, so a plain http download would fail.
    func photoLinkURL(_ typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            show("Photo links must start with https://.")
            return nil
        }
        return url
    }

    /// Move a contact to iCloud without an Instagram handle, with an optional photo.
    func moveToICloud(_ p: Person, photo source: PhotoSource?) {
        let engine = self.engine
        jobs.submit(kind: "add", title: "\(p.name) → iCloud") { ctx in
            let run = engine.run(ctx)
            run.say("Moving \(p.name) to iCloud…", done: 0, total: 1)
            // Get the photo first, so a bad link or file fails with the card untouched.
            let photo: PhotoPipeline.Photo?
            switch source {
            case .data(let data): photo = try PhotoPipeline.prepare(data)
            case .link(let url): photo = try await PhotoPipeline.download(url)
            case nil: photo = nil
            }
            let (newID, summary) = try await run.moveWithoutHandle(p.id, name: p.name, photo: photo)
            if newID != p.id { await self.carryNone(from: p.id, to: newID) }
            run.say(summary, done: 1, total: 1)
            ctx.summary("\(p.name): \(summary)")
        }
    }

    /// Moving a card changes its id; keep its "None" answer.
    private func carryNone(from old: String, to new: String) {
        guard noneIDs.remove(old) != nil else { return }
        noneIDs.insert(new)
        storage.saveNone(noneIDs)
    }

    /// Link several contacts in one job (Find matches → Link N).
    func linkPicked() {
        let todo: [(Person, String)] = picks.compactMap { id, u in
            guard let p = people.first(where: { $0.id == id }), let h = Handles.username(from: u) else { return nil }
            return (p, h)
        }.sorted { $0.0.name < $1.0.name }
        guard !todo.isEmpty else { return }
        let engine = self.engine
        jobs.submit(kind: "link", title: "Link \(todo.count) contact\(todo.count == 1 ? "" : "s")") { ctx in
            let run = engine.run(ctx)
            var done = 0
            var failed: [String] = []
            run.say("Linking \(todo.count) contact(s)…", done: 0, total: todo.count)
            for (i, (p, handle)) in todo.enumerated() {
                try Task.checkCancellation()
                do {
                    let (_, summary) = try await run.link(p.id, name: p.name, handle: handle)
                    done += 1
                    run.say("✓ \(p.name): \(summary)", done: done, total: todo.count)
                } catch let e as InstaError where e == .rateLimited || e == .challenge {
                    failed += todo[i...].map { "\($0.0.name): not linked" }
                    run.say("\(e.localizedDescription) Stopped; the rest weren't linked.")
                    break
                } catch InstaError.loginRequired {
                    throw InstaError.loginRequired
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failed.append("\(p.name): \(error.detail)")
                    run.say("✗ \(p.name): \(error.detail)", done: done, total: todo.count)
                }
                if i < todo.count - 1 { try await Task.sleep(for: .seconds(Double.random(in: 1.0...2.5))) }
            }
            let text = "Done: \(done) of \(todo.count) linked." + (failed.isEmpty ? "" : " \(failed.count) not linked.")
            run.say(text)
            ctx.summary(text)
        }
        for (p, _) in todo { dismissedMatches.insert(p.id) }
        picks = [:]
    }

    func removeHandle(_ p: Person) {
        guard let handle = p.handle else { return }
        let engine = self.engine
        jobs.submit(kind: "remove", title: "Remove @\(handle) from \(p.name)") { ctx in
            let run = engine.run(ctx)
            try run.clearHandle(p.id)
            run.say("Removed @\(handle) from \(p.name)")
            ctx.summary("Removed @\(handle) from \(p.name)")
        }
    }

    func refreshFollowing() {
        let storage = self.storage
        jobs.submit(kind: "following", title: "Refresh following list") { ctx in
            ctx.say("Fetching the accounts you follow…")
            let data = try await InstagramClient.fetchFollowing { text in ctx.say(text) }
            try storage.saveFollowing(data)
            ctx.say("Done: \(data.users.count) accounts.")
            ctx.summary("Following list: \(data.users.count) accounts")
        }
    }

    func fixPhones() {
        let engine = self.engine
        jobs.submit(kind: "phones", title: "Standardize phone numbers") { ctx in
            let run = engine.run(ctx)
            let rows = try run.currentPhoneRows()
            run.say("Standardizing phone numbers on \(rows.count) contact(s)…", done: 0, total: rows.count)
            let n = try run.fixPhones(rows)
            run.say("Done: \(n) of \(rows.count) contact(s) updated.", done: n, total: rows.count)
        }
    }

    // MARK: - match answers

    func answerNone(_ id: String) {
        noneIDs.insert(id)
        storage.saveNone(noneIDs)
        dismissedMatches.insert(id)
        picks[id] = nil
    }

    func skip(_ id: String) {
        dismissedMatches.insert(id)
        picks[id] = nil
    }

    func resetNone() {
        noneIDs = []
        storage.saveNone([])
        recomputeMatches()
    }

    // MARK: - backups

    /// Trim old backups, unless a job is running or waiting and may be writing some.
    func pruneBackups() async {
        guard !jobs.isBusy else { return }
        let root = storage.paths.backups
        let removed = await Task.detached { BackupRetention.prune(in: root) }.value
        guard removed.files > 0 else { return }
        BrowserLog.write("backups: removed \(removed.files) old file(s), \(removed.bytes / 1000) KB")
        backupsTrimmed += 1
    }

    struct BackupFolder: Identifiable {
        var url: URL
        var files: [URL]
        var id: URL { url }
        var date: Date? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd_HHmmss"
            return f.date(from: url.lastPathComponent)
        }
    }

    func backups() -> [BackupFolder] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: storage.paths.backups, includingPropertiesForKeys: nil) else { return [] }
        return dirs.filter(\.hasDirectoryPath).sorted { $0.lastPathComponent > $1.lastPathComponent }.map { d in
            let files = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "vcf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            return BackupFolder(url: d, files: files)
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func restore(_ url: URL) {
        let contacts = URL(fileURLWithPath: "/System/Applications/Contacts.app")
        NSWorkspace.shared.open([url], withApplicationAt: contacts, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - old version's data

    func offerLegacyImport() -> URL? {
        guard !storage.hasData, !UserDefaults.standard.bool(forKey: "legacyImportAnswered"),
              let path = Bundle.main.object(forInfoDictionaryKey: "InstaSyncLegacyDataPath") as? String, !path.isEmpty
        else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("following.json").path)
            || fm.fileExists(atPath: url.appendingPathComponent("sync_state.json").path) else { return nil }
        return url
    }

    func importLegacy(_ url: URL?) {
        UserDefaults.standard.set(true, forKey: "legacyImportAnswered")
        guard let url else { return }
        let copied = storage.importLegacy(from: url)
        loadFiles()
        recomputeMatches()
        show(copied.isEmpty ? "Nothing to import" : "Imported " + copied.joined(separator: ", "))
    }
}

/// Avatars: contact photos (from Contacts) and Instagram thumbnails (from the following list).
@MainActor
final class ImageCache {
    private let engine: Engine
    private var contactImages: [String: NSImage?] = [:]
    private var igImages: [String: NSImage?] = [:]

    init(engine: Engine) { self.engine = engine }

    func forgetContacts() { contactImages = [:] }

    func contact(_ id: String) async -> NSImage? {
        if let hit = contactImages[id] { return hit }
        let contacts = engine.contacts
        let img = await Task.detached(priority: .utility) { contacts.thumbnail(id, px: 96) }.value
        contactImages[id] = img
        return img
    }

    func instagram(_ username: String, url: String?) async -> NSImage? {
        if let hit = igImages[username] { return hit }
        let file = engine.storage.paths.thumbs.appendingPathComponent("\(username).jpg")
        var img = NSImage(contentsOf: file)
        if img == nil, let s = url, let u = URL(string: s) {
            if let (data, resp) = try? await URLSession.shared.data(from: u),
               (resp as? HTTPURLResponse)?.statusCode == 200, let i = NSImage(data: data) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file)
                img = i
            }
        }
        igImages[username] = img
        return img
    }
}
