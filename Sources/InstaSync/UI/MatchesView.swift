import InstaSyncCore
import SwiftUI

struct MatchesView: View {
    private var model: AppModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.following == nil {
                PageHeader(title: "Find matches", subtitle: "Matches come from the accounts you follow on Instagram.")
                Card {
                    VStack(spacing: 12) {
                        Text("First, fetch the accounts you follow.").font(.headline)
                        Text("Insta Sync reads your following list in its hidden Instagram browser and keeps it for 7 days.")
                            .foregroundStyle(.secondary)
                        Button("Fetch following list") { model.refreshFollowing() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.jobs.isBusy)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                }
                Spacer()
            } else if let rows = model.visibleMatches {
                header(rows)
                if rows.isEmpty {
                    Card { EmptyState(title: "Nothing to review.", message: "Every contact that might be someone you follow has been answered.") }
                    footer
                    Spacer()
                } else {
                    batchBar(rows)
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(rows) { MatchRowView(row: $0) }
                            footer.padding(.top, 6)
                        }
                    }
                }
            } else {
                PageHeader(title: "Find matches", subtitle: "Comparing your contacts with the accounts you follow…")
                ProgressView().frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(20)
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    private func header(_ rows: [Matching.Row]) -> some View {
        let f = model.following!
        let none = model.noneIDs.count
        return PageHeader(
            title: "Find matches",
            subtitle: "\(rows.count) contact\(rows.count == 1 ? "" : "s") to review · \(f.users.count) accounts you follow, updated \(ago(f.fetchedAt))"
                + (f.isStale ? " (out of date)" : "")
                + (none > 0 ? " · \(none) answered “None”" : "")
        ) {
            HStack {
                if none > 0 { Button("Ask again") { model.resetNone() }.help("Show contacts you answered None for") }
                Button("Refresh following") { model.refreshFollowing() }.disabled(model.jobs.isBusy)
            }
        }
    }

    private func batchBar(_ rows: [Matching.Row]) -> some View {
        let strong = rows.filter { ($0.candidates.first?.score ?? 0) >= 90 }
        let n = model.picks.count
        return HStack(spacing: 10) {
            if n > 0 { Text("**\(n)** selected") } else {
                Text("Click a match in each row you want to link").foregroundStyle(.secondary)
            }
            Button("Select strong matches (\(strong.count))") {
                for r in strong { model.picks[r.id] = r.candidates[0].user.username }
            }
            .disabled(strong.isEmpty)
            Button("Clear") { model.picks = [:] }.disabled(n == 0)
            Spacer()
            Text("Each: Instagram link · move to iCloud · HD photo").font(.caption).foregroundStyle(.secondary)
            Button(n > 0 ? "Link \(n)" : "Link") { model.linkPicked() }
                .buttonStyle(.borderedProminent)
                .disabled(n == 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.bar))
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text("Someone not listed here? Every contact without a handle is on").foregroundStyle(.secondary)
            Button("Add") { model.section = .add }.buttonStyle(.link)
        }
        .font(.callout)
    }
}

struct MatchRowView: View {
    private var model: AppModel { .shared }
    let row: Matching.Row
    @ViewState private var searching = false
    @ViewState private var query = ""
    @ViewState private var hits: [Matching.Candidate] = []

    private var contact: Person { row.contact }

    var body: some View {
        let picked = model.picks[row.id]
        let shown = Set(row.candidates.map(\.user.username))
        let extra = hits.filter { !shown.contains($0.user.username) }
        let typed = typedHandle(query)
        let explicit = query.hasPrefix("@") || query.localizedCaseInsensitiveContains("instagram.com/")
        let showTyped = searching && typed != nil && (explicit || hits.isEmpty)
            && !shown.contains(typed!) && !hits.contains { $0.user.username == typed }
        let allShown = shown.union(extra.map(\.user.username)).union(showTyped ? [typed!] : [])

        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(contact.name).font(.headline)
                    Text(contact.hint).font(.caption).foregroundStyle(.secondary)
                    AccountBadge(name: model.account(contact.id))
                    Spacer()
                    Button("None") { model.answerNone(row.id) }.help("No Instagram account here. Don't ask again.")
                    Button("Skip") { model.skip(row.id) }.help("Ask again next time")
                    Button(searching ? "Hide search" : "Search…") {
                        searching.toggle()
                        if searching { query = contact.name; runSearch() } else { hits = [] }
                    }
                    .help("None of these? Search the accounts you follow, or type a username")
                }
                .controlSize(.small)
                if searching {
                    HStack {
                        TextField("Search accounts you follow, or type @username", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 340)
                            .onChange(of: query) { runSearch() }
                        Text(searchHint(typed: typed)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Link("Search on Instagram ↗", destination: googleInstagramSearch(contact.name)).font(.caption)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(row.candidates, id: \.user.username) { c in
                            CandidateCard(username: c.user.username, fullName: c.user.fullName,
                                          tag: Matching.label(c.score), strong: c.score >= 90,
                                          selected: picked == c.user.username) { toggle(c.user.username) }
                        }
                        ForEach(extra, id: \.user.username) { c in
                            CandidateCard(username: c.user.username, fullName: c.user.fullName, tag: "Search result",
                                          manual: true, selected: picked == c.user.username) { toggle(c.user.username) }
                        }
                        if showTyped, let t = typed {
                            CandidateCard(username: t, fullName: "", tag: "Use this username", manual: true, noThumb: true,
                                          selected: picked == t) { toggle(t) }
                        }
                    }
                    .padding(2)
                }
                if let p = picked, !allShown.contains(p) {
                    HStack(spacing: 4) {
                        Text("Selected:").foregroundStyle(.secondary)
                        HandleLink(handle: p)
                    }
                    .font(.caption)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: picked == nil ? 0 : 1.5))
    }

    private func toggle(_ u: String) {
        model.picks[row.id] = model.picks[row.id] == u ? nil : u
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        hits = q.isEmpty ? [] : model.searchFollowing(q, for: contact)
    }

    private func searchHint(typed: String?) -> String {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if !hits.isEmpty { return "\(hits.count) account\(hits.count == 1 ? "" : "s") you follow" }
        return "No accounts you follow match." + (typed != nil ? " You can still use the username." : "")
    }

    /// @handle, bare handle, or an instagram.com link (as typed in the search field).
    private func typedHandle(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.contains("instagram.com/") || !t.contains(" ") else { return nil }
        return Handles.username(from: t)?.lowercased()
    }
}

struct CandidateCard: View {
    let username: String
    let fullName: String
    let tag: String
    var strong = false
    var manual = false
    var noThumb = false
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                if noThumb { Initial(name: username).frame(width: 56, height: 56) } else { InstagramAvatar(username: username) }
                Text(fullName.isEmpty ? username : fullName).font(.callout.weight(.medium)).lineLimit(1)
                Text("@\(username)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(tag)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(strong ? Color.green.opacity(0.18) : manual ? Color.purple.opacity(0.15) : Color.secondary.opacity(0.14)))
                    .foregroundStyle(strong ? Color.green : manual ? Color.purple : Color.secondary)
            }
            .frame(width: 130)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2),
                                                                     lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selected ? "Click again to unselect" : "Click to select")
        .contextMenu {
            Link("Open @\(username) in browser", destination: instagramURL(username))
        }
    }
}
