import AppKit
import MCGeneration
import SwiftUI

/// The left panel of the three-panel layout (HLD §10): the prompt card (the multi-line editor with its own bottom bar
/// holding recent prompts and Enhance), the settings right under it, and a pinned bottom row with the Images control,
/// Generate (⌘↩) and the error line. Settings show only the controls ``AppModel/controls`` allows for the selected
/// family (R7).
struct GenerationPanel: View {
    @Bindable var model: AppModel
    @State private var isLoRADropTargeted = false
    @State private var estimate: SpeedEstimate?
    /// The panel's height, so the prompt card's growth cap follows it.
    @State private var panelHeight: CGFloat = 0

    /// Changes whenever the composer's estimate may change, so `.task` recomputes it.
    private var estimateTaskID: String {
        "\(model.estimateRevision) \(model.size.width)x\(model.size.height) \(model.steps ?? 0) \(model.selectedModelID ?? "") \(model.loraStack.map(\.isUsed))"
    }

    /// The prompt editor's limits: about five lines of `.mcBody` at its smallest, and about sixty percent of the
    /// panel at its tallest, where it starts to scroll instead of growing (P02).
    private static let promptMinHeight: CGFloat = 100
    private static let promptMaxFraction: CGFloat = 0.6
    private var promptMaxHeight: CGFloat {
        max(Self.promptMinHeight, panelHeight * Self.promptMaxFraction)
    }

    /// The batch counts the Images control offers, and the range its numeric field accepts.
    private static let batchChoices = [1, 2, 4]
    private static let batchRange = 1...16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                layout
            }
            .frame(maxHeight: .infinity)

            Divider()
            bottomRow
        }
        .frame(minWidth: 320, idealWidth: 340, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            panelHeight = height
        }
        .overlay {
            if isLoRADropTargeted {
                RoundedRectangle(cornerRadius: MCRadius.card)
                    .stroke(MCTone.selection, lineWidth: MCStroke.selection)
                    .padding(MCSpacing.tight)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isLoRADropTargeted) { providers in
            LoRADrop.handle(providers, model: model)
        }
    }

    private var layout: some View {
        VStack(alignment: .leading, spacing: MCSpacing.group) {
            promptCard
            originalPromptField
            EnhanceResultCard(model: model)
            settings
            LoRASection(model: model)
        }
        .padding(MCSpacing.group)
    }

    // MARK: Prompt

    /// The prompt editor as a card (P02): it grows with what is written, and recent prompts and Enhance sit in its
    /// own bottom bar rather than floating under it.
    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            promptEditor
                .frame(minHeight: Self.promptMinHeight, maxHeight: promptMaxHeight)
            Divider()
            promptToolbar
        }
        .background(MCTone.textBackground, in: RoundedRectangle(cornerRadius: MCRadius.card))
        .overlay(RoundedRectangle(cornerRadius: MCRadius.card).stroke(MCTone.separator, lineWidth: MCStroke.hairline))
    }

    private var promptEditor: some View {
        TextEditor(text: $model.prompt)
            .font(.mcBody)
            .scrollContentBackground(.hidden)
            // A mouse attached to the Mac gives the editor a legacy scroller with a permanent track (P02); the
            // probe gives its scroll view an overlay scroller, which never draws one.
            .background { EditorScrollerOverlay() }
            .scrollIndicators(.automatic)
            .padding(MCSpacing.compact)
            .overlay(alignment: .topLeading) {
                if model.prompt.isEmpty {
                    Text("Describe a picture: a lighthouse at golden hour, waves crashing")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, MCSpacing.group)
                        .padding(.vertical, MCSpacing.compact)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("Prompt")
            // Tab and ⇧Tab leave the prompt like any other field, so keyboard focus is never trapped. ⌥Tab still types a tab.
            // ⇧Tab arrives as the back-tab character U+0019, not as `.tab` with ⇧, so both keys are listed.
            .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")], phases: .down) { press in
                if press.modifiers.contains(.option) { return .ignored }
                if press.key == .tab && !press.modifiers.contains(.shift) {
                    NSApp.keyWindow?.selectNextKeyView(nil)
                } else {
                    NSApp.keyWindow?.selectPreviousKeyView(nil)
                }
                return .handled
            }
    }

    /// The card's bottom bar: the reason Enhance cannot run or why its last press was refused, then Recent prompts
    /// and Enhance. The caption is the button's accessibility hint too; the reload note sits under the row (U8).
    private var promptToolbar: some View {
        VStack(alignment: .leading, spacing: MCSpacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: MCSpacing.regular) {
                if let caption = model.enhanceBlockReason ?? model.enhanceRefusal {
                    Text(caption)
                        .font(.mcSupporting)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                PromptHistoryButton(model: model)
                Button {
                    Task { await model.pressEnhance() }
                } label: {
                    Label("Enhance", systemImage: "sparkles")
                }
                .disabled(!model.canEnhance)
                .accessibilityHint(
                    model.enhanceBlockReason ?? "Rewrites the prompt for the selected model and LoRAs. Accept keeps the result.")
            }
            if let note = model.enhanceReloadNote {
                Text(note)
                    .font(.mcSupporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MCSpacing.regular)
    }

    /// The prompt an accepted enhancement replaced, read-only (KTD7). It is the text saved as provenance with the next image.
    @ViewBuilder
    private var originalPromptField: some View {
        if let original = model.originalPrompt {
            VStack(alignment: .leading, spacing: MCSpacing.tight) {
                HStack {
                    Text("Original prompt")
                        .font(.mcMetadata)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Restore") { model.restoreOriginalPrompt() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .help("Put the original prompt back")
                        .accessibilityLabel("Restore original prompt")
                }
                ScrollView {
                    Text(original)
                        .font(.mcSupporting)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 72)
                .accessibilityLabel("Original prompt, read only: \(original)")
            }
            .padding(MCSpacing.regular)
            .background(MCTone.controlBackground, in: RoundedRectangle(cornerRadius: MCRadius.field))
            .overlay(RoundedRectangle(cornerRadius: MCRadius.field).stroke(MCTone.separator, lineWidth: MCStroke.hairline))
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Settings

    @ViewBuilder
    private var settings: some View {
        if let controls = model.controls {
            ComposerSettings(model: model, controls: controls)
        } else {
            Text("Choose an available model to see its settings.")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Bottom row

    /// The batch count, the block reason on its own full-width line, and the full-width Generate with the estimate
    /// and ⌘↩ hint under it (P03). The estimate task reruns whenever the composer's inputs change.
    private var bottomRow: some View {
        VStack(alignment: .leading, spacing: MCSpacing.compact) {
            imagesControl

            if let reason = model.generateBlockReason {
                Text(reason)
                    .font(.mcSupporting)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Generate") {
                Task { await model.generate() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Tahoe's prominent capsule hugs its title; only .buttonSizing makes it take the row's width.
            .buttonSizing(.flexible)
            .frame(maxWidth: .infinity)
            .disabled(!model.canGenerate)
            .help(model.generateBlockReason ?? "Generate (⌘↩)")
            .accessibilityHint(model.generateBlockReason ?? "")

            if model.generateBlockReason == nil {
                Text(verbatim: estimateLine)
                    .font(.mcMetadata)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if let error = model.lastError {
                MCStatusText(.critical, error)
            }
        }
        .padding(MCSpacing.group)
        .task(id: estimateTaskID) {
            estimate = await model.composerEstimate()
        }
    }

    /// The secondary line under Generate: the per-batch estimate when one exists, and the ⌘↩ hint always.
    private var estimateLine: String {
        let hint = "⌘↩"
        guard let estimate else { return hint }
        return "\(SpeedEstimate.scaled(estimate, by: model.batchCount).label) · \(hint)"
    }

    /// Batch count as the common counts in a compact segmented control plus a numeric field for the rest of the
    /// range (P03). The field keeps the accessibility label "Batch count".
    private var imagesControl: some View {
        HStack(spacing: MCSpacing.regular) {
            Text("Images")
            Picker("Images", selection: $model.batchCount) {
                ForEach(Self.batchChoices, id: \.self) { count in
                    Text(verbatim: "\(count)").tag(count)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextField(
                "Batch count",
                value: Binding(
                    get: { model.batchCount },
                    set: { model.batchCount = min(max($0, Self.batchRange.lowerBound), Self.batchRange.upperBound) }
                ),
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 34)
            .accessibilityLabel("Batch count")
            .accessibilityValue("\(model.batchCount)")
        }
    }
}

/// Finds the `TextEditor`'s own `NSScrollView` (a sibling, reached through an ancestor's subtree) and switches it
/// to overlay scrollers, which never draw a track. Needed only for P02: on a Mac with a mouse the editor's legacy
/// scroller shows a permanent grey track even though the text fits.
private struct EditorScrollerOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> EditorScrollerProbe {
        EditorScrollerProbe()
    }

    func updateNSView(_ nsView: EditorScrollerProbe, context: Context) {
        nsView.applyOverlayStyle()
    }
}

private final class EditorScrollerProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // The editor's scroll view can appear after this probe does, so try again on the next pass too.
        DispatchQueue.main.async { [weak self] in self?.applyOverlayStyle() }
    }

    fileprivate func applyOverlayStyle() {
        var container = superview
        while let current = container {
            if let scroll = Self.editorScrollView(in: current) {
                // Overlay scrollers draw no track, and autohiding keeps the knob away until a real scroll happens.
                scroll.scrollerStyle = .overlay
                scroll.autohidesScrollers = true
                return
            }
            container = current.superview
        }
    }

    /// The first scroll view in the subtree whose document is a text view — the editor's, because this probe sits
    /// inside the same editor branch.
    private static func editorScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTextView { return scroll }
        return view.subviews.lazy.compactMap(editorScrollView(in:)).first
    }
}
