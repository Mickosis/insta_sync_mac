import Foundation
import InstaSyncCore

/// Planned phone fixes for one iCloud contact.
struct PhoneRow: Identifiable, Hashable {
    var id: String
    var name: String
    var plan: Phones.Plan
}

/// Insta Sync's actions on Contacts and Instagram. Blocking Contacts work runs on the
/// job's background task; Instagram lookups hop to the main actor (the web view).
final class Engine: @unchecked Sendable {
    let contacts = ContactsService()
    let notes = NotesBridge()
    let storage = Storage()

    static let merge = "Merge into the iCloud card"
    static let separate = "Keep as a separate card"

    /// Every contact (without Notes: reading those needs Contacts.app).
    func people() throws -> [Person] { try contacts.people() }

    /// Planned phone fixes for iCloud contacts.
    static func phoneRows(_ people: [Person], accounts: [String: Account], iCloudID: String?) -> [PhoneRow] {
        guard let iCloudID else { return [] }
        return people.compactMap { p in
            guard !p.phones.isEmpty, accounts[p.id]?.id == iCloudID else { return nil }
            let plan = Phones.plan(p.phones)
            return plan.changed ? PhoneRow(id: p.id, name: p.name, plan: plan) : nil
        }
    }

    func run(_ ctx: JobContext) -> Run { Run(engine: self, ctx: ctx) }

    /// "HD photo 1080×1080", or for a small original "photo 150×150 (the biggest Instagram has)".
    static func photoLabel(_ w: Int, _ h: Int) -> String {
        max(w, h) >= InstagramClient.hdMinPx ? "HD photo \(w)×\(h)" : "photo \(w)×\(h) (the biggest Instagram has)"
    }

    /// One job's work: its own backup folder, progress reporting and questions.
    final class Run: @unchecked Sendable {
        let engine: Engine
        let ctx: JobContext
        lazy var backupDir: URL = engine.storage.paths.newBackupFolder()
        private var iCloud: String?

        var contacts: ContactsService { engine.contacts }
        var notes: NotesBridge { engine.notes }

        init(engine: Engine, ctx: JobContext) {
            self.engine = engine
            self.ctx = ctx
        }

        func say(_ s: String, done: Int? = nil, total: Int? = nil) { ctx.say(s, done: done, total: total) }

        func iCloudID() throws -> String {
            if let iCloud { return iCloud }
            let id = try contacts.iCloudContainerID()
            iCloud = id
            return id
        }

        private var backedUp = Set<String>()

        /// Save a .vcf of the contact, including its Notes. Once per contact per job, so the
        /// backup is the card as it was before this job changed it.
        func backup(_ id: String, note: String? = nil) throws {
            guard !backedUp.contains(id) else { return }
            try contacts.backup(id, to: backupDir, note: note ?? notes.note(id))
            backedUp.insert(id)
        }

        // MARK: - moving to iCloud

        /// Move a contact into iCloud (backup → copy → delete original). Returns its id afterwards.
        ///
        /// If iCloud already has a card with the same name, the user decides whether to merge
        /// into it. Returns the original id if it's already in iCloud or the question is dismissed.
        func ensureICloud(_ id: String, name: String, account: Account? = nil) async throws -> String {
            let icloud = try iCloudID()
            let account = account ?? contacts.account(of: id)
            if account?.id == icloud { return id }
            let note = try notes.note(id)
            try backup(id, note: note)
            let from = account?.name ?? "another account"

            let dups = try contacts.sameName(as: id, in: icloud)
            if !dups.isEmpty {
                let choice = await ctx.ask("“\(name)” already has a card in iCloud. What should happen to the card in \(from)?",
                                           [Engine.merge, Engine.separate])
                try Task.checkCancellation()
                guard let choice else {
                    say("\(name): not moved (left in \(from))")
                    return id
                }
                if choice == Engine.merge {
                    let dst = dups[0].id
                    let merged = Cleanup.mergeNotes(try notes.note(dst), note)
                    _ = try contacts.merge(id, into: dst)
                    try notes.setNoteRetrying(dst, merged)
                    say("\(name): merged into the existing iCloud card")
                    return dst
                }
            }
            let newID = try contacts.move(id, to: icloud)
            try notes.setNoteRetrying(newID, note)
            say("\(name): moved from \(from) to iCloud")
            return newID
        }

        // MARK: - Instagram link and photo

        /// Save the photo on the card through Contacts.app (shows centered); if that fails,
        /// through the Contacts framework.
        private func savePhoto(_ id: String, _ jpeg: Data) throws {
            do {
                try notes.setPhoto(id, jpeg: jpeg)
            } catch {
                BrowserLog.write("photo via Contacts.app failed (\(error.detail)); using the Contacts framework")
                do { try contacts.setPhoto(id, jpeg: jpeg) } catch let second {
                    throw ContactsService.Fail(message: "Couldn't save the photo. Contacts.app: \(error.detail). Contacts: \(second.detail)")
                }
            }
        }

        /// Save the profile link in the card's "Instagram" URL field.
        func saveHandle(_ id: String, _ handle: String) throws {
            let url = Handles.profileURL(handle)
            do {
                try contacts.setInstagramURL(id, url: url)
            } catch {
                BrowserLog.write("Instagram link via Contacts framework failed (\(error.detail)); using Contacts.app")
                try notes.setInstagramURL(id, url: url)
                BrowserLog.write("Instagram link saved via Contacts.app")
            }
        }

        /// Remove the Instagram URL field(s).
        func clearHandle(_ id: String) throws {
            try backup(id)
            try contacts.deleteInstagramURLs(id)
        }

        /// Set the contact's photo to the full-size Instagram picture. Returns its size.
        func setPhotoFromInstagram(_ id: String, _ handle: String) async throws -> (Int, Int) {
            let profile = try await InstagramClient.lookupProfile(handle)
            let photo = try await PhotoPipeline.download(profile.photoURL)
            BrowserLog.write("lookup @\(handle): downloaded \(photo.width)×\(photo.height), confirmed biggest: \(profile.largestAvailable)")
            // A small picture only when Instagram confirms it's the biggest version it has
            // (the person uploaded a small one); never a reduced copy of a bigger picture.
            if max(photo.width, photo.height) < InstagramClient.hdMinPx && !profile.largestAvailable {
                throw InstaError.noHDPhoto
            }
            try savePhoto(id, photo.jpeg)
            engine.storage.recordSync(handle: handle, w: photo.width, h: photo.height)
            return (photo.width, photo.height)
        }

        /// Save the Instagram link, move to iCloud, set the HD photo. Returns (id afterwards, summary).
        func link(_ id: String, name: String, handle: String) async throws -> (String, String) {
            BrowserLog.write("link \(name) @\(handle): account \(contacts.account(of: id)?.name ?? "?"), backing up")
            try backup(id)
            BrowserLog.write("link \(name): backup done, saving Instagram link")
            try saveHandle(id, handle)
            BrowserLog.write("link \(name): link saved")
            say("\(name): @\(handle) saved")
            let newID = try await ensureICloud(id, name: name)
            var parts = ["@\(handle) saved"] + (newID != id ? ["moved to iCloud"] : [])
            do {
                let (w, h) = try await setPhotoFromInstagram(newID, handle)
                parts.append("\(Engine.photoLabel(w, h))")
                say("\(name): \(Engine.photoLabel(w, h))")
            } catch InstaError.noHDPhoto {
                parts.append("no HD photo available")
                say("\(name): no HD photo available")
            }
            return (newID, parts.joined(separator: " · "))
        }

        // MARK: - sync

        struct SyncResult {
            var done = 0
            var total = 0
            var moved: [String] = []
            var failed: [String] = []
        }

        /// Move tagged contacts to iCloud and set their HD photos. Stops early on a rate limit.
        func sync(_ rows: [Person]) async throws -> SyncResult {
            var r = SyncResult(total: rows.count)
            if rows.isEmpty { return r }
            let icloud = try iCloudID()
            let accounts = try contacts.accounts()
            for (i, p) in rows.enumerated() {
                try Task.checkCancellation()
                guard let handle = p.handle else { continue }
                var id = p.id
                let label = p.name.isEmpty ? "@\(handle)" : p.name
                do {
                    if accounts[id]?.id != icloud {
                        let newID = try await ensureICloud(id, name: label, account: accounts[id])
                        if newID != id { r.moved.append(label) }
                        id = newID
                    }
                    let (w, h) = try await setPhotoFromInstagram(id, handle)
                    r.done += 1
                    say("\(label) @\(handle): \(Engine.photoLabel(w, h))", done: r.done, total: r.total)
                } catch let e as InstaError where e == .rateLimited || e == .challenge {
                    r.failed.append("\(label): \(e.localizedDescription)")
                    say("\(e.localizedDescription) Stopped.", done: r.done)
                    break
                } catch InstaError.notFound {
                    r.failed.append("\(label): @\(handle) not found")
                    say("✗ \(label): @\(handle) not found")
                } catch InstaError.noHDPhoto {
                    r.failed.append("\(label): no HD photo available, skipped")
                    say("✗ \(label): no HD photo available, skipped")
                } catch InstaError.loginRequired {
                    throw InstaError.loginRequired
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    r.failed.append("\(label): \(error.detail)")  // keep going on one bad contact
                    say("✗ \(label): \(error.detail)")
                }
                if i < rows.count - 1 { try await Task.sleep(for: .seconds(Double.random(in: 1.0...2.5))) }
            }
            return r
        }

        // MARK: - cleanup

        /// Back up, then delete old Google profile links.
        func cleanGoogleProfiles(_ rows: [Person]) throws -> Int {
            for p in rows { try backup(p.id) }
            for p in rows { try contacts.deleteURLs(p.id, values: p.googleProfileURLs) }
            if !rows.isEmpty { say("Removed old Google profile links from \(rows.count) contact(s). Backup: \(backupDir.path)") }
            return rows.count
        }

        /// Back up, then rewrite the phone numbers.
        func fixPhones(_ rows: [PhoneRow]) throws -> Int {
            for r in rows { try backup(r.id) }
            for r in rows {
                do { try contacts.applyPhones(r.id, changes: r.plan.phones) } catch {
                    say("\(r.name): phone numbers not changed (\(error.localizedDescription))")
                }
            }
            if !rows.isEmpty { say("Standardized phone numbers on \(rows.count) contact(s). Backup: \(backupDir.path)") }
            return rows.count
        }

        /// Current planned phone fixes (re-read, since earlier steps may have moved contacts).
        func currentPhoneRows() throws -> [PhoneRow] {
            let people = try engine.people()
            return Engine.phoneRows(people, accounts: try contacts.accounts(), iCloudID: try iCloudID())
        }
    }
}

extension Error {
    /// The message plus domain, code and underlying errors, so failures can be diagnosed.
    var detail: String {
        let e = self as NSError
        if self is InstaError || self is ContactsService.Fail || self is NotesBridge.Fail { return localizedDescription }
        var parts = ["\(e.localizedDescription) [\(e.domain) \(e.code)]"]
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { parts.append("caused by: \(u.localizedDescription) [\(u.domain) \(u.code)]") }
        if let reason = e.localizedFailureReason { parts.append(reason) }
        if let more = e.userInfo["NSDetailedErrors"] as? [NSError] { parts += more.prefix(3).map { "\($0.domain) \($0.code): \($0.userInfo)" } }
        return parts.joined(separator: " · ")
    }
}
