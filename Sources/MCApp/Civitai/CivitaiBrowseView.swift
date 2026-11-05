import MCLibrary
import MCModels
import SwiftUI

/// Civitai's NSFW levels are bit flags, where `1` means None. A missing level counts as NSFW, the same as a listing
/// without the NSFW flag (R7).
enum CivitaiPreviewRule {
    static func isNSFW(level: Int?) -> Bool {
        level.map { $0 > 1 } ?? true
    }
}

/// The license terms of a Civitai LoRA in plain words (D20). Shared by the license sheet and the Installed detail.
enum CivitaiLicenseText {
    static func lines(_ flags: CivitaiLicenseFlags) -> [String] {
        var lines: [String] = []
        switch flags.allowNoCredit {
        case true?: lines.append("Credit to the creator is not required.")
        case false?: lines.append("Credit to the creator is required.")
        case nil: lines.append("The creator did not say whether credit is required.")
        }
        if flags.allowCommercialUse.isEmpty {
            lines.append("No commercial use is listed by the creator.")
        } else {
            lines.append("Commercial use is allowed for: \(flags.allowCommercialUse.joined(separator: ", ")).")
        }
        switch flags.allowDerivatives {
        case true?: lines.append("Derivative works (merges, further training) are allowed.")
        case false?: lines.append("Derivative works are not allowed.")
        case nil: lines.append("The creator did not say whether derivative works are allowed.")
        }
        switch flags.allowDifferentLicense {
        case true?: lines.append("Derivative works may use a different license.")
        case false?: lines.append("Derivative works must keep this license.")
        case nil: lines.append("The creator did not say whether derivative works may use a different license.")
        }
        return lines
    }
}

/// The Civitai tab of the LoRA library sheet (plan U7). State and downloads live on `CivitaiBrowseModel`, which
/// `AppModel` owns, so a download keeps running after the sheet closes. A finished download goes on the generation stack
/// when it fits the selected model's family and the stack has room (D51).
struct CivitaiBrowseView: View {
    @Bindable var model: AppModel
    @State private var showingKey = false

    private var browse: CivitaiBrowseModel { model.civitai }

    private var selectedModelName: String? {
        model.selectedModel.map { ModelChip.title(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(MCSpacing.group)
            if showingKey || browse.keyError != nil {
                CivitaiKeyField(browse: browse)
                    .padding(.horizontal, MCSpacing.group)
                    .padding(.bottom, MCSpacing.group)
            }
            Divider()
            content
            Divider()
            footer
                .padding(MCSpacing.group)
        }
        .task(id: browse.selectionKey) {
            await browse.showTab()
        }
        .sheet(isPresented: licensePresented) {
            if let pending = browse.pendingLicense {
                CivitaiLicenseSheet(browse: browse, pending: pending)
            }
        }
    }

    private var licensePresented: Binding<Bool> {
        Binding(
            get: { browse.pendingLicense != nil },
            set: { presented in
                if !presented { browse.declinePendingLicense() }
            })
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: MCSpacing.regular) {
            HStack(spacing: MCSpacing.regular) {
                TextField(
                    "Search Civitai LoRAs",
                    text: Binding(
                        get: { browse.query },
                        set: { browse.setQuery($0) })
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .accessibilityLabel("Search Civitai LoRAs")
                Picker(
                    "Sort",
                    selection: Binding(
                        get: { browse.sort },
                        set: { sort in Task { await browse.setSort(sort) } })
                ) {
                    ForEach(CivitaiSort.allCases, id: \.self) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .accessibilityLabel("Sort results")
                familyMenu
                Spacer(minLength: 0)
                Button(showingKey ? "Hide key" : "Civitai key…") {
                    showingKey.toggle()
                }
                .controlSize(.small)
                .accessibilityLabel(showingKey ? "Hide Civitai key field" : "Show Civitai key field")
            }
            HStack(spacing: MCSpacing.section) {
                Toggle(
                    "Show incompatible",
                    isOn: Binding(
                        get: { browse.showIncompatible },
                        set: { on in Task { await browse.setShowIncompatible(on) } })
                )
                .toggleStyle(.checkbox)
                Toggle(
                    "Include NSFW",
                    isOn: Binding(
                        get: { browse.includeNSFW },
                        set: { on in Task { await browse.setIncludeNSFW(on) } })
                )
                .toggleStyle(.checkbox)
                Spacer(minLength: 0)
                if let name = selectedModelName {
                    Text("Fits \(name) by default")
                        .font(.mcMetadata)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var familyMenu: some View {
        Menu {
            Button("Selected model's family") {
                Task { await browse.setFamily(nil) }
            }
            Divider()
            ForEach(browse.familyChoices) { choice in
                Button(choice.name) {
                    Task { await browse.setFamily(choice.id) }
                }
            }
        } label: {
            Text("Family: \(familyName)")
        }
        .fixedSize()
        .accessibilityLabel("Family filter, currently \(familyName)")
    }

    private var familyName: String {
        browse.familyChoices.first { $0.id == browse.chipFamilyID }?.name ?? "None"
    }

    // MARK: Results

    @ViewBuilder
    private var content: some View {
        switch browse.state {
        case .noModel:
            message("Select a model first. Civitai LoRAs are listed for the family of the selected model.")
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results:
            resultsList
        case .empty:
            VStack(spacing: MCSpacing.regular) {
                Text("No LoRAs match this search.")
                    .foregroundStyle(.secondary)
                HStack(spacing: MCSpacing.regular) {
                    if !browse.showIncompatible {
                        Button("Show incompatible") {
                            Task { await browse.setShowIncompatible(true) }
                        }
                    }
                    Button("Clear search") {
                        Task { await browse.clearSearch() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsKey(let text):
            VStack(spacing: MCSpacing.regular) {
                Text(text ?? "Civitai needs an API key to download this LoRA.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                CivitaiKeyField(browse: browse)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(MCSpacing.group)
        case .regionLimited:
            message("Civitai is not available in your region for this search.")
        case .failed(let text):
            VStack(spacing: MCSpacing.regular) {
                Text(text)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") {
                    Task { await browse.search() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(MCSpacing.group)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(MCSpacing.group)
    }

    private var resultsList: some View {
        let rows = browse.rows
        return List(rows) { row in
            CivitaiResultRowView(
                browse: browse,
                row: row,
                modelName: selectedModelName
            )
            .onAppear {
                // Reaching the last row loads the next page. `loadMore` does nothing without a cursor.
                if row.id == rows.last?.id {
                    Task { await browse.loadMore() }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: MCSpacing.regular) {
            if let line = browse.activeDownloadLine {
                Text(line)
                    .font(.mcMetadata)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Downloads keep going if you close this sheet.")
                    .font(.mcMetadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The Civitai key field: a secure field saved to the Keychain, sent only to civitai.com. Shown in the header and in the
/// needs-key state. The typed key is cleared only after a successful save and is never displayed or logged.
struct CivitaiKeyField: View {
    let browse: CivitaiBrowseModel
    @State private var key = ""

    private var isBlank: Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.tight) {
            HStack(spacing: MCSpacing.regular) {
                SecureField(browse.hasSavedKey ? "Replace saved Civitai key" : "Civitai API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Civitai API key")
                Button("Save key") {
                    let value = key
                    Task {
                        await browse.saveKey(value)
                        if browse.keyError == nil {
                            key = ""
                        }
                    }
                }
                .disabled(isBlank)
                if browse.hasSavedKey {
                    Text("A key is saved in the Keychain.")
                        .font(.mcMetadata)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = browse.keyError {
                Text(error)
                    .font(.mcMetadata)
                    .foregroundStyle(MCTone.critical)
            }
            Text("The key is sent only to civitai.com.")
                .font(.mcMetadata)
                .foregroundStyle(.secondary)
        }
    }
}

/// One result row: preview, name, creator, size, downloads, status, and the Download or Cancel action.
private struct CivitaiResultRowView: View {
    let browse: CivitaiBrowseModel
    let row: CivitaiResultRow
    let modelName: String?

    /// Blurred while the preview is NSFW and the user has not revealed it (AE4). The NSFW opt-in only decides whether
    /// NSFW results appear.
    private var blurred: Bool {
        browse.isBlurred(row)
    }

    private var detailLine: String {
        var parts: [String] = []
        if let creator = row.creatorName { parts.append("by \(creator)") }
        if let version = row.versionName { parts.append(version) }
        if let size = row.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let downloads = row.downloadCount { parts.append("\(downloads.formatted()) downloads") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: MCSpacing.regular) {
            preview
            VStack(alignment: .leading, spacing: MCSpacing.hairline) {
                HStack(spacing: MCSpacing.compact) {
                    Text(row.name)
                        .font(.body.weight(.medium))  // no token: medium-weight row title
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.matchesSelectedModel {
                        badge("Fits \(modelName ?? "the selected model")")
                    }
                    if row.isNSFW {
                        badge("NSFW")
                    }
                }
                if !detailLine.isEmpty {
                    Text(detailLine)
                        .font(.mcMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                statusView
            }
            Spacer(minLength: MCSpacing.compact)
            actionView
        }
        .padding(.vertical, MCSpacing.hairline)
    }

    private var preview: some View {
        ZStack {
            CivitaiThumbnail(url: row.previewURL)
                .blur(radius: blurred ? 18 : 0)
            if blurred {
                Button("Show") {
                    browse.reveal(row.id)
                }
                .controlSize(.mini)
                .accessibilityLabel("Show NSFW preview of \(row.name)")
            }
        }
        .frame(width: MCSize.civitaiThumbnail, height: MCSize.civitaiThumbnail)
        .clipShape(RoundedRectangle(cornerRadius: MCRadius.field))
        .accessibilityLabel(blurred ? "Hidden NSFW preview" : "Preview of \(row.name)")
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.mcBadge)
            .padding(.horizontal, MCSpacing.tight)
            .padding(.vertical, MCSpacing.hairline)
            .background(MCTone.cardFill, in: Capsule())
    }

    @ViewBuilder
    private var statusView: some View {
        switch row.status {
        case .available:
            caption("Available")
        case .installed:
            caption("Installed")
        case .queued:
            caption("Queued")
        case .downloading(let fraction):
            ProgressView(value: fraction)
                .frame(width: 160)
                .accessibilityLabel("Downloading \(row.name)")
        case .added:
            Label("Added to your LoRAs", systemImage: "checkmark.circle")
                .font(.mcMetadata)
                .foregroundStyle(MCTone.success)
        case .addedToStack:
            Label {
                Text("Added to the stack")
            } icon: {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(MCTone.success)
            }
            .font(.mcMetadata)
        case .needsKey:
            Text("Needs a Civitai key to download")
                .font(.mcMetadata)
                .foregroundStyle(MCTone.warning)
        case .refused(let reason):
            Text(reason)
                .font(.mcMetadata)
                .foregroundStyle(MCTone.critical)
                .lineLimit(2)
        case .failed(let text):
            Text(text)
                .font(.mcMetadata)
                .foregroundStyle(MCTone.critical)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var actionView: some View {
        switch row.status {
        case .queued, .downloading:
            Button("Cancel") {
                browse.cancelDownload(modelID: row.id)
            }
            .controlSize(.small)
            .accessibilityLabel("Cancel download of \(row.name)")
        default:
            let title = isFailed ? "Retry" : "Download and Add"
            Button(title) {
                browse.requestDownload(modelID: row.id)
            }
            .controlSize(.small)
            .disabled(!row.canDownload)
            .accessibilityLabel("\(title) \(row.name)")
        }
    }

    private var isFailed: Bool {
        if case .failed = row.status { return true }
        return false
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.mcMetadata)
            .foregroundStyle(.secondary)
    }
}

/// A browse thumbnail read through `CivitaiThumbnailCache`. A cached image shows on the first frame.
private struct CivitaiThumbnail: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(MCTone.cardFill)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if url == nil {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
                    .help("Civitai has no preview image for this LoRA.")
            }
        }
        .frame(width: MCSize.civitaiThumbnail, height: MCSize.civitaiThumbnail)
        .clipped()
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            let small = CivitaiImage.thumbnailURL(url, width: CivitaiThumbnailCache.pixelWidth)
            image = CivitaiThumbnailCache.shared.cached(small)
            if image == nil { image = await CivitaiThumbnailCache.shared.load(url) }
        }
    }
}

/// The license terms and the acceptance that starts a download (D20). Nothing downloads until Accept; Cancel
/// leaves the row as it was.
struct CivitaiLicenseSheet: View {
    let browse: CivitaiBrowseModel
    let pending: CivitaiDownloadSpec

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.group) {
            Text("License for \(pending.modelName)")
                .font(.mcSheetTitle)
            Text("The creator on Civitai set these terms for this LoRA. They apply to the copy you download.")
                .font(.mcSupporting)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: MCSpacing.compact) {
                ForEach(CivitaiLicenseText.lines(pending.license), id: \.self) { line in
                    Text("• \(line)")
                        .font(.mcSupporting)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("By choosing Accept and Download you accept this license. The time you accepted is recorded with the LoRA.")
                .font(.mcSupporting)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") {
                    browse.declinePendingLicense()
                }
                .keyboardShortcut(.cancelAction)
                Button("Accept and Download") {
                    browse.acceptPendingLicense()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(MCSpacing.sheet)
        .frame(width: 480)
    }
}
