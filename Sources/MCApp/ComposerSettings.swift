import MCCatalog
import SwiftUI

/// The composer's settings below the prompt: the size is always visible, while the seed controls, steps, CFG scale and
/// negative prompt sit behind "More options". Which rows exist follows the selected family through ``SettingsControls``.
/// All of it lies on one two-column grid — labels leading in the first column, controls in the second — so every row
/// shares the composer's leading edge and no label wraps (P01).
struct ComposerSettings: View {
    @Bindable var model: AppModel
    let controls: SettingsControls
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: MCSpacing.regular, verticalSpacing: MCSpacing.group) {
            row("Size") { sizePicker }
            moreOptionsToggle
            if model.showsMoreOptions {
                row("Seed") { seedPolicyPicker }
                if model.seedChoice != .random {
                    GridRow {
                        // no token: an empty label cell, so the seed field sits in the controls column. Zero-sized:
                        // a bare Color is greedy and the grid would size the label column to it (P01).
                        Color.clear.frame(width: 0, height: 0)
                        seedField
                    }
                }
                stepsRow
                if let guidance = controls.guidance {
                    guidanceRow(guidance)
                }
                if controls.showsNegativePrompt {
                    row("Negative prompt") { negativePromptField }
                }
            }
        }
    }

    /// Every label a row can carry for these controls, whether the row is shown or not. The label column keeps one
    /// width — the widest of these — so the controls column's leading edge never moves when "More options" opens or
    /// closes (P01).
    private var labelTitles: [String] {
        var titles = ["Size", "Seed", "Steps"]
        if controls.guidance != nil { titles.append("CFG scale") }
        if controls.showsNegativePrompt { titles.append("Negative prompt") }
        return titles
    }

    /// One labelled row. Hidden copies of every possible label pin the first column to the widest label the family
    /// can show; the second column takes the flexible width and leads, so a control's leading x is the same in every
    /// disclosure state. `.lineLimit(1)` keeps a label to one line whatever the panel's width.
    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        GridRow {
            ZStack(alignment: .leading) {
                ForEach(labelTitles, id: \.self) { Text($0).lineLimit(1).hidden() }
                Text(title)
                    .lineLimit(1)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Opens and closes the disclosure, as a full-width row spanning both grid columns. Its collapsed label carries
    /// the summary of every non-default option.
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

    private var seedPolicyPicker: some View {
        Picker("Seed policy", selection: $model.seedChoice) {
            Text("Random").tag(SeedChoice.random)
            Text("Fixed").tag(SeedChoice.fixed)
            Text("Increment").tag(SeedChoice.increment)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // Flexible like the rest of the controls column: a fixed size would overflow the composer when the pinned
        // label column leaves it less room (P01).
    }

    private var seedField: some View {
        TextField(
            model.seedChoice == .fixed ? "Seed" : "Base seed",
            text: $model.seedText
        )
        .monospacedDigit()
        .accessibilityLabel(model.seedChoice == .fixed ? "Seed" : "Base seed")
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 160, alignment: .leading)
    }

    @ViewBuilder
    private var stepsRow: some View {
        if controls.stepsAreFixed {
            row("Steps") {
                Text("\(controls.steps.defaultSteps) steps, set by the model")
                    .foregroundStyle(.secondary)
            }
        } else {
            row("Steps") {
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
            }
        }
    }

    private func guidanceRow(_ guidance: GuidanceCapability) -> some View {
        row("CFG scale") {
            HStack(spacing: MCSpacing.regular) {
                Slider(
                    value: Binding(
                        get: { model.guidance ?? guidance.defaultValue },
                        set: { model.guidance = $0 }
                    ),
                    in: guidance.min...guidance.max,
                    step: 0.1
                )
                .frame(maxWidth: 160)
                Text(model.guidance.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "Default")
                    .monospacedDigit()
                    .foregroundStyle(model.guidance == nil ? .secondary : .primary)
                if model.guidance != nil {
                    Button("Use Default") { model.guidance = nil }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private var negativePromptField: some View {
        TextField("Things to avoid", text: $model.negativePrompt, axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Negative prompt")
    }
}
