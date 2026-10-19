import MCCatalog
import SwiftUI

/// The left panel of the three-panel layout (HLD §10): the multi-line prompt, the settings inline, and a pinned bottom
/// row with the ×N batch stepper, Generate (⌘↩) and the error line. Settings show only the controls
/// ``AppModel/controls`` allows for the selected family (R7).
struct GenerationPanel: View {
    @Bindable var model: AppModel

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
    }

    private func layout(promptFillsHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            promptEditor
                .frame(
                    minHeight: Self.promptMinHeight,
                    idealHeight: Self.promptMinHeight,
                    maxHeight: promptFillsHeight ? .infinity : Self.promptMinHeight)
            settings
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
                    Text("\(size.width) × \(size.height)").tag(size)
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
                    Text(model.guidance.map { String(format: "%.1f", $0) } ?? "Default")
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

                Spacer(minLength: 0)

                Button("Generate") {
                    Task { await model.generate() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canGenerate)
                .buttonStyle(.borderedProminent)
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
