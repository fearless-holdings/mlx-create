import MCCatalog
import SwiftUI

/// The ⚙ popover (HLD §8.3). Shows only controls ``AppModel/controls`` allows for the selected family (R7).
struct SettingsPopover: View {
    @Bindable var model: AppModel

    var body: some View {
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
            .frame(width: 360)
        } else {
            Text("Choose an available model to see its settings.")
                .foregroundStyle(.secondary)
                .padding()
                .frame(width: 280)
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
}
