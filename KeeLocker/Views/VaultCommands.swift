import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Platform commands live here; the repository only receives domain commands.
@MainActor
enum VaultDialogs {
    static func mayLeave(_ store: VaultStore) -> Bool {
        if store.isBusy || store.hasDraft {
            let alert = NSAlert()
            alert.messageText = store.isBusy ? "Please wait for the operation to finish." : "Finish editing this item first."
            alert.informativeText = "Save or cancel your current edit before leaving this vault."
            alert.runModal()
            return false
        }
        guard store.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved vault changes?"
        alert.informativeText = "Choose Cancel and use File → Save to keep your changes."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func saveAs(_ store: VaultStore) {
        guard !store.isBusy, !store.hasDraft else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "kdbx") ?? .data]
        panel.nameFieldStringValue = (store.fileURL?.deletingPathExtension().lastPathComponent ?? "Vault") + " copy.kdbx"
        let session = store.sessionID
        panel.begin { response in
            guard response == .OK, let url = panel.url, !store.hasDraft else { return }
            store.run(.saveAs(url), session: session)
        }
    }

    static func newGroup(_ store: VaultStore, atRoot: Bool = false) {
        guard let parent = atRoot ? store.rootGroupCreationParent : store.groupCreationParent else { return }
        group(store, parent: parent)
    }

    static func group(_ store: VaultStore, parent: VaultGroup, rename: Bool = false) {
        guard !store.isLocked, !store.isBusy, !store.hasDraft,
              rename ? store.capabilities.canEdit : store.capabilities.canCreate else { return }
        let alert = NSAlert()
        alert.messageText = rename ? "Rename Group" : "New Group"
        if !rename { alert.informativeText = "Create inside: \(parent.path)" }
        alert.addButton(withTitle: rename ? "Rename" : "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: rename ? parent.name : "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // Keep external reloads pending while the name is being edited. Start
        // the command before releasing the draft guard so a pending refresh
        // cannot interrupt Create/Rename or replace its source snapshot.
        store.hasDraft = true
        defer { store.hasDraft = false }
        guard alert.runModal() == .alertFirstButtonReturn, !store.isLocked, !store.isBusy,
              store.groups.contains(where: { $0.id == parent.id }),
              !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.run(rename ? .renameGroup(parent.id, field.stringValue) : .createGroup(parent: parent.id, name: field.stringValue))
    }

    static func delete(_ store: VaultStore, command: VaultCommand) {
        let alert = NSAlert()
        alert.messageText = "Delete the selected item?"
        alert.informativeText = store.fileURL == nil
            ? "This will delete the selected item. Groups must be empty."
            : "This will delete the selected item and save the vault file immediately. Groups must be empty."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        if alert.runModal() == .alertSecondButtonReturn { store.run(command) }
    }
}

struct EntryCommands: View {
    @ObservedObject var store: VaultStore
    let item: VaultItem
    var body: some View {
        Button("Attachments & History…") { store.inspectedEntryID = item.id }
            .disabled(!store.capabilities.canSave || store.isBusy || store.hasDraft)
        Menu("Move to Group") {
            ForEach(store.groups) { group in
                Button(group.path) { store.run(.moveEntry(item.id, group.id)) }
                    .disabled(group.id == item.group.id)
            }
        }
        .disabled(!store.capabilities.canEdit || store.isBusy || store.hasDraft)
        Button("Delete", role: .destructive) { VaultDialogs.delete(store, command: .deleteEntry(item.id)) }
            .disabled(!store.capabilities.canDelete || store.isBusy || store.hasDraft)
    }
}

struct EntryFilesAndHistory: View {
    @ObservedObject var store: VaultStore
    let id: UUID
    @State private var versions: [VaultEntry] = []
    @State private var selectedVersion: Int?
    @State private var failure: VaultFailure?
    @State private var working = false
    @State private var fileTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    private var entry: VaultEntry? { store.items.first { $0.id == id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry?.title ?? "Entry").font(.headline)
            Text("Attachments").fontWeight(.medium)
            ForEach(entry?.attachments ?? []) { attachment in
                HStack {
                    Text(attachment.name)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: attachment.size), countStyle: .file)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save…") { export(attachment.name) }
                    Button("Delete", role: .destructive) { store.run(.deleteAttachment(id, attachment.name)) }
                }
            }
            Button("Add Attachment…", action: add)
            Divider()
            Text("Entry History").fontWeight(.medium)
            if versions.isEmpty { Text("No previous versions").foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(versions.indices, id: \.self) { index in
                        Button("\(versions[index].modifiedAt.formatted()) — \(versions[index].title)") { selectedVersion = index }
                    }
                }
            }.frame(maxHeight: 160)
            if let failure { Text(failure.message).foregroundStyle(.red) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 580)
        .disabled(store.isBusy || working)
        .task(id: store.snapshotRevision) {
            let revision = store.snapshotRevision
            versions = []
            selectedVersion = nil
            do {
                let latest = try await store.history(id)
                try Task.checkCancellation()
                guard revision == store.snapshotRevision else { return }
                versions = latest
                failure = nil
            } catch {
                if !Task.isCancelled, revision == store.snapshotRevision,
                   !(error is CancellationError) {
                    failure = (error as? VaultFailure) ?? .invalidOperation
                }
            }
        }
        .sheet(isPresented: Binding(get: { selectedVersion != nil }, set: { if !$0 { selectedVersion = nil } })) {
            if let index = selectedVersion, versions.indices.contains(index) {
                VStack {
                    ItemDetailView(item: .constant(versions[index]), canEdit: false, canFavorite: false)
                    Button("Done") { selectedVersion = nil }.keyboardShortcut(.cancelAction).padding()
                }.frame(width: 740, height: 640)
            }
        }
        .onDisappear {
            fileTask?.cancel()
            fileTask = nil
            versions = []
            selectedVersion = nil
        }
    }

    private func add() {
        let session = store.sessionID
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        fileTask = Task {
            defer { working = false }
            do {
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                guard !Task.isCancelled, !store.isLocked, store.sessionID == session,
                      store.inspectedEntryID == id else { return }
                store.run(.putAttachment(id, url.lastPathComponent, data), session: session)
                await store.waitForOperation()
            } catch { failure = .failedToReadFile }
        }
    }

    private func export(_ name: String) {
        let session = store.sessionID
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: name).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        fileTask = Task {
            defer { working = false }
            do {
                let data = try await store.attachment(id, name: name)
                guard !Task.isCancelled, store.sessionID == session else { return }
                try await Task.detached { try data.write(to: url, options: .atomic) }.value
            } catch { if !(error is CancellationError) { failure = .writeFailed } }
        }
    }
}

struct GroupCommands: View {
    @ObservedObject var store: VaultStore
    let group: VaultGroup
    var body: some View {
        Group {
            Button("New Group…") { VaultDialogs.group(store, parent: group) }
            Button("Rename Group…") { VaultDialogs.group(store, parent: group, rename: true) }
            Menu("Move to Group") {
                ForEach(store.groups.filter { $0.id != group.id }) { destination in
                    Button(destination.path) { store.run(.moveGroup(group.id, destination.id)) }
                }
            }
            .disabled(group.parentID == nil)
            Button("Delete Group", role: .destructive) { VaultDialogs.delete(store, command: .deleteGroup(group.id)) }
                .disabled(group.parentID == nil)
        }
        .disabled(!store.capabilities.canEdit || store.isBusy || store.hasDraft)
    }
}

// Preserve the SwiftUI window delegate and interpose only the close decision.
struct VaultWindowGuard: NSViewRepresentable {
    let store: VaultStore
    func makeNSView(context: Context) -> GuardView { GuardView(store: store) }
    func updateNSView(_ view: GuardView, context: Context) { view.window?.isDocumentEdited = store.isDirty || store.hasDraft }

    final class GuardView: NSView, NSWindowDelegate {
        let store: VaultStore
        weak var originalDelegate: (any NSWindowDelegate)?
        init(store: VaultStore) { self.store = store; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.delegate !== self else { return }
            originalDelegate = window.delegate
            window.delegate = self
            VaultApplicationDelegate.guards = VaultApplicationDelegate.guards.filter { $0.value != nil }
            VaultApplicationDelegate.guards.append(WeakGuard(self))
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard VaultDialogs.mayLeave(store) else { return false }
            store.lock()
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || (originalDelegate?.responds(to: selector) ?? false) }
        override func forwardingTarget(for selector: Selector!) -> Any? { originalDelegate }
    }
}

final class WeakGuard {
    weak var value: VaultWindowGuard.GuardView?
    init(_ value: VaultWindowGuard.GuardView) { self.value = value }
}

@MainActor
final class VaultApplicationDelegate: NSObject, NSApplicationDelegate {
    static var guards: [WeakGuard] = []
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for guardView in Self.guards.compactMap(\.value) {
            if !VaultDialogs.mayLeave(guardView.store) { return .terminateCancel }
        }
        for guardView in Self.guards.compactMap(\.value) { guardView.store.lock() }
        SessionQuickUnlock.shared.reset()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardOwner.shared.clearOnTermination()
        SessionQuickUnlock.shared.reset()
    }
}
