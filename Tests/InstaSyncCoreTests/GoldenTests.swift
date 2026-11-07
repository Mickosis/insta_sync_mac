import Foundation
import Testing
@testable import InstaSyncCore

/// golden.json holds the old Python version's answers for a list of made-up inputs.
/// The Swift port must give the same answers.
struct Golden {
    static let data: [String: Any] = {
        let url = Bundle.module.url(forResource: "golden", withExtension: "json")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    static func rows(_ key: String) -> [[Any]] { data[key] as! [[Any]] }
    static func opt(_ v: Any) -> String? { v is NSNull ? nil : (v as! String) }
}

@Test func phones() {
    for r in Golden.rows("phones") {
        #expect(Phones.format(r[0] as? String) == Golden.opt(r[1]), "\(r[0])")
    }
}

@Test func usernames() {
    for r in Golden.rows("usernames") {
        #expect(Handles.username(from: r[0] as! String) == Golden.opt(r[1]), "\(r[0])")
    }
}

@Test func stripHTC() {
    for r in Golden.rows("strip_htc") {
        #expect(Cleanup.stripHTC(r[0] as? String) == r[1] as! String, "\(r[0])")
    }
}

@Test func mergeNotes() {
    for r in Golden.rows("merges") {
        #expect(Cleanup.mergeNotes(r[0] as? String, r[1] as? String) == r[2] as! String, "\(r[0]) + \(r[1])")
    }
}

@Test func googleProfileLinks() {
    for r in Golden.rows("gprofile") {
        #expect(Cleanup.gprofileRE.matches(r[0] as! String) == r[1] as! Bool, "\(r[0])")
    }
}

@Test func tokens() {
    for r in Golden.rows("tokens") {
        #expect(Matching.tokens(r[0] as? String) == r[1] as! [String], "\(r[0])")
    }
}

@Test func matchScores() {
    for r in Golden.rows("scores") {
        let c = r[0] as! [String: String], u = r[1] as! [String: String]
        let got = Matching.score(first: c["first"]!, last: c["last"]!, nick: c["nick"]!,
                                 username: u["username"]!, fullName: u["full_name"]!)
        #expect(got == r[2] as! Int, "\(c) ↔ \(u)")
    }
}

@Test func phonePlanDedupes() {
    let p = Phones.plan(["09171234567", "+63 917 123 4567", "1-800-MY-APPLE"])
    #expect(p.changed)
    #expect(p.phones.map(\.new) == ["+63 917 123 4567", "", nil])
    #expect(p.skipped == ["1-800-MY-APPLE"])
    #expect(!Phones.plan(["+63 917 123 4567"]).changed)
}

@Test func findMatchesOrder() {
    let people = [Person(id: "1", first: "Juan", last: "Cruz"), Person(id: "2", first: "Ana", last: "Lim"),
                  Person(id: "3", first: "Zed", last: "Nobody")]
    let users = [FollowedUser(username: "juancruz", fullName: "Juan Cruz"), FollowedUser(username: "juan.cruz"),
                 FollowedUser(username: "analim", fullName: "Ana")]
    let rows = Matching.find(people, users)
    #expect(rows.map(\.contact.id) == ["1", "2"])
    #expect(rows[0].candidates.map(\.user.username) == ["juancruz", "juan.cruz"])
}

@Test func handleComesFromInstagramURL() {
    #expect(Person(id: "x", note: "IG: @fromnotes", urls: ["https://www.instagram.com/fromurl/"]).handle == "fromurl")
    #expect(Person(id: "y", note: "@fromnotes").handle == nil)
}
