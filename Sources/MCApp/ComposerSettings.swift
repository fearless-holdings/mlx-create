import MCCatalog
import SwiftUI

/// The composer's settings below the prompt: the size is always visible, while the seed controls, steps, CFG scale and
/// negative prompt sit behind "More options". Which rows exist follows the selected family through ``SettingsControls``.
struct ComposerSettings: View {
    @Bindable var model: AppModel
    let controls: SettingsControls
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: MCSpacing.group) {
            LabeledContent("Size") { sizePicker }
            moreOptionsToggle
            if model.showsMoreOptions {
                VStack(alignment: .leading, spacing: MCSpacing.group) {
                    seedRows
                    stepsRow
                    if let guidance = controls.guidance {
                        guidanceRow(guidance)
                    }
                    if controls.showsNegativePrompt {
                        LabeledContent("Negative prompt") {
                            TextField("Things to avoid", text: $model.negativePrompt, axis: .vertical)
                                .lineLimit(1...4)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Negative prompt")
                        }
                    }
                }
                .padding(.leading, MCSpacing.section)
            }
        }
    }

    private var sizePicker: some View {
        Picker("Size", selection: $model.size) {
            ForEach(controls.sizes, id: \.self) { size in
                Text(verbatim: "\(size.width) × \(size.height)").tag(size)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// Opens and closes the disclosure. Its collapsed label carries the summary of every non-default option.
    private var moreOptionsToggle: some View {
        Button {
            if reduceMotion {
                model.showsMoreOptions.toggle()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { model.showsMoreOptions.toggle() }
            }
        } label: {
            HStack(spacing: MCSpacing.compact) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))  // no token: same font as mcBadge, but that token is for badge text
                    .rotationEffect(.degrees(model.showsMoreOptions ? 90 : 0))
                    .accessibilityHidden(true)
                Text("More options")
                if !model.showsMoreOptions, let summary = model.moreOptionsSummary {
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More options")
        .accessibilityValue(model.showsMoreOptions ? "expanded" : (model.moreOptionsSummary ?? "collapsed"))
    }

    @ViewBuilder
    private var seedRows: some View {
        LabeledContent("Seed") {
            Picker("Seed policy", selection: $model.seedChoice) {
                Text("Random").tag(SeedChoice.random)
                Text("Fixed").tag(SeedChoice.fixed)
                Text("Increment").tag(SeedChoice.increment)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        if model.seedChoice != .random {
            TextField(
                model.seedChoice == .fixed ? "Seed" : "Base seed",
                text: $model.seedText
            )
            .monospacedDigit()
            .accessibilityLabel(model.seedChoice == .fixed ? "Seed" : "Base seed")
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 160)
        }
    }

    @ViewBuilder
    private var stepsRow: some View {
        if controls.stepsAreFixed {
            Text("\(controls.steps.defaultSteps) steps, set by the model")
                .foregroundStyle(.secondary)
        } else {
            LabeledContent {
                HStack(spacing: MCSpacing.regular) {
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

    private func guidanceRow(_ guidance: GuidanceCapability) -> some View {
        LabeledContent {
            HStack(spacing: MCSpacing.regular) {
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
