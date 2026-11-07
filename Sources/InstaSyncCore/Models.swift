import Foundation

/// One contact card, as Insta Sync sees it.
public struct Person: Identifiable, Hashable, Sendable {
    public var id: String
    public var first: String
    public var last: String
    public var nick: String
    public var name: String
    public var note: String
    /// First phone number, else first email: shown under the name.
    public var hint: String
    public var phones: [String]
    public var emails: [String]
    public var urls: [String]

    public init(id: String, first: String = "", last: String = "", nick: String = "", name: String = "",
                note: String = "", phones: [String] = [], emails: [String] = [], urls: [String] = []) {
        self.id = id
        self.first = first
        self.last = last
        self.nick = nick
        self.name = name.isEmpty ? "\(first) \(last)".pyStrip : name
        self.note = note
        self.phones = phones
        self.emails = emails
        self.urls = urls
        self.hint = phones.first ?? emails.first ?? ""
    }

    /// The last instagram.com URL on the card.
    public var instagramURL: String? { urls.last { $0.localizedCaseInsensitiveContains("instagram.com") } }

    /// The Instagram handle, from the card's Instagram URL field.
    public var handle: String? { instagramURL.flatMap(Handles.username(from:)) }

    public var googleProfileURLs: [String] { urls.filter { Cleanup.gprofileRE.matches($0) } }
}

/// An Instagram account you follow (cached following list).
public struct FollowedUser: Codable, Hashable, Sendable, Identifiable {
    public var username: String
    public var fullName: String
    public var profilePicURL: String
    public var id: String { username }

    public init(username: String, fullName: String = "", profilePicURL: String = "") {
        self.username = username
        self.fullName = fullName
        self.profilePicURL = profilePicURL
    }

    enum CodingKeys: String, CodingKey {
        case username, fullName = "full_name", profilePicURL = "profile_pic_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        username = try c.decode(String.self, forKey: .username)
        fullName = try c.decodeIfPresent(String.self, forKey: .fullName) ?? ""
        profilePicURL = try c.decodeIfPresent(String.self, forKey: .profilePicURL) ?? ""
    }
}

/// A contacts account (iCloud, Google, On My Mac…).
public struct Account: Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
    public var isICloud: Bool { name == "iCloud" }
}
