import AppKit
import MCGeneration
import SwiftUI

/// The left panel of the three-panel layout (HLD §10): the multi-line prompt, the settings inline, and a pinned bottom
/// row with the ×N batch stepper, Generate (⌘↩) and the error line. Settings show only the controls
/// ``AppModel/controls`` allows for the selected family (R7).
struct GenerationPanel: View {
    @Bindable var model: AppModel
    @State private var isLoRADropTargeted = false
    @State private var estimate: SpeedEstimate?

    /// Changes whenever the composer's estimate may change, so `.task` recomputes it.
    private var estimateTaskID: String {
        "\(model.estimateRevision) \(model.size.width)x\(model.size.height) \(model.steps ?? 0) \(model.selectedModelID ?? "") \(model.loraStack.map(\.isUsed))"
    }

    /// The prompt editor never gets shorter than this. When the window is too short for the settings beside it, the
    /// whole top area scrolls instead of squeezing the prompt.
    private static let promptMinHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .vertical) {
                // Roomy: the prompt takes the height the settings leave over.
                layout(promptFillsHeight: true)
                // Short: the same content scrolls, with the prompt held at its minimum.
                ScrollView {
                    layout(promptFillsHeight: false)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            bottomRow
        }
        .frame(minWidth: 320, idealWidth: 340, maxHeight: .infinity)
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

    private func layout(promptFillsHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: MCSpacing.group) {
            promptEditor
                .frame(
                    minHeight: Self.promptMinHeight,
                    idealHeight: Self.promptMinHeight,
                    maxHeight: promptFillsHeight ? .infinity : Self.promptMinHeight)
            originalPromptField
            enhanceRow
            EnhanceResultCard(model: model)
            settings
            LoRASection(model: model)
        }
        .padding(MCSpacing.group)
    }

    // MARK: Prompt

    private var promptEditor: some View {
        TextEditor(text: $model.prompt)
            .font(.mcBody)
            .scrollContentBackground(.hidden)
            .padding(MCSpacing.compact)
            .background(MCTone.textBackground, in: RoundedRectangle(cornerRadius: MCRadius.field))
            .overlay(RoundedRectangle(cornerRadius: MCRadius.field).stroke(MCTone.separator, lineWidth: MCStroke.hairline))
            .overlay(alignment: .topLeading) {
                if model.prompt.isEmpty {
                    Text("Describe an image")
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

    /// The Enhance button with its caption: the reason it can't run, else the reason the last press was refused, and the
    /// note about the image model reload (U8). The caption is the button's accessibility hint too.
    private var enhanceRow: some View {
        VStack(alignment: .leading, spacing: MCSpacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: MCSpacing.regular) {
                if let caption = model.enhanceBlockReason ?? model.enhanceRefusal {
                    Text(caption)
                        .font(.mcSupporting)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                PromptHistoryButton(model: model)
                Button("Enhance") {
                    Task { await model.pressEnhance() }
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

    private var bottomRow: some View {
        VStack(alignment: .leading, spacing: MCSpacing.compact) {
            HStack(spacing: MCSpacing.regular) {
                Stepper(value: $model.batchCount, in: 1...16) {
                    Text("×\(model.batchCount)")
                        .monospacedDigit()
                }
                .fixedSize()
                .accessibilityLabel("Batch count")
                .accessibilityValue("\(model.batchCount)")

                if let reason = model.generateBlockReason {
                    Text(reason)
                        .font(.mcSupporting)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let estimate {
                    Text(SpeedEstimate.scaled(estimate, by: model.batchCount).label)
                        .font(.mcMetadata)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)

                Button("Generate") {
                    Task { await model.generate() }
                }
                .disabled(!model.canGenerate)
                .buttonStyle(.borderedProminent)
                .help(model.generateBlockReason ?? "Generate (⌘↩)")
                .accessibilityHint(model.generateBlockReason ?? "")
            }
            .task(id: estimateTaskID) {
                estimate = await model.composerEstimate()
            }
            if let error = model.lastError {
                MCStatusText(.critical, error)
            }
        }
        .padding(MCSpacing.group)
    }
}
