import Foundation
import InstaSyncCore

/// Contacts' Notes, through AppleScript to Contacts.app (the Contacts framework can't
/// read Notes without a restricted Apple entitlement). Only used when a job changes a
/// card: backups include Notes, and a card moved to iCloud keeps them. Runs `osascript`,
/// so it's safe off the main thread; macOS asks once to let Insta Sync control Contacts.
final class NotesBridge: @unchecked Sendable {
    struct Fail: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func run(_ script: String, _ args: [String] = []) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"] + args
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        try p.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = errors.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        errDone.wait()
        if p.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if msg.contains("-1743") || msg.contains("Not authorized") {
                throw Fail(message: "Insta Sync isn't allowed to control Contacts. Allow it in System Settings → Privacy & Security → Automation → Insta Sync → Contacts.")
            }
            throw Fail(message: msg.isEmpty ? "osascript failed" : msg)
        }
        var s = String(data: outData, encoding: .utf8) ?? ""
        while s.hasSuffix("\n") { s.removeLast() }
        return s
    }

    func note(_ id: String) throws -> String {
        try run("""
        on run argv
        tell application "Contacts" to set nt to note of person id (item 1 of argv)
        if nt is missing value then return ""
        return nt
        end run
        """, [id])
    }

    func setNote(_ id: String, _ note: String) throws {
        _ = try run("""
        on run argv
        tell application "Contacts"
          set note of person id (item 1 of argv) to (item 2 of argv)
          save
        end tell
        end run
        """, [id, note])
    }

    /// Contacts.app can take a moment to see a card the framework just created.
    func setNoteRetrying(_ id: String, _ note: String) throws {
        for attempt in 0..<10 {
            do { return try setNote(id, note) } catch {
                if attempt == 9 { throw error }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    /// Set a contact's photo through Contacts.app, as a JPEG. Contacts.app resets the photo's
    /// crop, so the picture shows centered (the Contacts framework keeps an old photo's crop,
    /// which leaves new photos off-center).
    func setPhoto(_ id: String, jpeg: Data) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("instasync-\(UUID().uuidString).jpg")
        try jpeg.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try run("""
        on run argv
        set img to read (POSIX file (item 2 of argv)) as JPEG picture
        tell application "Contacts"
          set image of person id (item 1 of argv) to img
          save
        end tell
        end run
        """, [id, file.path])
    }

    /// Save the Instagram link through Contacts.app (fallback when the framework save fails):
    /// the first instagram.com URL gets the link and the label "Instagram", others are deleted.
    func setInstagramURL(_ id: String, url: String) throws {
        _ = try run("""
        on run argv
        tell application "Contacts"
          set p to person id (item 1 of argv)
          set found to false
          repeat with u in (every url of p whose value contains "instagram.com")
            if found then
              delete u
            else
              set value of u to (item 2 of argv)
              set label of u to "Instagram"
              set found to true
            end if
          end repeat
          if not found then make new url at end of urls of p with properties {label:"Instagram", value:(item 2 of argv)}
          save
        end tell
        end run
        """, [id, url])
    }

    /// Rewrite phone numbers through Contacts.app (fallback when the framework save fails):
    /// one change per number on the card, in order. Nothing is changed unless every number
    /// is still what the plan expects, in the same order.
    func applyPhones(_ id: String, changes: [Phones.Change]) throws {
        _ = try run("""
        on run argv
        tell application "Contacts"
          set p to person id (item 1 of argv)
          set n to ((count of argv) - 1) div 2
          if (count of phones of p) is not n then error "phone list changed"
          repeat with i from 1 to n
            if (value of phone i of p) is not (item (i * 2) of argv) then error "phone list changed"
          end repeat
          repeat with i from n to 1 by -1
            set newValue to item (i * 2 + 1) of argv
            if newValue is "" then
              delete phone i of p
            else if newValue is not (item (i * 2) of argv) then
              set value of phone i of p to newValue
            end if
          end repeat
          save
        end tell
        end run
        """, [id] + changes.flatMap { [$0.old, $0.new ?? $0.old] })
    }
}
