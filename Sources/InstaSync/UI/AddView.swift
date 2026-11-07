import AppKit
import InstaSyncCore
import SwiftUI
import UniformTypeIdentifiers

struct AddView: View {
    private var model: AppModel { .shared }
    @ViewState private var filter = ""
    @ViewState private var showTagged = false
    @ViewState private var open: String?
    @ViewState private var handle = ""
    @ViewState private var photoData: Data?
    @ViewState private var photoLink = ""
    @ViewState private var dropTargeted = false
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
            PageHeader(title: "Add to iCloud",
                       subtitle: "\(untagged) contact\(untagged == 1 ? "" : "s") without an Instagram handle. Click one, then type their username or paste their profile link: it saves the link in an Instagram URL field, moves the contact to iCloud and sets the HD photo. Or leave the handle empty and move them to iCloud as they are, with a photo of your own if you like.")
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
                            if p.handle == nil { photoRow(p).padding(.leading, 40) }
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

    /// Move without a handle, with an optional photo. Off while a handle is typed: the
    /// Instagram photo wins, and sync would replace a manual one anyway.
    private func photoRow(_ p: Person) -> some View {
        let handleTyped = !handle.trimmingCharacters(in: .whitespaces).isEmpty
        let link = photoLink.trimmingCharacters(in: .whitespaces)
        let hasPhoto = photoData != nil || !link.isEmpty
        let inICloud = model.isICloud(p.id)
        return HStack(spacing: 10) {
            dropZone(enabled: !handleTyped)
            TextField("or paste an image link (https://…)", text: $photoLink)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .disabled(handleTyped)
                .onChange(of: photoLink) { _, new in
                    if !new.isEmpty { photoData = nil }
                }
            if hasPhoto {
                Button("Clear") { resetPhoto() }
                    .disabled(handleTyped)
            }
            Button(inICloud ? "Save photo" : "Move to iCloud") { move(p) }
                .disabled(handleTyped || (inICloud && !hasPhoto))
            Spacer()
        }
    }

    private func dropZone(enabled: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return ZStack {
            if let photoData, let image = NSImage(data: photoData) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text("Drop a photo").font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(4)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(shape)
        .overlay(shape.strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                    style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: photoData == nil ? [4] : [])))
        .opacity(enabled ? 1 : 0.4)
        .onDrop(of: [.fileURL, .image, .url], isTargeted: $dropTargeted) { providers in
            enabled && drop(providers)
        }
    }

    /// Finder files and image data become the photo; a web link fills the link field.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let item = providers.first else { return false }
        if item.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                let data = url.flatMap { try? Data(contentsOf: $0) }
                DispatchQueue.main.async { setDropped(data) }
            }
        } else if item.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            item.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                DispatchQueue.main.async { setDropped(data) }
            }
        } else if item.canLoadObject(ofClass: URL.self) {
            _ = item.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url { photoLink = url.absoluteString }
                }
            }
        } else {
            return false
        }
        return true
    }

    private func setDropped(_ data: Data?) {
        guard let data, NSImage(data: data) != nil else {
            model.show("That isn't an image.")
            return
        }
        photoLink = ""
        photoData = data
    }

    private func resetPhoto() {
        photoData = nil
        photoLink = ""
    }

    private func move(_ p: Person) {
        var source: AppModel.PhotoSource?
        if let photoData {
            source = .data(photoData)
        } else if !photoLink.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let url = model.photoLinkURL(photoLink) else { return }
            source = .link(url)
        }
        model.moveToICloud(p, photo: source)
        resetPhoto()
        open = nil
    }

    private func toggle(_ p: Person) {
        if open == p.id { open = nil; return }
        open = p.id
        handle = p.handle.map { "@" + $0 } ?? ""
        resetPhoto()
        DispatchQueue.main.async { handleFocused = true }
    }

    private func submit(_ p: Person) {
        let h = handle.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        model.link(p, handle: h, kind: "add")
        resetPhoto()
        open = nil
    }
}
