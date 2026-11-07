import InstaSyncCore
import SwiftUI

struct CleanupView: View {
    private var model: AppModel { .shared }
    @ViewState private var confirm: Action?
    @ViewState private var backups: [AppModel.BackupFolder] = []

    enum Action: Identifiable {
        case phones(Int)
        var id: String { "phones" }
    }

    var body: some View {
        let phones = model.phoneRows
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Cleanup & backups",
                           subtitle: "Every sync standardizes phone numbers too. Each contact is backed up before it's changed.")
                phonesCard(phones)
                backupsCard
            }
            .padding(20)
        }
        .onAppear { backups = model.backups() }
        .onChange(of: model.people) { backups = model.backups() }
        .onChange(of: model.backupsTrimmed) { backups = model.backups() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { a in
            switch a {
            case .phones: Button("Standardize") { model.fixPhones() }
            }
        } message: { _ in Text("Each contact is backed up first.") }
    }

    private var confirmTitle: String {
        switch confirm {
        case .phones(let n): return "Standardize phone numbers on \(n) iCloud contact\(n == 1 ? "" : "s")?"
        case nil: return ""
        }
    }

    private func phonesCard(_ rows: [PhoneRow]) -> some View {
        let changes = rows.reduce(0) { $0 + $1.plan.phones.filter { $0.new != nil }.count }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Phone numbers").font(.headline)
                Text("Formats iCloud contacts' numbers as +63 917 123 4567 (landlines +63 2 8123 4567, US +1 212 555 0123) and removes a number that appears twice on the same contact. Numbers it can't safely recognize are left as they are.")
                    .font(.callout).foregroundStyle(.secondary)
                if rows.isEmpty {
                    Text("All iCloud phone numbers are already standard. ✓").fontWeight(.medium)
                } else {
                    Text("**\(changes)** change\(changes == 1 ? "" : "s") on **\(rows.count)** contact\(rows.count == 1 ? "" : "s"):")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(rows) { r in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.name).fontWeight(.medium)
                                    ForEach(Array(r.plan.phones.enumerated()), id: \.offset) { _, ph in
                                        if let new = ph.new {
                                            HStack(spacing: 4) {
                                                Text(ph.old).foregroundStyle(.secondary)
                                                Text("→").foregroundStyle(.secondary)
                                                if new.isEmpty { Text("duplicate, removed").italic() } else { Text(new).foregroundStyle(.green) }
                                            }
                                            .font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    Button("Standardize \(rows.count) contact\(rows.count == 1 ? "" : "s")") { confirm = .phones(rows.count) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.jobs.isBusy)
                }
            }
        }
    }

    private var backupsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Backups").font(.headline)
                    Spacer()
                    Button("Show in Finder") { model.reveal(model.storage.paths.backups) }.controlSize(.small)
                }
                Text("Saved before any contact is moved, merged, cleaned or has its numbers reformatted, with its photo and Notes. Each contact keeps its original backup and its 2 latest different versions; older ones are deleted automatically. Restore opens the card in Contacts, which asks before importing.")
                    .font(.callout).foregroundStyle(.secondary)
                if !backups.isEmpty { Text(backupTotal).font(.caption).foregroundStyle(.secondary) }
                if backups.isEmpty {
                    Text("No backups yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(backups.enumerated()), id: \.element.id) { i, b in
                        BackupFolderRow(folder: b, startOpen: i == 0)
                    }
                }
            }
        }
    }
}

private extension CleanupView {
    var backupTotal: String {
        let files = backups.flatMap(\.files)
        let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(files.count) backup\(files.count == 1 ? "" : "s") · \(size)"
    }
}

struct BackupFolderRow: View {
    private var model: AppModel { .shared }
    let folder: AppModel.BackupFolder
    let startOpen: Bool
    @ViewState private var expanded: Bool?

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded ?? startOpen }, set: { expanded = $0 })) {
            VStack(spacing: 2) {
                ForEach(folder.files, id: \.self) { f in
                    HStack {
                        Text(displayName(f)).lineLimit(1)
                        Spacer()
                        Text(size(f)).font(.caption).foregroundStyle(.secondary)
                        Button("Show") { model.reveal(f) }
                        Button("Restore") { model.restore(f) }
                    }
                    .controlSize(.small)
                    .padding(.vertical, 2)
                }
            }
            .padding(.leading, 6)
        } label: {
            HStack {
                Text(folder.date?.formatted(date: .abbreviated, time: .standard) ?? folder.url.lastPathComponent).fontWeight(.medium)
                Text("\(folder.files.count) contact\(folder.files.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { model.reveal(folder.url) }.controlSize(.small)
            }
        }
    }

    private func displayName(_ f: URL) -> String {
        let stem = f.deletingPathExtension().lastPathComponent
        return PyRegex("_[0-9A-F]{8}$").sub(stem)
    }

    private func size(_ f: URL) -> String {
        let n = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return n > 1_000_000 ? String(format: "%.1f MB", Double(n) / 1e6) : "\(max(1, n / 1000)) KB"
    }
}
