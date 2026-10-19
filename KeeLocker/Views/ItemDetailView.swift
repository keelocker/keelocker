import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ItemDetailView: View {
    @Binding var item: VaultItem
    let canEdit: Bool
    let canFavorite: Bool
    @Binding var hasDraft: Bool
    let isNew: Bool
    let onSave: ((VaultItem) async -> Bool)?
    let onBeginEditing: (() -> Bool)?
    let onCancel: (() -> Void)?
    let customIcons: [VaultCustomIcon]
    @State private var draft: ItemEditingDraft
    @State private var isEditing = false
    @State private var showsPassword = false
    @State private var copiedValue: CopiedValue?
    @State private var copyFeedbackToken = UUID()
    @State private var showsIconPicker = false
    @State private var importsIcon = false
    @State private var iconImportFailure = false
    @State private var iconImports = IconImportSession()
    @State private var iconImportToken: UUID?
    @State private var importTask: Task<Void, Never>?
    @State private var isImportingIcon = false
    @State private var isDownloadingIcon = false
    @State private var iconDownloadFailure = false
    @FocusState private var titleHasFocus: Bool

    init(item: Binding<VaultItem>, canEdit: Bool = true, canFavorite: Bool = true,
         hasDraft: Binding<Bool> = .constant(false), isNew: Bool = false,
         onSave: ((VaultItem) async -> Bool)? = nil,
         onBeginEditing: (() -> Bool)? = nil, onCancel: (() -> Void)? = nil,
         customIcons: [VaultCustomIcon] = []) {
        _item = item
        self.canEdit = canEdit
        self.canFavorite = canFavorite
        _hasDraft = hasDraft
        self.isNew = isNew
        self.onSave = onSave
        self.onBeginEditing = onBeginEditing
        self.onCancel = onCancel
        self.customIcons = customIcons
        _draft = State(initialValue: ItemEditingDraft(isNew ? item.wrappedValue : .empty))
        _isEditing = State(initialValue: isNew)
    }

    private var presentedItem: VaultItem {
        isEditing ? draft.item : item
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader
                actionBar
                    .padding(.top, 24)

                detailContent
                    .padding(.top, 34)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 38)
            .padding(.top, 34)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(KeeTheme.canvas)
        .onAppear { if isNew { titleHasFocus = true } }
        .onDisappear {
            invalidateIconImport()
            draft = ItemEditingDraft()
            showsPassword = false
        }
        .fileImporter(isPresented: $importsIcon, allowedContentTypes: [.image]) { [token = iconImportToken] result in
            guard let token, iconImports.isCurrent(token),
                  isEditing, canEdit, case .success(let url) = result else { return }
            iconImportToken = nil
            isImportingIcon = true
            importTask = Task {
                defer { if iconImports.isCurrent(token) { isImportingIcon = false; importTask = nil } }
                do {
                    guard let icon = try await iconImports.load(url, request: token),
                          isEditing, canEdit else { return }
                    draft.item.chooseIcon(.imported(icon))
                } catch {
                    guard !Task.isCancelled, iconImports.isCurrent(token), isEditing else { return }
                    iconImportFailure = true
                }
            }
        }
        .alert("Couldn’t import icon", isPresented: $iconImportFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Choose a supported image up to 20 MB. KeeLocker will resize it to fit the icon.")
        }
        .alert("Couldn’t download icon", isPresented: $iconDownloadFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No supported icon was found. Check the website and your connection, or import an image.")
        }
        .onChange(of: draft.item.website) { _, _ in
            if isDownloadingIcon { invalidateIconImport() }
        }
    }

    private var detailHeader: some View {
        HStack(alignment: .top, spacing: 18) {
            if isEditing {
                Button { showsIconPicker = true } label: {
                    EntryIcon(item: presentedItem, size: 64)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "pencil.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, KeeTheme.accent)
                                .offset(x: 3, y: 3)
                        }
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!canEdit)
                .help("Change icon")
                .accessibilityLabel("Change icon")
                .accessibilityValue(draft.item.icon?.name ?? "Demo icon")
                .accessibilityIdentifier("entry.changeIcon")
                .popover(isPresented: $showsIconPicker, arrowEdge: .leading) {
                    EntryIconPicker(selected: draft.item.icon, customIcons: customIcons, onSelect: { icon in
                        invalidateIconImport()
                        draft.item.chooseIcon(icon)
                        showsIconPicker = false
                    }, onImport: {
                        invalidateIconImport()
                        showsIconPicker = false
                        iconImportToken = iconImports.begin()
                        importsIcon = true
                    }, canDownload: FaviconDownloader.origin(for: draft.item.website) != nil,
                       isDownloading: isDownloadingIcon, onDownload: downloadWebsiteIcon)
                }
            } else {
                EntryIcon(item: presentedItem, size: 64)
            }

            VStack(alignment: .leading, spacing: 5) {
                Group {
                    if isEditing {
                        TextField("Title", text: $draft.item.title)
                            .textFieldStyle(.plain)
                            .lineLimit(1)
                            .focused($titleHasFocus)
                    } else {
                        Text(presentedItem.title)
                            .lineLimit(2)
                    }
                }
                .font(.system(size: 30, weight: .semibold))
                .frame(minHeight: 42, alignment: .leading)

                HStack(spacing: 7) {
                    Text(presentedItem.group.rawValue)
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text("Updated \(presentedItem.modifiedAt.formatted(.relative(presentation: .named)))")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                if isEditing {
                    draft.item.isFavorite.toggle()
                } else {
                    item.isFavorite.toggle()
                }
            } label: {
                Image(systemName: presentedItem.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(presentedItem.isFavorite ? Color.orange : Color.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help(presentedItem.isFavorite ? "Remove from favorites" : "Add to favorites")
            .disabled(!canEdit || !canFavorite)
            .accessibilityLabel(presentedItem.isFavorite ? "Remove from favorites" : "Add to favorites")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            DetailActionButton(
                title: copiedValue == .password ? "Copied" : "Copy",
                iconName: copiedValue == .password ? "checkmark" : "doc.on.doc",
                alternateLabel: copiedValue == .password
                    ? ("Copy", "doc.on.doc") : ("Copied", "checkmark"),
                prominence: .primary
            ) {
                copy(presentedItem.password, as: .password)
            }
            .disabled(presentedItem.password.isEmpty)

            DetailActionButton(
                title: showsPassword ? "Hide" : "Show",
                iconName: showsPassword ? "eye.slash" : "eye",
                alternateLabel: showsPassword ? ("Show", "eye") : ("Hide", "eye.slash")
            ) {
                showsPassword.toggle()
            }

            DetailActionButton(title: "Open", iconName: "arrow.up.right.square") {
                openWebsite()
            }
            .disabled(presentedItem.websiteURL == nil)

            Spacer(minLength: 8)

            if isEditing {
                DetailActionButton(title: "Cancel", iconName: "xmark") {
                    invalidateIconImport()
                    showsIconPicker = false
                    draft = ItemEditingDraft()
                    isEditing = false
                    if let onCancel { onCancel() }
                    else { hasDraft = false }
                }
            }

            DetailActionButton(
                title: isEditing ? "Save" : "Edit",
                iconName: isEditing ? "checkmark" : "pencil"
            ) {
                if isEditing {
                    invalidateIconImport()
                    showsIconPicker = false
                    draft.item.modifiedAt = .now
                    let savedItem = draft.savedItem
                    if let onSave {
                        Task {
                            if await onSave(savedItem) {
                                draft = ItemEditingDraft()
                                isEditing = false
                                hasDraft = false
                            }
                        }
                    } else {
                        item = savedItem
                        draft = ItemEditingDraft()
                        isEditing = false
                        hasDraft = false
                    }
                } else {
                    guard onBeginEditing?() ?? true else { return }
                    draft = ItemEditingDraft(item)
                    isEditing = true
                    hasDraft = true
                }
            }
            .disabled(!canEdit || isImportingIcon || isDownloadingIcon)
        }
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 30) {
            DetailSection(title: "Sign-in") {
                if isEditing {
                    EditableCredentialRow(
                        label: "Username",
                        iconName: "person",
                        text: $draft.item.username,
                        prompt: "Username or email"
                    )
                    PanelDivider()
                    EditableCredentialRow(
                        label: "Password",
                        iconName: "key",
                        text: $draft.item.password,
                        prompt: "Password",
                        isSecure: true
                    )
                    PanelDivider()
                    EditableCredentialRow(
                        label: "Website",
                        iconName: "globe",
                        text: $draft.item.website,
                        prompt: "https://example.com"
                    )
                } else {
                    CredentialRow(
                        label: "Username",
                        iconName: "person",
                        value: presentedItem.username.isEmpty ? "No username" : presentedItem.username
                    ) {
                        MiniActionButton(iconName: copiedValue == .username ? "checkmark" : "doc.on.doc", help: "Copy username") {
                            copy(presentedItem.username, as: .username)
                        }
                    }
                    PanelDivider()
                    CredentialRow(
                        label: "Password",
                        iconName: "key",
                        value: showsPassword ? presentedItem.password : "••••••••••••••••••••",
                        usesMonospacedFont: true
                    ) {
                        HStack(spacing: 2) {
                            MiniActionButton(iconName: showsPassword ? "eye.slash" : "eye", help: showsPassword ? "Hide password" : "Show password") {
                                showsPassword.toggle()
                            }
                            MiniActionButton(iconName: copiedValue == .password ? "checkmark" : "doc.on.doc", help: "Copy password") {
                                copy(presentedItem.password, as: .password)
                            }
                        }
                    }
                    PanelDivider()
                    CredentialRow(
                        label: "Website",
                        iconName: "globe",
                        value: presentedItem.website
                    ) {
                        MiniActionButton(iconName: "arrow.up.right", help: "Open website") {
                            openWebsite()
                        }
                    }
                }
            }

            if let oneTimePassword = presentedItem.oneTimePassword, !isEditing {
                DetailSection(title: "Verification") {
                    OneTimePasswordView(oneTimePassword: oneTimePassword) {
                        copy(oneTimePassword.code.replacingOccurrences(of: " ", with: ""), as: .oneTimePassword)
                    }
                }
            }

            if isEditing {
                DetailSection(title: "Custom fields") {
                    VStack(spacing: 8) {
                        ForEach($draft.item.customFields) { $field in
                            HStack {
                                TextField("Name", text: $field.name)
                                if field.isSensitive { SecureField("Value", text: $field.value) }
                                else { TextField("Value", text: $field.value) }
                                Toggle("Protected", isOn: $field.isSensitive)
                                Button(role: .destructive) { draft.item.customFields.removeAll { $0.id == field.id } } label: { Image(systemName: "minus.circle") }
                            }
                        }
                        Button("Add Field") { draft.item.customFields.append(CustomField(name: "", value: "")) }
                    }
                    .padding(12)
                }
            } else if !presentedItem.customFields.isEmpty {
                DetailSection(title: "Custom fields") {
                    ForEach(Array(presentedItem.customFields.enumerated()), id: \.element.id) { index, field in
                        CredentialRow(
                            label: field.name,
                            iconName: field.isSensitive ? "lock" : "textformat",
                            value: field.isSensitive ? "••••••••••••" : field.value,
                            usesMonospacedFont: field.isSensitive
                        ) {
                            MiniActionButton(iconName: "doc.on.doc", help: "Copy \(field.name)") {
                                copy(field.value, as: .customField)
                            }
                        }

                        if index < presentedItem.customFields.count - 1 {
                            PanelDivider()
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                if isEditing {
                    DetailSection(title: "Notes") {
                        TextEditor(text: $draft.item.notes)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 88)
                            .padding(12)
                    }
                } else if !presentedItem.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Notes")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(presentedItem.notes)
                            .font(.body)
                            .foregroundStyle(.primary.opacity(0.86))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if isEditing {
                    TextField("Tags (separated by semicolons)", text: $draft.tagsText)
                    .textFieldStyle(.roundedBorder)
                } else if !presentedItem.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Tags")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 7) {
                            ForEach(presentedItem.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(KeeTheme.accent)
                                    .padding(.horizontal, 9)
                                    .frame(height: 25)
                                    .background(KeeTheme.accent.opacity(0.11), in: Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    private func copy(_ value: String, as copiedValue: CopiedValue) {
        guard ClipboardOwner.shared.copy(value) else { return }
        let feedbackToken = UUID()
        copyFeedbackToken = feedbackToken
        self.copiedValue = copiedValue

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard self.copyFeedbackToken == feedbackToken else { return }
            self.copiedValue = nil
        }
    }

    private func openWebsite() {
        guard let url = presentedItem.websiteURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func invalidateIconImport() {
        iconImports.invalidate()
        importTask?.cancel()
        importTask = nil
        iconImportToken = nil
        importsIcon = false
        isImportingIcon = false
        isDownloadingIcon = false
        iconDownloadFailure = false
        iconImportFailure = false
    }

    private func downloadWebsiteIcon() {
        if isDownloadingIcon { invalidateIconImport(); return }
        guard isEditing, canEdit, let url = FaviconDownloader.origin(for: draft.item.website) else { return }
        invalidateIconImport()
        let token = iconImports.begin()
        let website = draft.item.website
        isDownloadingIcon = true
        importTask = Task {
            defer { if iconImports.isCurrent(token) { isDownloadingIcon = false; importTask = nil } }
            do {
                guard let icon = try await iconImports.loadWebsite(url, request: token),
                      isEditing, canEdit, draft.item.website == website else { return }
                draft.item.useWebsiteIcon(icon, origin: url)
                showsIconPicker = false
            } catch {
                guard !Task.isCancelled, iconImports.isCurrent(token), isEditing else { return }
                iconDownloadFailure = true
            }
        }
    }
}

/// Keep field input verbatim while editing; normalize tags only for the saved entry.
struct ItemEditingDraft {
    var item: VaultItem
    var tagsText: String

    init(_ item: VaultItem = .empty) {
        self.item = item
        tagsText = item.tags.joined(separator: "; ")
    }

    var savedItem: VaultItem {
        var saved = item
        saved.tags = tagsText.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return saved
    }
}

private enum CopiedValue: Equatable {
    case username
    case password
    case oneTimePassword
    case customField
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0, content: content)
                .background(
                    RoundedRectangle(cornerRadius: KeeTheme.Radius.panel, style: .continuous)
                        .fill(KeeTheme.raisedSurface)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: KeeTheme.Radius.panel, style: .continuous)
                        .stroke(Color.primary.opacity(0.065), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: KeeTheme.Radius.panel, style: .continuous))
        }
    }
}

private struct CredentialRow<Trailing: View>: View {
    let label: String
    let iconName: String
    let value: String
    var usesMonospacedFont = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(usesMonospacedFont ? .system(.body, design: .monospaced) : .body)
                    .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
    }
}

private struct EditableCredentialRow: View {
    let label: String
    let iconName: String
    @Binding var text: String
    let prompt: String
    var isSecure = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Group {
                    if isSecure {
                        SecureField(prompt, text: $text)
                    } else {
                        TextField(prompt, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.body)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
    }
}

private struct PanelDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 46)
    }
}

private struct MiniActionButton: View {
    let iconName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct DetailActionButton: View {
    enum Prominence {
        case normal
        case primary
    }

    let title: String
    let iconName: String
    var alternateLabel: (title: String, iconName: String)? = nil
    var prominence: Prominence = .normal
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if prominence == .primary {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var button: some View {
        Button(action: action) {
            ZStack {
                if let alternateLabel {
                    // Reserve both states' dimensions, including differing symbol heights.
                    Label(alternateLabel.title, systemImage: alternateLabel.iconName)
                        .hidden()
                        .accessibilityHidden(true)
                }
                Label(title, systemImage: iconName)
            }
        }
        .accessibilityLabel(title)
        .labelStyle(.titleAndIcon)
        .controlSize(.large)
        .fixedSize()
    }
}

private struct OneTimePasswordView: View {
    let oneTimePassword: OneTimePassword
    let onCopy: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = remainingSeconds(at: context.date)
            let period = oneTimePassword.safePeriod

            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(KeeTheme.positive.opacity(0.16), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: CGFloat(remaining) / CGFloat(period))
                        .stroke(KeeTheme.positive, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(remaining.formatted())
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(KeeTheme.positive)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text("One-time password")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(oneTimePassword.code)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced).monospacedDigit())
                        .tracking(1.4)
                        .textSelection(.enabled)
                }

                Spacer()

                Button(action: onCopy) {
                    Label("Copy code", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .foregroundStyle(KeeTheme.positive)
                        .background(KeeTheme.positive.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(14)
        }
    }

    private func remainingSeconds(at date: Date) -> Int {
        let period = oneTimePassword.safePeriod
        let elapsed = Int(date.timeIntervalSince1970) % period
        return max(period - elapsed, 1)
    }
}
