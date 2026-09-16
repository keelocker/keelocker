import AppKit
import SwiftUI

struct ItemDetailView: View {
    @Binding var item: VaultItem
    @AppStorage("clearClipboard") private var clearsClipboard = true

    @State private var draft: VaultItem
    @State private var isEditing = false
    @State private var showsPassword = false
    @State private var copiedValue: CopiedValue?
    @State private var copyFeedbackToken = UUID()

    init(item: Binding<VaultItem>) {
        _item = item
        _draft = State(initialValue: item.wrappedValue)
    }

    private var presentedItem: VaultItem {
        isEditing ? draft : item
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
    }

    private var detailHeader: some View {
        HStack(alignment: .top, spacing: 18) {
            EntryIcon(item: presentedItem, size: 64)

            VStack(alignment: .leading, spacing: 5) {
                if isEditing {
                    TextField("Title", text: $draft.title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 30, weight: .semibold))
                } else {
                    Text(presentedItem.title)
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(-0.45)
                        .lineLimit(2)
                }

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
                    draft.isFavorite.toggle()
                } else {
                    item.isFavorite.toggle()
                }
            } label: {
                Image(systemName: presentedItem.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(presentedItem.isFavorite ? Color.orange : Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .help(presentedItem.isFavorite ? "Remove from favorites" : "Add to favorites")
            .accessibilityLabel(presentedItem.isFavorite ? "Remove from favorites" : "Add to favorites")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            DetailActionButton(
                title: copiedValue == .password ? "Copied" : "Copy",
                iconName: copiedValue == .password ? "checkmark" : "doc.on.doc",
                prominence: .primary
            ) {
                copy(presentedItem.password, as: .password)
            }
            .disabled(presentedItem.password.isEmpty)

            DetailActionButton(
                title: showsPassword ? "Hide" : "Show",
                iconName: showsPassword ? "eye.slash" : "eye"
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
                    draft = item
                    isEditing = false
                }
            }

            DetailActionButton(
                title: isEditing ? "Save" : "Edit",
                iconName: isEditing ? "checkmark" : "pencil"
            ) {
                if isEditing {
                    draft.modifiedAt = .now
                    item = draft
                } else {
                    draft = item
                }
                isEditing.toggle()
            }
        }
    }

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 30) {
            DetailSection(title: "Sign-in") {
                if isEditing {
                    EditableCredentialRow(
                        label: "Username",
                        iconName: "person",
                        text: $draft.username,
                        prompt: "Username or email"
                    )
                    PanelDivider()
                    EditableCredentialRow(
                        label: "Password",
                        iconName: "key",
                        text: $draft.password,
                        prompt: "Password",
                        isSecure: true
                    )
                    PanelDivider()
                    EditableCredentialRow(
                        label: "Website",
                        iconName: "globe",
                        text: $draft.website,
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

            if !presentedItem.customFields.isEmpty {
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
                        TextEditor(text: $draft.notes)
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

                if !presentedItem.tags.isEmpty {
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
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        let pasteboardChangeCount = NSPasteboard.general.changeCount
        let feedbackToken = UUID()
        copyFeedbackToken = feedbackToken
        self.copiedValue = copiedValue

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard self.copyFeedbackToken == feedbackToken else { return }
            self.copiedValue = nil
        }

        guard clearsClipboard else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            guard NSPasteboard.general.changeCount == pasteboardChangeCount else { return }
            NSPasteboard.general.clearContents()
        }
    }

    private func openWebsite() {
        guard let url = presentedItem.websiteURL else { return }
        NSWorkspace.shared.open(url)
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
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
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
    var prominence: Prominence = .normal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: iconName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .frame(minWidth: 76, minHeight: 34)
                .foregroundStyle(prominence == .primary ? Color.white : Color.primary)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var backgroundColor: Color {
        prominence == .primary ? KeeTheme.accent : Color.primary.opacity(0.06)
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
