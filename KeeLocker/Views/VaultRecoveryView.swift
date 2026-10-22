import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VaultRecoveryView: View {
    @ObservedObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var copies: [VaultBackup] = []
    @State private var selectedID: String?
    @State private var password = ""
    @State private var keyFile: URL?
    @State private var loading = true
    @State private var working = false
    @State private var status: String?
    @State private var statusIsError = false
    @State private var generation = UUID()
    @State private var fileTask: Task<Void, Never>?
    @State private var activePanel: NSSavePanel?
    @State private var visible = false

    private var selectedCopy: VaultBackup? { copies.first { $0.id == selectedID } }
    private var canAct: Bool { store.supportsRecovery && !store.isBusy && !working && !loading }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recovery Copies").font(.headline)
            Text("Restore an encrypted recovery copy to a new file using that copy’s password and key file.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if loading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading recovery copies…").foregroundStyle(.secondary)
                }
            } else if copies.isEmpty {
                Text("No recovery copies are available for this vault.")
                    .foregroundStyle(.secondary)
            }
            List {
                ForEach(copies) { copy in
                    Button {
                        selectedID = copy.id
                        status = nil
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedID == copy.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedID == copy.id ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(copy.isOriginal ? "Original" : "Recovery Copy").fontWeight(.medium)
                                Text(copy.createdAt?.formatted(date: .abbreviated, time: .standard) ?? "Date unavailable")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: copy.size), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(copy.isOriginal ? "recovery.original" : "recovery.copy.\(copy.id)")
                    .accessibilityAddTraits(selectedID == copy.id ? .isSelected : [])
                }
            }
            .frame(height: 200)
            .accessibilityIdentifier("recovery.list")
            .disabled(!canAct)

            SecureField("Recovery Copy Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("recovery.password")
                .disabled(!canAct)
            HStack {
                Button(keyFile?.lastPathComponent ?? "Choose Key File…", action: chooseKeyFile)
                    .accessibilityIdentifier("recovery.keyFile")
                if keyFile != nil {
                    Button("Remove") { keyFile = nil }
                }
            }
            .disabled(!canAct)

            if working {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Validating and restoring copy…").foregroundStyle(.secondary)
                }
            }
            if let status {
                Text(status)
                    .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("recovery.status")
            }
            HStack {
                if !loading && !working {
                    Button("Refresh") { Task { await loadCopies() } }
                        .disabled(store.isBusy || !store.supportsRecovery || activePanel != nil)
                }
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("recovery.done")
                Button("Restore Copy…", action: restore)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAct || selectedCopy == nil || activePanel != nil)
                    .accessibilityIdentifier("recovery.restore")
            }
        }
        .padding(24)
        .frame(width: 580)
        .task {
            visible = true
            await loadCopies()
        }
        .onChange(of: store.sessionID) { _, _ in close() }
        .onDisappear { clear() }
    }

    @MainActor
    private func loadCopies() async {
        let session = store.sessionID
        let request = UUID()
        generation = request
        loading = true
        selectedID = nil
        copies = []
        status = nil
        defer { if generation == request { loading = false } }
        do {
            let latest = try await store.backups()
            guard isCurrent(session, request), !Task.isCancelled else { return }
            copies = latest
        } catch {
            guard isCurrent(session, request), !Task.isCancelled, !(error is CancellationError) else { return }
            show(error)
        }
    }

    @MainActor
    private func chooseKeyFile() {
        guard canAct, activePanel == nil else { return }
        let session = store.sessionID
        let request = generation
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        activePanel = panel
        panel.begin { response in
            guard isCurrent(session, request), activePanel === panel else { return }
            activePanel = nil
            guard response == .OK, !store.isBusy else { return }
            keyFile = panel.url
        }
    }

    @MainActor
    private func restore() {
        guard canAct, let copy = selectedCopy, activePanel == nil else { return }
        let session = store.sessionID
        let request = generation
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "kdbx") ?? .data]
        panel.nameFieldStringValue = "Recovered Vault.kdbx"
        panel.prompt = "Restore Copy"
        activePanel = panel
        panel.begin { response in
            guard isCurrent(session, request), activePanel === panel else { return }
            activePanel = nil
            guard response == .OK, let destination = panel.url, canAct, selectedID == copy.id else { return }
            working = true
            status = nil
            fileTask = Task {
                defer {
                    if isCurrent(session, request) {
                        working = false
                        fileTask = nil
                    }
                }
                do {
                    let result = try await store.restoreBackup(copy, to: destination, password: password, keyFile: keyFile)
                    guard isCurrent(session, request), !Task.isCancelled else { return }
                    password = ""
                    keyFile = nil
                    statusIsError = false
                    status = result.directorySynced
                        ? "Restored copy: \(result.url.path)"
                        : "Copy committed at \(result.url.path), but its directory could not be synced. Keep the recovery copy and verify the new file before relying on it."
                } catch {
                    guard isCurrent(session, request), !Task.isCancelled, !(error is CancellationError) else { return }
                    show(error)
                }
            }
        }
    }

    private func isCurrent(_ session: UUID, _ request: UUID) -> Bool {
        visible && store.sessionID == session && generation == request
    }

    private func show(_ error: Error) {
        statusIsError = true
        status = (error as? VaultFailure)?.message ?? "The recovery copy could not be read or restored. Choose a new destination and check the copy’s password and key file."
    }

    private func close() {
        clear()
        dismiss()
    }

    private func clear() {
        visible = false
        generation = UUID()
        activePanel?.cancel(nil)
        activePanel = nil
        fileTask?.cancel()
        fileTask = nil
        password = ""
        keyFile = nil
        copies = []
        selectedID = nil
    }
}
