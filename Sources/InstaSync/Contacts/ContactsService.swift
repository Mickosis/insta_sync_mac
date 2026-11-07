import AppKit
import Contacts
import Foundation
import InstaSyncCore

/// Everything Insta Sync does with Apple's Contacts framework: listing cards, accounts,
/// moving cards to iCloud, merging, vCard backups, photos, URL and phone fields.
///
/// The framework can't read or write Notes without a special Apple entitlement, so Notes
/// go through `NotesBridge` (AppleScript to Contacts.app). Card ids are the same in both.
final class ContactsService: @unchecked Sendable {
    let store = CNContactStore()
    /// One caller at a time: the contacts database misbehaves (Cocoa error 134092) when the
    /// same store is used from several threads at once, e.g. avatars loading during a save.
    private let lock = NSRecursiveLock()

    struct Fail: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func requestAccess() async throws {
        let ok = try await store.requestAccess(for: .contacts)
        if !ok {
            throw Fail(message: "Contacts access was denied. Allow it in System Settings → Privacy & Security → Contacts.")
        }
    }

    // Everything except Notes (needs an entitlement).
    static let copyKeys: [String] = [
        CNContactTypeKey, CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey,
        CNContactFamilyNameKey, CNContactPreviousFamilyNameKey, CNContactNameSuffixKey,
        CNContactNicknameKey, CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey,
        CNContactPhoneticFamilyNameKey, CNContactPhoneticOrganizationNameKey,
        CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey,
        CNContactBirthdayKey, CNContactNonGregorianBirthdayKey, CNContactDatesKey,
        CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey,
        CNContactUrlAddressesKey, CNContactRelationsKey, CNContactSocialProfilesKey,
        CNContactInstantMessageAddressesKey, CNContactImageDataKey, CNContactThumbnailImageDataKey,
    ]
    static var fetchKeys: [CNKeyDescriptor] {
        copyKeys.map { $0 as CNKeyDescriptor } + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
    }
    static var listKeys: [CNKeyDescriptor] {
        [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
         CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactUrlAddressesKey].map { $0 as CNKeyDescriptor }
            + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
    }

    /// Run a read-modify-save of a card, again with a fresh copy if the contacts database
    /// rejects it as out of date (Cocoa error 134092, e.g. right after Contacts.app touched
    /// the card). Each attempt re-reads the card, so it never saves a stale copy.
    func retrying<T>(_ work: () throws -> T) throws -> T {
        var attempt = 0
        while true {
            do { return try work() } catch let e as NSError {
                BrowserLog.write("contacts save failed (attempt \(attempt + 1)): \(e.domain) \(e.code) \(Self.describe(e))")
                guard e.domain == NSCocoaErrorDomain && (e.code == 134092 || e.code == 134050) && attempt < 4 else { throw e }
                attempt += 1
                Thread.sleep(forTimeInterval: 0.6 * Double(attempt))
            }
        }
    }

    /// Every key of an error's userInfo, nested errors included, for the log.
    static func describe(_ e: NSError, depth: Int = 0) -> String {
        guard depth < 4 else { return "…" }
        return e.userInfo.map { k, v in
            if let n = v as? NSError { return "\(k)={\(n.domain) \(n.code) \(describe(n, depth: depth + 1))}" }
            if let list = v as? [NSError] { return "\(k)=[" + list.prefix(4).map { "\($0.domain) \($0.code) \(describe($0, depth: depth + 1))" }.joined(separator: "; ") + "]" }
            return "\(k)=\(String(describing: v).prefix(400))"
        }.joined(separator: ", ")
    }

    // MARK: - reading

    /// One specific card (not merged with cards linked to it in other accounts).
    func card(_ id: String, keys: [CNKeyDescriptor] = ContactsService.fetchKeys) throws -> CNContact {
        lock.lock(); defer { lock.unlock() }
        let req = CNContactFetchRequest(keysToFetch: keys)
        req.predicate = CNContact.predicateForContacts(withIdentifiers: [id])
        req.unifyResults = false
        var found: CNContact?
        try store.enumerateContacts(with: req) { c, stop in found = c; stop.pointee = true }
        guard let c = found else { throw Fail(message: "That contact no longer exists. Reload.") }
        return c
    }

    func fullName(_ c: CNContact) -> String {
        CNContactFormatter.string(from: c, style: .fullName) ?? c.organizationName
    }

    /// Every card (each account's card separately, as Contacts.app lists them). No Notes.
    func people() throws -> [Person] {
        lock.lock(); defer { lock.unlock() }
        let req = CNContactFetchRequest(keysToFetch: Self.listKeys)
        req.unifyResults = false
        var out: [Person] = []
        try store.enumerateContacts(with: req) { c, _ in
            out.append(Person(
                id: c.identifier, first: c.givenName, last: c.familyName, nick: c.nickname, name: self.fullName(c),
                phones: c.phoneNumbers.map { $0.value.stringValue },
                emails: c.emailAddresses.map { $0.value as String },
                urls: c.urlAddresses.map { $0.value as String }))
        }
        return out
    }

    // MARK: - accounts

    func containers() throws -> [CNContainer] {
        lock.lock(); defer { lock.unlock() }
        return try store.containers(matching: nil)
    }

    func iCloudContainerID() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let c = try containers().first(where: { $0.name == "iCloud" }) else {
            throw Fail(message: "No iCloud contacts account found. Turn on Contacts in System Settings → Apple Account → iCloud.")
        }
        return c.identifier
    }

    /// Account of every card: {card id: account}.
    func accounts() throws -> [String: Account] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Account] = [:]
        for container in try containers() {
            let acct = Account(id: container.identifier, name: container.name)
            let req = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
            req.predicate = CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)
            req.unifyResults = false
            try store.enumerateContacts(with: req) { c, _ in out[c.identifier] = acct }
        }
        return out
    }

    func account(of id: String) -> Account? {
        lock.lock(); defer { lock.unlock() }
        guard let c = try? store.containers(matching: CNContainer.predicateForContainerOfContact(withIdentifier: id)).first
        else { return nil }
        return Account(id: c.identifier, name: c.name)
    }

    // MARK: - photos

    /// The contact's photo as JPEG. Photos set through AppleScript are stored only in
    /// the thumbnail field (as TIFF), so fall back to that.
    func photoJPEG(_ c: CNContact) -> Data? {
        guard let raw = c.imageData ?? c.thumbnailImageData else { return nil }
        guard let rep = NSBitmapImageRep(data: raw),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return raw }
        return jpg
    }

    func setPhoto(_ id: String, jpeg: Data) throws {
        lock.lock(); defer { lock.unlock() }
        // Fallback only: Contacts keeps the previous photo's crop and applies it to a photo
        // saved here, so it can show off-center. NotesBridge.setPhoto (Contacts.app) doesn't.
        try retrying {
            let c = try card(id, keys: [CNContactImageDataKey as CNKeyDescriptor])
            let m = c.mutableCopy() as! CNMutableContact
            m.imageData = jpeg
            let req = CNSaveRequest()
            req.update(m)
            try store.execute(req)
        }
    }

    /// Square, centre-cropped avatar, or nil if the card has no photo.
    func thumbnail(_ id: String, px: Int) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        guard let c = try? card(id, keys: [CNContactThumbnailImageDataKey, CNContactImageDataKey].map { $0 as CNKeyDescriptor }),
              let raw = c.thumbnailImageData ?? c.imageData, let src = NSImage(data: raw),
              src.size.width > 0, src.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        let side = CGFloat(px)
        let scale = max(side / src.size.width, side / src.size.height)
        let w = src.size.width * scale, h = src.size.height * scale
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        src.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: px, height: px))
        img.addRepresentation(rep)
        return img
    }

    // MARK: - moving and merging

    /// A brand-new card with every copyable field of `c` (no Notes).
    func copyOf(_ c: CNContact) -> CNMutableContact {
        let m = CNMutableContact()
        m.contactType = c.contactType
        m.namePrefix = c.namePrefix; m.givenName = c.givenName; m.middleName = c.middleName
        m.familyName = c.familyName; m.previousFamilyName = c.previousFamilyName
        m.nameSuffix = c.nameSuffix; m.nickname = c.nickname
        m.phoneticGivenName = c.phoneticGivenName; m.phoneticMiddleName = c.phoneticMiddleName
        m.phoneticFamilyName = c.phoneticFamilyName
        m.phoneticOrganizationName = c.phoneticOrganizationName
        m.organizationName = c.organizationName; m.departmentName = c.departmentName
        m.jobTitle = c.jobTitle
        m.birthday = c.birthday; m.nonGregorianBirthday = c.nonGregorianBirthday; m.dates = c.dates
        m.phoneNumbers = c.phoneNumbers; m.emailAddresses = c.emailAddresses
        m.postalAddresses = c.postalAddresses; m.urlAddresses = c.urlAddresses
        m.contactRelations = c.contactRelations; m.socialProfiles = c.socialProfiles
        m.instantMessageAddresses = c.instantMessageAddresses
        m.imageData = photoJPEG(c)
        return m
    }

    /// Copy the card into another account and delete the original. Returns the new id.
    func move(_ id: String, to containerID: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        return try retrying {
            let c = try card(id)
            let copy = copyOf(c)
            let req = CNSaveRequest()
            req.add(copy, toContainerWithIdentifier: containerID)
            req.delete(c.mutableCopy() as! CNMutableContact)
            try store.execute(req)
            return copy.identifier
        }
    }

    /// Add src's fields to dst, then delete src. Returns dstID.
    func merge(_ srcID: String, into dstID: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        return try retrying {
            let src = try card(srcID)
            let dst = try card(dstID).mutableCopy() as! CNMutableContact
            func union<T>(_ a: [CNLabeledValue<T>], _ b: [CNLabeledValue<T>], _ key: (T) -> String) -> [CNLabeledValue<T>] {
                var seen = Set(a.map { key($0.value) })
                var r = a
                for v in b where !seen.contains(key(v.value)) { r.append(v); seen.insert(key(v.value)) }
                return r
            }
            dst.phoneNumbers = union(dst.phoneNumbers, src.phoneNumbers) { $0.stringValue.filter { $0.isNumber } }
            dst.emailAddresses = union(dst.emailAddresses, src.emailAddresses) { ($0 as String).lowercased() }
            dst.urlAddresses = union(dst.urlAddresses, src.urlAddresses) { ($0 as String).lowercased() }
            dst.postalAddresses = union(dst.postalAddresses, src.postalAddresses) {
                "\($0.street)|\($0.city)|\($0.postalCode)".lowercased()
            }
            dst.socialProfiles = union(dst.socialProfiles, src.socialProfiles) { "\($0.service)|\($0.username)".lowercased() }
            if dst.birthday == nil { dst.birthday = src.birthday }
            if dst.imageData == nil && dst.thumbnailImageData == nil { dst.imageData = photoJPEG(src) }
            if dst.organizationName.isEmpty { dst.organizationName = src.organizationName }
            if dst.jobTitle.isEmpty { dst.jobTitle = src.jobTitle }
            if dst.nickname.isEmpty { dst.nickname = src.nickname }
            let req = CNSaveRequest()
            req.update(dst)
            req.delete(src.mutableCopy() as! CNMutableContact)
            try store.execute(req)
            return dstID
        }
    }

    /// Other cards in the account with this card's full name.
    func sameName(as id: String, in containerID: String) throws -> [(id: String, name: String)] {
        lock.lock(); defer { lock.unlock() }
        let want = fullName(try card(id)).lowercased().trimmingCharacters(in: .whitespaces)
        if want.isEmpty { return [] }
        let req = CNContactFetchRequest(keysToFetch: Self.listKeys)
        req.predicate = CNContact.predicateForContactsInContainer(withIdentifier: containerID)
        req.unifyResults = false
        var hits: [(id: String, name: String)] = []
        try store.enumerateContacts(with: req) { c, _ in
            let n = self.fullName(c)
            if c.identifier != id && n.lowercased().trimmingCharacters(in: .whitespaces) == want {
                hits.append((c.identifier, n))
            }
        }
        return hits
    }

    // MARK: - fields

    /// Save the profile link in the card's URL field labelled "Instagram": the first instagram.com
    /// URL gets the new link and the label, any other instagram.com URLs are deleted.
    func setInstagramURL(_ id: String, url: String) throws {
        lock.lock(); defer { lock.unlock() }
        try retrying {
            let c = try card(id, keys: [CNContactUrlAddressesKey as CNKeyDescriptor])
            var found = false
            var urls: [CNLabeledValue<NSString>] = []
            for lv in c.urlAddresses {
                guard (lv.value as String).localizedCaseInsensitiveContains("instagram.com") else { urls.append(lv); continue }
                if !found {
                    urls.append(lv.settingLabel("Instagram", value: url as NSString))
                    found = true
                }
            }
            if !found { urls.append(CNLabeledValue(label: "Instagram", value: url as NSString)) }
            let m = c.mutableCopy() as! CNMutableContact
            m.urlAddresses = urls
            let req = CNSaveRequest()
            req.update(m)
            try store.execute(req)
        }
    }

    /// Delete every instagram.com URL from the card.
    func deleteInstagramURLs(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let c = try card(id, keys: [CNContactUrlAddressesKey as CNKeyDescriptor])
        try deleteURLs(id, values: c.urlAddresses.map { $0.value as String }.filter { $0.localizedCaseInsensitiveContains("instagram.com") })
    }

    /// Delete these URL values from the card.
    func deleteURLs(_ id: String, values: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        try retrying {
            let c = try card(id, keys: [CNContactUrlAddressesKey as CNKeyDescriptor])
            let m = c.mutableCopy() as! CNMutableContact
            let drop = Set(values)
            m.urlAddresses = c.urlAddresses.filter { !drop.contains($0.value as String) }
            let req = CNSaveRequest()
            req.update(m)
            try store.execute(req)
        }
    }

    /// Rewrite phone numbers: one change per number on the card, in order.
    func applyPhones(_ id: String, changes: [Phones.Change]) throws {
        lock.lock(); defer { lock.unlock() }
        try retrying {
            let c = try card(id, keys: [CNContactPhoneNumbersKey as CNKeyDescriptor])
            let current = c.phoneNumbers
            guard current.count == changes.count,
                  zip(current, changes).allSatisfy({ $0.value.stringValue == $1.old })
            else { throw Fail(message: "phone list changed") }
            var out: [CNLabeledValue<CNPhoneNumber>] = []
            for (lv, ch) in zip(current, changes) {
                if ch.isDelete { continue }
                if let new = ch.new {
                    out.append(lv.settingValue(CNPhoneNumber(stringValue: new)))
                } else {
                    out.append(lv)
                }
            }
            let m = c.mutableCopy() as! CNMutableContact
            m.phoneNumbers = out
            let req = CNSaveRequest()
            req.update(m)
            try store.execute(req)
        }
    }

    // MARK: - backups

    static func vcardEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ";", with: "\\;")
    }

    /// Save a .vcf of the card, with its photo and the given Notes text. Returns the file.
    @discardableResult
    func backup(_ id: String, to dir: URL, note: String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let c = try card(id)
        // Serialise a copy: the original's Notes can't be read here, and the
        // serialiser would trip over the unfetched property.
        var text = String(data: try CNContactVCardSerialization.data(with: [copyOf(c)]), encoding: .utf8) ?? ""
        var extra = ""
        if !note.isEmpty { extra += "NOTE:\(Self.vcardEscape(note))\r\n" }
        if let img = photoJPEG(c), !text.contains("PHOTO") {
            extra += "PHOTO;ENCODING=b;TYPE=JPEG:\(img.base64EncodedString())\r\n"
        }
        if !extra.isEmpty, let r = text.range(of: "END:VCARD", options: .backwards) {
            text.replaceSubrange(r, with: extra + "END:VCARD")
        }
        let safe = fullName(c).replacingOccurrences(of: "/", with: "-")
        let short = id.split(separator: "-").first.map(String.init) ?? id
        let name = "\(safe.isEmpty ? "contact" : safe)_\(short).vcf"
        // Nothing changed since the last backup of this card: that one still covers it.
        if let last = BackupRetention.latest(named: name, in: dir.deletingLastPathComponent()),
           (try? Data(contentsOf: last)) == Data(text.utf8) {
            return last
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
