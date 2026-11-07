import InstaSyncCore
import SwiftUI

struct ContactsView: View {
    private var model: AppModel { .shared }
    @ViewState private var selection = Set<String>()
    @ViewState private var editing: Person?
    @ViewState private var editText = ""
    @ViewState private var removing: Person?

    var body: some View {
        let list = model.tagged
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Contacts",
                       subtitle: "Contacts with an Instagram link. Syncing moves them to iCloud and sets the HD profile photo.")
            tiles(list)
            HStack {
                Button("Sync all") { model.sync() }
                    .buttonStyle(.borderedProminent)
                    .disabled(list.isEmpty)
                Button("Sync selected" + (selection.isEmpty ? "" : " (\(selection.count))")) { model.sync(ids: selection) }
                    .disabled(selection.isEmpty)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
            }
            if list.isEmpty && model.loaded {
                Card {
                    EmptyState(title: "No contacts have an Instagram handle yet.",
                               message: "Use Find matches or Add to link a contact to their Instagram.")
                }
                Spacer()
            } else {
                table(list)
            }
        }
        .padding(20)
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.people) { _, people in
            let ids = Set(people.map(\.id))
            selection = selection.filter { ids.contains($0) }
        }
        .sheet(item: $editing) { p in editSheet(p) }
        .confirmationDialog("Remove the Instagram link from \(removing?.name ?? "")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { p in
            Button("Remove @\(p.handle ?? "")", role: .destructive) { model.removeHandle(p) }
        } message: { _ in
            Text("Deletes the Instagram URL field and any handle in Notes. The contact is backed up first.")
        }
    }

    private func tiles(_ list: [Person]) -> some View {
        let inICloud = list.filter { model.isICloud($0.id) }.count
        let toMove = list.count - inICloud
        return HStack(spacing: 10) {
            Tile(value: "\(list.count)", label: "with a handle, of \(model.people.count) contacts" + (model.onlyWithPhones ? " with phone numbers" : ""))
            Tile(value: "\(inICloud)", label: "in iCloud")
            Tile(value: "\(toMove)", label: "to move to iCloud on next sync", attention: toMove > 0)
            Tile(value: model.following.map { "\($0.users.count)" } ?? "–",
                 label: "accounts you follow · " + (model.following.map { ago($0.fetchedAt) } ?? "not fetched"))
            Tile(value: ago(model.lastSync), label: "last photo sync", small: true)
        }
    }

    private func table(_ list: [Person]) -> some View {
        Table(list, selection: $selection) {
            TableColumn("Contact") { p in
                HStack(spacing: 8) {
                    ContactAvatar(id: p.id, name: p.name)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).lineLimit(1)
                        Text(p.hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 180, ideal: 240)
            TableColumn("Instagram") { p in
                if let h = p.handle { HandleLink(handle: h) }
            }
            .width(min: 120, ideal: 160)
            TableColumn("Account") { p in AccountBadge(name: model.account(p.id)) }
                .width(min: 90, ideal: 130)
            TableColumn("Photo synced") { p in
                let rec = model.syncRecord(p)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ago(rec?.syncedAt))
                    if let rec { Text("\(rec.w)×\(rec.h)").font(.caption).foregroundStyle(.secondary) }
                }
                .help(rec.map { Date(timeIntervalSince1970: $0.syncedAt).formatted() } ?? "")
            }
            .width(min: 90, ideal: 110)
            TableColumn("") { p in
                HStack(spacing: 6) {
                    Button("Sync") { model.sync(ids: [p.id]) }
                    Button("Edit") {
                        editText = "@" + (p.handle ?? "")
                        editing = p
                    }
                    Button("Remove") { removing = p }
                }
                .controlSize(.small)
            }
            .width(min: 170, ideal: 180)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minHeight: 160, maxHeight: .infinity)
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty { Button("Sync \(ids.count == 1 ? "" : "\(ids.count) ")contact\(ids.count == 1 ? "" : "s")") { model.sync(ids: ids) } }
        }
    }

    private func editSheet(_ p: Person) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Instagram for \(p.name)").font(.headline)
            TextField("@username or instagram.com/username", text: $editText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { saveEdit(p) }
            Text("Saving links the new account, moves the contact to iCloud and sets the HD photo.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { editing = nil }.keyboardShortcut(.cancelAction)
                Button("Save") { saveEdit(p) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func saveEdit(_ p: Person) {
        let v = editText.trimmingCharacters(in: .whitespaces)
        editing = nil
        guard let new = Handles.username(from: v) else {
            model.show("That isn't a valid Instagram username or profile link.")
            return
        }
        if new.lowercased() != p.handle?.lowercased() { model.link(p, handle: new) }
    }
}

struct Tile: View {
    let value: String
    let label: String
    var attention = false
    var small = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(small ? .title3.weight(.semibold) : .title.weight(.semibold))
                .foregroundStyle(attention ? Color.orange : Color.primary)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(attention ? Color.orange.opacity(0.5) : Color.secondary.opacity(0.15)))
    }
}
