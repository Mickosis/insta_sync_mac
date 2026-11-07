import InstaSyncCore
import SwiftUI

struct AddView: View {
    private var model: AppModel { .shared }
    @ViewState private var filter = ""
    @ViewState private var showTagged = false
    @ViewState private var open: String?
    @ViewState private var handle = ""
    @FocusState private var handleFocused: Bool

    var body: some View {
        let untagged = model.people.filter { $0.handle == nil }.count
        let term = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let list = model.people.filter { p in
            (showTagged || p.handle == nil)
                && (term.isEmpty || p.name.lowercased().contains(term) || p.hint.lowercased().contains(term)
                    || p.emails.contains { $0.lowercased().contains(term) })
        }
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Add an Instagram profile",
                       subtitle: "\(untagged) contact\(untagged == 1 ? "" : "s") without an Instagram handle. Click one, then type their username or paste their profile link. It saves their profile link in an Instagram URL field, moves the contact to iCloud and sets the HD photo.")
            HStack {
                TextField("Filter by name, phone or email", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Toggle("Also show contacts that already have a handle", isOn: $showTagged)
                    .toggleStyle(.checkbox)
                Spacer()
            }
            if list.isEmpty && model.loaded {
                Card { EmptyState(title: term.isEmpty ? "Every contact has an Instagram handle. ✓" : "No contacts match.") }
                Spacer()
            } else {
                List(list) { p in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ContactAvatar(id: p.id, name: p.name, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(p.name).fontWeight(.medium)
                                    if model.noneIDs.contains(p.id) {
                                        Text("None").font(.caption2).padding(.horizontal, 5)
                                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                    }
                                }
                                Text(p.hint).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let h = p.handle { HandleLink(handle: h).font(.callout) }
                            AccountBadge(name: model.account(p.id))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(p) }
                        if open == p.id {
                            HStack {
                                TextField("@username or instagram.com/username", text: $handle)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 320)
                                    .focused($handleFocused)
                                    .onSubmit { submit(p) }
                                Button("Link") { submit(p) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(handle.trimmingCharacters(in: .whitespaces).isEmpty)
                                Link("Search on Instagram ↗", destination: googleInstagramSearch(p.name)).font(.caption)
                                Spacer()
                            }
                            .padding(.leading, 40)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 160, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    private func toggle(_ p: Person) {
        if open == p.id { open = nil; return }
        open = p.id
        handle = p.handle.map { "@" + $0 } ?? ""
        DispatchQueue.main.async { handleFocused = true }
    }

    private func submit(_ p: Person) {
        let h = handle.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        model.link(p, handle: h, kind: "add")
        open = nil
    }
}
