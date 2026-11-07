import AppKit
import SwiftUI

@main
struct InstaSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("Insta Sync", id: "main") {
            RootView()
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { AppDelegate.model = model }
        }
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            InstagramCommands(model: model)
            CommandGroup(after: .toolbar) {
                Button("Reload Contacts") { Task { await model.reload() } }
                    .keyboardShortcut("r")
                Toggle("Only Contacts with Phone Numbers", isOn: Binding(get: { model.onlyWithPhones }, set: { model.onlyWithPhones = $0 }))
            }
        }

        Window("Instagram", id: "instagram") {
            InstagramWindow()
        }
        .defaultSize(width: 900, height: 820)
        .windowResizability(.contentMinSize)
    }
}

struct InstagramCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Instagram") {
            Button(model.isLoggedIn ? "Show Instagram Window" : "Log In…") { openWindow(id: "instagram") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Refresh Following List") { model.refreshFollowing() }
                .disabled(!model.isLoggedIn)
            Divider()
            Button("Log Out") { Task { await model.logOut() } }
                .disabled(!model.isLoggedIn)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model = Self.model, model.jobs.isBusy else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "A task is still running"
            alert.informativeText = "Quitting now stops it partway. Contacts already done stay done."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Quit")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { InstagramSession.shared.close() }
    }
}

struct RootView: View {
    private var model: AppModel { .shared }
    @Environment(\.openWindow) private var openWindow
    @ViewState private var legacy: URL?

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) { s in
                Label(s.title, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .frame(minHeight: 0, maxHeight: .infinity)
        } detail: {
            Group {
                if let e = model.loadError, !model.loaded {
                    VStack(spacing: 12) {
                        EmptyState(title: "Insta Sync can't read your contacts.", message: e)
                        Button("Try Again") { Task { await model.start() } }
                    }
                } else if !model.loaded {
                    ProgressView("Reading contacts…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch model.section {
                    case .contacts: ContactsView()
                    case .matches: MatchesView()
                    case .add: AddView()
                    case .cleanup: CleanupView()
                    }
                }
            }
            // minHeight 0: the window decides the height; long lists scroll inside it.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .safeAreaInset(edge: .bottom, spacing: 0) { JobPanel() }
        }
        .navigationTitle(model.section.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { model.onlyWithPhones }, set: { model.onlyWithPhones = $0 })) {
                    Label("Phone numbers only", systemImage: "phone")
                }
                .toggleStyle(.button)
                .help(model.onlyWithPhones ? "Showing only contacts with a phone number. Click to show all."
                      : "Showing all contacts. Click to show only those with a phone number.")
                Button { Task { await model.reload() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Re-read Contacts")
                    .disabled(model.loading)
                Button { openWindow(id: "instagram") } label: {
                    Label(model.isLoggedIn ? "Instagram: logged in" : "Log in to Instagram",
                          systemImage: model.isLoggedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(model.isLoggedIn ? Color.green : Color.orange)
                }
                .help(model.isLoggedIn ? "Show the Instagram window" : "Log in to Instagram in Insta Sync's own browser")
            }
        }
        .overlay(alignment: .top) {
            if let t = model.toast {
                Text(t)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.regularMaterial))
                    .shadow(radius: 4)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.toast)
        .task {
            legacy = model.offerLegacyImport()
            await model.start()
            if model.loginChecked && !model.isLoggedIn { openWindow(id: "instagram") }
        }
        .alert("Import data from the previous Insta Sync?",
               isPresented: Binding(get: { legacy != nil }, set: { if !$0 { legacy = nil } })) {
            Button("Import") { model.importLegacy(legacy); legacy = nil }
            Button("Don't Import", role: .cancel) { model.importLegacy(nil); legacy = nil }
        } message: {
            Text("Copies your following list, photo sync history, “None” answers and backups from \(legacy?.path ?? "").")
        }
    }
}
