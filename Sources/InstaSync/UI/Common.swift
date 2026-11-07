import AppKit
import InstaSyncCore
import SwiftUI

func ago(_ date: Date?) -> String {
    guard let date else { return "never" }
    let s = Date().timeIntervalSince(date)
    if s < 60 { return "just now" }
    if s < 3600 { return "\(Int((s / 60).rounded())) min ago" }
    if s < 86400 { return "\(Int((s / 3600).rounded())) h ago" }
    let d = Int((s / 86400).rounded())
    return "\(d) day\(d == 1 ? "" : "s") ago"
}

func ago(_ ts: Double?) -> String { ago(ts.map { Date(timeIntervalSince1970: $0) }) }

func instagramURL(_ handle: String) -> URL { URL(string: Handles.profileURL(handle))! }

func googleInstagramSearch(_ name: String) -> URL {
    var c = URLComponents(string: "https://www.google.com/search")!
    c.queryItems = [URLQueryItem(name: "q", value: "site:instagram.com \"\(name)\"")]
    return c.url!
}

struct Initial: View {
    let name: String
    var body: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.18))
            Text(String(name.trimmingCharacters(in: .whitespaces).first ?? "?").uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

struct ContactAvatar: View {
    private var model: AppModel { .shared }
    let id: String
    let name: String
    var size: CGFloat = 28
    @ViewState private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() } else { Initial(name: name) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: id) { image = await model.images.contact(id) }
    }
}

struct InstagramAvatar: View {
    private var model: AppModel { .shared }
    let username: String
    var size: CGFloat = 56
    @ViewState private var image: NSImage?
    @ViewState private var tried = false

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() } else { Initial(name: username) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: username) {
            let url = model.following?.users.first { $0.username == username }?.profilePicURL
            image = await model.images.instagram(username, url: url)
        }
    }
}

struct AccountBadge: View {
    let name: String
    var body: some View {
        let icloud = name == "iCloud"
        Text(name == "Personal" ? "Google · Personal" : name)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(icloud ? Color.blue.opacity(0.14) : Color.orange.opacity(0.16)))
            .foregroundStyle(icloud ? Color.blue : Color.orange)
    }
}

struct HandleLink: View {
    let handle: String
    var body: some View {
        Link("@\(handle)", destination: instagramURL(handle))
            .help("Open in your browser")
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct EmptyState: View {
    let title: String
    var message: String = ""
    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            if !message.isEmpty { Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))
    }
}

/// SwiftUI's `@State` is a macro in this SDK whose plugin ships only with full Xcode, not the
/// Command Line Tools. Naming the property wrapper type through an alias skips the macro.
typealias ViewState<Value> = SwiftUI.State<Value>
