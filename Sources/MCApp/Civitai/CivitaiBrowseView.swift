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

/// The Browse Civitai tab of the LoRA library sheet (plan U7). State and downloads live on `CivitaiBrowseModel`, which
/// `AppModel` owns, so a download keeps running after the sheet closes. Nothing here attaches a download to the stack (R5).
struct CivitaiBrowseView: View {
    @Bindable var model: AppModel
    @State private var showingKey = false
    @State private var revealedIDs: Set<Int> = []

    private var browse: CivitaiBrowseModel { model.civitai }

    private var selectedModelName: String? {
        model.selectedModel.map { ModelChip.title(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(12)
            if showingKey {
                CivitaiKeyField(browse: browse)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            Divider()
            content
            Divider()
            footer
                .padding(12)
        }
        .task {
            await browse.search()
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search Civitai LoRAs", text: Binding(
                    get: { browse.query },
                    set: { browse.setQuery($0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .accessibilityLabel("Search Civitai LoRAs")
                Picker("Sort", selection: Binding(
                    get: { browse.sort },
                    set: { sort in Task { await browse.setSort(sort) } })) {
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
            HStack(spacing: 14) {
                Toggle("Show incompatible", isOn: Binding(
                    get: { browse.showIncompatible },
                    set: { on in Task { await browse.setShowIncompatible(on) } }))
                    .toggleStyle(.checkbox)
                Toggle("Include NSFW", isOn: Binding(
                    get: { browse.includeNSFW },
                    set: { on in Task { await browse.setIncludeNSFW(on) } }))
                    .toggleStyle(.checkbox)
                Spacer(minLength: 0)
                if let name = selectedModelName {
                    Text("Fits \(name) by default")
                        .font(.caption)
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
            VStack(spacing: 8) {
                Text("No LoRAs match this search.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
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
            VStack(spacing: 10) {
                Text(text ?? "Civitai needs an API key to download this LoRA.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                CivitaiKeyField(browse: browse)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        case .regionLimited:
            message("Civitai is not available in your region for this search.")
        case .failed(let text):
            VStack(spacing: 8) {
                Text(text)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") {
                    Task { await browse.search() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
    }

    private var resultsList: some View {
        let rows = browse.rows
        return List(rows) { row in
            CivitaiResultRowView(
                browse: browse,
                row: row,
                modelName: selectedModelName,
                isRevealed: revealedIDs.contains(row.id),
                onReveal: { revealedIDs.insert(row.id) })
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
        HStack(spacing: 8) {
            if let line = browse.activeDownloadLine {
                Text(line)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Downloads keep going if you close this sheet. A downloaded LoRA goes to your library, not the stack.")
                    .font(.caption)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = browse.keyError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("The key is sent only to civitai.com.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One result row: preview, name, creator, size, downloads, status, and the Download or Cancel action.
private struct CivitaiResultRowView: View {
    let browse: CivitaiBrowseModel
    let row: CivitaiResultRow
    let modelName: String?
    let isRevealed: Bool
    let onReveal: () -> Void

    /// Blurred while NSFW and neither the NSFW opt-in is on nor this preview was revealed.
    private var blurred: Bool {
        row.isNSFW && !browse.includeNSFW && !isRevealed
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
        HStack(alignment: .top, spacing: 10) {
            preview
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.body.weight(.medium))
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                statusView
            }
            Spacer(minLength: 6)
            actionView
        }
        .padding(.vertical, 3)
    }

    private var preview: some View {
        ZStack {
            AsyncImage(url: row.previewURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle().fill(.quaternary)
                }
            }
            .blur(radius: blurred ? 18 : 0)
            if blurred {
                Button("Show") {
                    onReveal()
                }
                .controlSize(.mini)
                .accessibilityLabel("Show NSFW preview of \(row.name)")
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(blurred ? "Hidden NSFW preview" : "Preview of \(row.name)")
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
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
                .font(.caption)
                .foregroundStyle(.green)
        case .needsKey:
            Text("Needs a Civitai key to download")
                .font(.caption)
                .foregroundStyle(.orange)
        case .refused(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case .failed(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.red)
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
            Button(isFailed ? "Retry" : "Download") {
                browse.requestDownload(modelID: row.id)
            }
            .controlSize(.small)
            .disabled(!row.canDownload)
            .accessibilityLabel("\(isFailed ? "Retry" : "Download") \(row.name)")
        }
    }

    private var isFailed: Bool {
        if case .failed = row.status { return true }
        return false
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// The license terms and the acceptance that starts a download (D20). Nothing downloads until Accept; Cancel
/// leaves the row as it was.
struct CivitaiLicenseSheet: View {
    let browse: CivitaiBrowseModel
    let pending: CivitaiDownloadSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("License for \(pending.modelName)")
                .font(.title3.bold())
            Text("The creator on Civitai set these terms for this LoRA. They apply to the copy you download.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(CivitaiLicenseText.lines(pending.license), id: \.self) { line in
                    Text("• \(line)")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Your acceptance and the time you accepted are recorded with the LoRA.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") {
                    browse.declinePendingLicense()
                }
                .keyboardShortcut(.cancelAction)
                Button("Accept and download") {
                    browse.acceptPendingLicense()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
