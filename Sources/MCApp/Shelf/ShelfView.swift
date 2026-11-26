import MCCatalog
import SwiftUI

/// The Recommended tab of the LoRA sheet (D43): the vouched LoRAs for the selected model, grouped by role. Picking one opens its
/// license, then downloads it and puts it on the stack at the scale it was tested at.
struct ShelfView: View {
    @Bindable var model: AppModel

    private var familyID: String? {
        model.loraFamily?.id
    }

    private var rows: [ShelfModel.Row] {
        model.shelf.rows(family: familyID, includeNSFW: model.civitai.includeNSFW)
    }

    var body: some View {
        Group {
            if familyID == nil {
                ContentUnavailableView(
                    "No model selected", systemImage: "square.stack.3d.up",
                    description: Text("Pick a model to see the LoRAs vouched for it."))
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing on the shelf yet", systemImage: "square.stack.3d.up",
                    description: Text("There are no vouched LoRAs for this model."))
            } else {
                List(rows) { row in
                    ShelfRowView(model: model, row: row)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(
            item: Binding(
                get: { model.shelf.pending.map(PendingEntry.init) },
                set: { if $0 == nil { model.shelf.dismissPending() } })
        ) { pending in
            ShelfLicenseSheet(model: model, entry: pending.entry)
        }
    }

    private struct PendingEntry: Identifiable {
        let entry: LoRAShelfEntry
        var id: String { entry.sha256 }
    }
}

private struct ShelfRowView: View {
    let model: AppModel
    let row: ShelfModel.Row

    private var inStack: Bool {
        model.loraRecords.contains { record in
            record.sha256 == row.entry.sha256 && model.loraSlots.contains { $0.id == record.id }
        }
    }

    /// The Civitai row's anatomy for a curated entry (P10): a leading tile, the name, one supporting line with the
    /// role and the size, then the action.
    var body: some View {
        HStack(alignment: .top, spacing: MCSpacing.regular) {
            tile
            VStack(alignment: .leading, spacing: MCSpacing.hairline) {
                Text(row.entry.displayName)
                    .font(.body.weight(.medium))  // no token: medium-weight row title, as in the Civitai rows
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(row.entry.role.capitalized) · \(ByteCountFormatter.string(fromByteCount: row.entry.sizeBytes, countStyle: .file))")
                    .font(.mcMetadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !row.entry.triggerWords.isEmpty {
                    Text("Trigger words: " + row.entry.triggerWords.joined(separator: ", "))
                        .font(.mcMetadata)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: MCSpacing.compact)
            trailing
        }
        .padding(.vertical, MCSpacing.hairline)
    }

    /// A shelf entry has no preview image, so the tile is a symbol.
    private var tile: some View {
        Image(systemName: "square.stack.3d.up")
            .font(.title2)  // no token: symbol sized for the 64 pt tile
            .foregroundStyle(.secondary)
            .frame(width: MCSize.civitaiThumbnail, height: MCSize.civitaiThumbnail)
            .background(MCTone.cardFill, in: RoundedRectangle(cornerRadius: MCRadius.field))
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.status {
        case .available:
            if inStack {
                Label("In stack", systemImage: "checkmark")
                    .font(.mcSupporting)
                    .foregroundStyle(.secondary)
            } else {
                Button("Add to stack") { Task { await model.shelf.pick(row.entry) } }
                    .disabled(!model.loraAddEnabled)
            }
        case .downloading(let fraction):
            ProgressView(value: fraction).frame(width: 120)
        case .unavailable:
            Text("No longer available").font(.mcSupporting).foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .trailing, spacing: MCSpacing.tight) {
                MCStatusText(.critical, message).lineLimit(2)
                Button("Try again") { Task { await model.shelf.pick(row.entry) } }
            }
        }
    }
}

/// The license sheet for a shelf LoRA (D20): the license as the source publishes it, accepted before anything downloads.
private struct ShelfLicenseSheet: View {
    let model: AppModel
    let entry: LoRAShelfEntry

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.group) {
            Text(entry.displayName).font(.mcSheetTitle)
            ScrollView {
                Text(entry.license)
                    .font(.mcSupporting)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 280)
            Text("By choosing Accept and Download you accept this license.")
                .font(.mcSupporting)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.shelf.dismissPending() }
                    .keyboardShortcut(.cancelAction)
                Button("Accept and Download") { Task { await model.shelf.acceptPending() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(MCSpacing.sheet)
        .frame(width: MCSize.sheetStandard)
    }
}
