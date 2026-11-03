import AppKit
import MCCatalog
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
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isLoRADropTargeted) { providers in
            LoRADrop.handle(providers, model: model)
        }
    }

    private func layout(promptFillsHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
        .padding(12)
    }

    // MARK: Prompt

    private var promptEditor: some View {
        TextEditor(text: $model.prompt)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .overlay(alignment: .topLeading) {
                if model.prompt.isEmpty {
                    Text("Describe an image")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
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
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Original prompt")
                        .font(.caption)
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
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 72)
                .accessibilityLabel("Original prompt, read only: \(original)")
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .accessibilityElement(children: .contain)
        }
    }

    /// The Enhance button with its caption: the reason it can't run, else the reason the last press was refused, and the
    /// note about the image model reload (U8). The caption is the button's accessibility hint too.
    private var enhanceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let caption = model.enhanceBlockReason ?? model.enhanceRefusal {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Settings

    @ViewBuilder
    private var settings: some View {
        if let controls = model.controls {
            Form {
                seedSection
                sizeSection(controls)
                stepsSection(controls)
                if let guidance = controls.guidance {
                    guidanceSection(guidance)
                }
                if controls.showsNegativePrompt {
                    Section("Negative prompt") {
                        TextField("Things to avoid", text: $model.negativePrompt, axis: .vertical)
                            .lineLimit(1...4)
                            .accessibilityLabel("Negative prompt")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Choose an available model to see its settings.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var seedSection: some View {
        Section("Seed") {
            Picker("Seed policy", selection: $model.seedChoice) {
                Text("Random").tag(SeedChoice.random)
                Text("Fixed").tag(SeedChoice.fixed)
                Text("Increment").tag(SeedChoice.increment)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.seedChoice != .random {
                TextField(
                    model.seedChoice == .fixed ? "Seed" : "Base seed",
                    text: $model.seedText
                )
                .monospacedDigit()
                .accessibilityLabel(model.seedChoice == .fixed ? "Seed" : "Base seed")
            }
        }
    }

    private func sizeSection(_ controls: SettingsControls) -> some View {
        Section("Size") {
            Picker("Size", selection: $model.size) {
                ForEach(controls.sizes, id: \.self) { size in
                    Text(verbatim: "\(size.width) × \(size.height)").tag(size)
                }
            }
        }
    }

    private func stepsSection(_ controls: SettingsControls) -> some View {
        Section("Steps") {
            if controls.stepsAreFixed {
                Text("\(controls.steps.defaultSteps) steps, set by the model")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(model.steps.map(String.init) ?? "Default")
                            .monospacedDigit()
                            .foregroundStyle(model.steps == nil ? .secondary : .primary)
                        Stepper(
                            "Steps",
                            value: Binding(
                                get: { model.steps ?? controls.steps.defaultSteps },
                                set: { model.steps = $0 }
                            ),
                            in: controls.steps.min...controls.steps.max
                        )
                        .labelsHidden()
                        if model.steps != nil {
                            Button("Use Default") { model.steps = nil }
                                .buttonStyle(.link)
                        }
                    }
                } label: {
                    Text("Steps")
                }
                .accessibilityValue(model.steps.map { "\($0)" } ?? "Default")
            }
        }
    }

    private func guidanceSection(_ guidance: GuidanceCapability) -> some View {
        Section("Guidance") {
            LabeledContent {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { model.guidance ?? guidance.defaultValue },
                            set: { model.guidance = $0 }
                        ),
                        in: guidance.min...guidance.max,
                        step: 0.1
                    )
                    .frame(width: 160)
                    Text(model.guidance.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "Default")
                        .monospacedDigit()
                        .foregroundStyle(model.guidance == nil ? .secondary : .primary)
                    if model.guidance != nil {
                        Button("Use Default") { model.guidance = nil }
                            .buttonStyle(.link)
                    }
                }
            } label: {
                Text("CFG scale")
            }
        }
    }

    // MARK: Bottom row

    private var bottomRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Stepper(value: $model.batchCount, in: 1...16) {
                    Text("×\(model.batchCount)")
                        .monospacedDigit()
                }
                .fixedSize()
                .accessibilityLabel("Batch count")
                .accessibilityValue("\(model.batchCount)")

                if let reason = model.generateBlockReason {
                    Text(reason)
                        .font(.callout)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let estimate {
                    Text(SpeedEstimate.scaled(estimate, by: model.batchCount).label)
                        .font(.caption)
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
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }
}
