import Foundation
import MCCatalog
import MCModels
import SwiftUI

/// What the Chat setup screen shows for the catalog's agent model (D60, amended 2026-11-24). The screen's one
/// action — Download, Resume or Retry — is `ModelBrowserModel.installAcceptedNow`, which records the license
/// acceptance itself (D20); the license sheet belongs to the model browser, not here.
enum ChatSetupPhase: Equatable {
    /// Installs are off or the catalog lists no agent model: plain text, no action.
    case unavailable
    /// A folder without a verified install record blocks the destination. The user must move or delete it first.
    case unverified(path: String)
    /// Download — also what a missing-files row offers again.
    case ready
    /// The install runs; `step` is the progress card's current step (0 Download, 1 Check the files).
    case downloading(step: Int, progress: ModelBrowserRow.Progress)
    /// The download stopped partway; Resume continues it from the partials.
    case paused(bytesOnDisk: Int64, bytesTotal: Int64)
    /// The install failed; `retryable` offers Retry.
    case failed(String, retryable: Bool)
    /// The files and record are in place; the engine has not listed the model yet.
    case gettingReady

    /// The progress step the screen announces; nil outside the live install states — a paused or failed
    /// install announces its own heading instead.
    var step: Int? {
        switch self {
        case .downloading(let step, _): step
        case .gettingReady: 2
        case .unavailable, .unverified, .ready, .paused, .failed: nil
        }
    }

    init(row: ModelBrowserRow?, installsAvailable: Bool) {
        guard installsAvailable, let row, row.model?.kind == .agent else {
            self = .unavailable
            return
        }
        switch row.state {
        case .available, .missingFiles:
            self = .ready
        case .installing(let progress):
            if progress.phase == .installed {
                self = .gettingReady
            } else {
                self = .downloading(step: Self.step(for: progress.phase), progress: progress)
            }
        case .installed:
            // `inEngine` true means Chat is already ready and this screen is gone; false is the gap between
            // the install record landing and the engine listing the model.
            self = .gettingReady
        case .interrupted(let bytesOnDisk, let bytesTotal):
            self = .paused(bytesOnDisk: bytesOnDisk, bytesTotal: bytesTotal)
        case .failed(let message):
            self = .failed(message, retryable: row.action == .retry)
        case .unverified(let path):
            self = .unverified(path: path)
        }
    }

    /// preflight and downloading are the download step; verifying and moving check the files; `installed`
    /// means the engine listing is next. `failed`/`cancelled` are transient — the row's state decides what
    /// the screen shows a moment later.
    private static func step(for phase: InstallEvent.Phase) -> Int {
        switch phase {
        case .preflight, .downloading: 0
        case .verifying, .moving: 1
        case .installed: 2
        case .failed, .cancelled: 0
        }
    }
}

/// The Chat setup screen (D60, amended 2026-11-24): what Chat mode shows in place of the conversation while
/// the agent LLM is not installed. One Download action installs it — the license line under the button is
/// the acceptance (D20) — then one progress card walks the install's phases, paused and failed included,
/// until the engine lists the model and Chat takes over. The full license lives in Settings ▸ Licenses.
struct ChatSetupView: View {
    let model: AppModel

    /// The progress step last announced, so a repeated refresh does not read the same step twice.
    @State private var announcedStep: Int?

    private var browser: ModelBrowserModel { model.browser }
    private var agent: CatalogModel? { browser.catalogModel(ofKind: .agent) }
    private var row: ModelBrowserRow? { browser.rows(of: .agent).first }
    private var phase: ChatSetupPhase {
        ChatSetupPhase(row: row, installsAvailable: model.installs != nil)
    }
    private var license: PendingLicense? {
        agent.map { browser.pendingLicense(for: $0) }
    }

    /// The progress card's steps, in order; the size rides on the first.
    private static let steps = ["Download", "Check the files", "Get Chat ready"]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(spacing: MCSpacing.section) {
                        header
                        if showsFacts {
                            facts
                        }
                        stateContent
                        if let actionBlockedReason {
                            Text(actionBlockedReason)
                                .font(.mcSupporting)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        licenseContent
                    }
                    .padding(MCSpacing.emptyState)
                    .frame(maxWidth: MCSize.chatSetupMaxWidth)
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: geometry.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatSetup")
        .onChange(of: phase.step) { _, step in announce(step: step) }
    }

    /// Facts belong beside a download decision; they are noise where no download can start.
    private var showsFacts: Bool {
        guard agent != nil, model.installs != nil else { return false }
        switch phase {
        case .unavailable, .unverified: return false
        case .ready, .downloading, .paused, .failed, .gettingReady: return true
        }
    }

    /// Whether Download, Resume or Retry can start right now. `installTask` covers the preflight beat before the
    /// installer publishes its active row, so a fast second click cannot queue behind the first one.
    private var installActionEnabled: Bool {
        browser.installTask == nil && row?.canAct == true
    }

    /// Why an offered install action is disabled, when the row knows one (usually another model installing).
    private var actionBlockedReason: String? {
        let offered: Bool
        switch phase {
        case .ready, .paused: offered = true
        case .failed(_, let retryable): offered = retryable
        case .unavailable, .unverified, .downloading, .gettingReady: offered = false
        }
        return offered ? row?.actionBlockedReason : nil
    }

    /// The hero symbol, title and the why paragraph — the same on every state the screen can be in.
    private var header: some View {
        VStack(spacing: MCSpacing.group) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: MCSize.chatSetupSymbol))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Make pictures by describing them")
                .font(.mcSheetTitle)
            Text(
                "Chat uses a language model that runs on this Mac to turn what you write into the right model, prompt and settings. It's a one-time download, and Chat works offline after that. What you write never leaves this Mac."
            )
            .font(.mcBody)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Size, reference download times and where the model runs — the facts a download decision needs, as
    /// three equal columns: icon, value, caption.
    private var facts: some View {
        HStack(alignment: .top, spacing: MCSpacing.group) {
            fact(
                icon: "arrow.down.circle",
                value: agent?.downloadBytes.formatted(.byteCount(style: .file)) ?? "",
                caption: "One-time download")
            fact(
                icon: "clock",
                value: timeValue,
                caption: timeCaption)
            fact(
                icon: "laptopcomputer",
                value: "On this Mac",
                caption: "Works offline")
        }
    }

    private func fact(icon: String, value: String, caption: String) -> some View {
        VStack(spacing: MCSpacing.tight) {
            Image(systemName: icon)
                .font(.mcSupporting)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(value)
                .font(.mcRowTitle)
            Text(caption)
                .font(.mcMetadata)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// "About 9 min" — the download estimate at 100 Mbit/s.
    private var timeValue: String {
        guard let agent else { return "" }
        let minutes = Self.referenceMinutes(bytes: agent.downloadBytes, megabitsPerSecond: 100)
        return "About \(minutes) min"
    }

    /// "at 100 Mbit/s · 1 min at 1 Gbit/s" — the same estimate's caption.
    private var timeCaption: String {
        guard let agent else { return "" }
        let fast = Self.referenceMinutes(bytes: agent.downloadBytes, megabitsPerSecond: 1000)
        return "at 100 Mbit/s · \(fast) min at 1 Gbit/s"
    }

    /// The download-time estimate at a reference speed, in whole minutes (minimum 1): the bytes' bits at
    /// `megabitsPerSecond` Mbit/s, ceiled. "About 9 min" for the agent pack at 100 Mbit/s.
    static func referenceMinutes(bytes: Int64, megabitsPerSecond: Int) -> Int {
        guard megabitsPerSecond > 0, bytes > 0 else { return 1 }
        let seconds = Double(bytes) * 8 / (Double(megabitsPerSecond) * 1_000_000)
        return max(1, Int((seconds / 60).rounded(.up)))
    }

    @ViewBuilder
    private var stateContent: some View {
        switch phase {
        case .unavailable:
            Text(unavailableText)
                .font(.mcBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        case .unverified(let path):
            unverifiedContent(path: path)
        case .ready:
            Button("Download Chat Model") {
                Task { await installAgent() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(!installActionEnabled)
            .accessibilityIdentifier("chatSetupDownload")
        case .downloading, .paused, .failed, .gettingReady:
            VStack(spacing: MCSpacing.group) {
                progressCard
                if let resumeNote {
                    Text(resumeNote)
                        .font(.mcSupporting)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The plain-language reason there is nothing to download, for the states that offer no action.
    private var unavailableText: String {
        if model.installs == nil {
            return "The model catalog could not be verified, so Chat can't be set up right now."
        }
        if agent == nil {
            return "This version of MLX Create has no Chat model to install."
        }
        return "Chat can't be set up right now."
    }

    /// The stray-folder state is actionable: it names the folder, says what to do with it, and offers the
    /// refresh that picks up the remedy. Nothing here deletes or moves the user's files.
    private func unverifiedContent(path: String) -> some View {
        VStack(spacing: MCSpacing.group) {
            Text("Unverified local files use the Chat model's folder name. MLX Create does not overwrite them.")
                .font(.mcBody)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(path)
                .font(.mcMetadataMonospaced)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
            Text("Move or delete that folder, then check again.")
                .font(.mcSupporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Check Again") {
                Task { await browser.refresh() }
            }
        }
    }

    /// Download, Resume and Retry share one action: the install records the license acceptance itself (D20).
    /// Unlike a card's sequential items, this user action never queues behind another install — when one is
    /// active the button is disabled instead of restarting later after a cancel.
    private func installAgent() async {
        guard let agent, installActionEnabled else { return }
        _ = browser.installAcceptedNow(agent.id)
    }

    /// The one progress card every in-flight state shares: heading by state, the three steps always
    /// visible, the bar row, the detail line, and the state's action trailing at the bottom.
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: MCSpacing.group) {
            if let heading = cardHeading {
                Text(heading)
                    .font(.mcRowTitle)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            stepsList
            barRow
            detailLine
            cardActionRow
        }
        .padding(MCSpacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MCTone.cardFill, in: RoundedRectangle(cornerRadius: MCRadius.card))
    }

    /// The step list's current index: the live install's own step; a paused or failed install sits on the
    /// download step — a pause only interrupts the download, and a failure carries no phase to show.
    private var cardStep: Int {
        switch phase {
        case .downloading(let step, _): step
        case .paused, .failed: 0
        case .gettingReady: 2
        case .unavailable, .unverified, .ready: 0
        }
    }

    private var cardHeading: String? {
        switch phase {
        case .downloading(let step, _):
            switch step {
            case 0: "Downloading the Chat model"
            case 1: "Checking the files"
            default: "Getting Chat ready"
            }
        case .paused: "Download paused"
        case .failed: "Download failed"
        case .gettingReady: "Getting Chat ready"
        case .unavailable, .unverified, .ready: nil
        }
    }

    private var stepsList: some View {
        let current = cardStep
        return VStack(alignment: .leading, spacing: MCSpacing.compact) {
            ForEach(Self.steps.indices, id: \.self) { index in
                HStack(spacing: MCSpacing.regular) {
                    Image(systemName: Self.stepIcon(index, current: current))
                        .foregroundStyle(Self.stepTone(index, current: current))
                        // no token: aligns the step icons' text column; SF Symbols have no shared width.
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(Self.steps[index])
                        .font(.mcSupporting)
                        .foregroundStyle(index <= current ? .primary : .secondary)
                    if index == 0, let agent {
                        Spacer()
                        Text(agent.downloadBytes.formatted(.byteCount(style: .file)))
                            .font(.mcMetadata)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The bar row: determinate with a trailing percent while bytes move or sit paused, indeterminate while
    /// the engine lists the model, and nothing for a failure — there are no bytes to measure.
    @ViewBuilder
    private var barRow: some View {
        switch phase {
        case .downloading(_, let progress):
            barRowView(fraction: progress.fraction)
        case .paused(let bytesOnDisk, let bytesTotal):
            let fraction = bytesTotal > 0 ? Double(bytesOnDisk) / Double(bytesTotal) : 0
            barRowView(fraction: min(1, max(0, fraction)))
        case .gettingReady:
            ProgressView()
        case .failed, .unavailable, .unverified, .ready:
            EmptyView()
        }
    }

    private func barRowView(fraction: Double) -> some View {
        HStack(spacing: MCSpacing.group) {
            ProgressView(value: fraction)
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .font(.mcMetadata)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// The line under the bar: bytes and time left while downloading, where a pause stopped, or the
    /// failure itself. Getting ready needs no line — the heading says it.
    @ViewBuilder
    private var detailLine: some View {
        switch phase {
        case .downloading(_, let progress):
            Text(progressDetail(progress))
                .font(.mcMetadata)
                .foregroundStyle(.secondary)
        case .paused(let bytesOnDisk, let bytesTotal):
            Text(
                "Paused at \(bytesOnDisk.formatted(.byteCount(style: .file))) of \(bytesTotal.formatted(.byteCount(style: .file)))"
            )
            .font(.mcMetadata)
            .foregroundStyle(.secondary)
        case .failed(let message, _):
            MCStatusText(.critical, message)
        case .gettingReady, .unavailable, .unverified, .ready:
            EmptyView()
        }
    }

    /// The install record is in place but the engine has not listed the model. During the installer's own
    /// rescan the active row keeps this hidden; afterwards it is the one recovery action the user has.
    private var canCheckReadyAgain: Bool {
        guard browser.installTask == nil, case .installed(inEngine: false) = row?.state else { return false }
        return true
    }

    /// "341.3 MB of 6.58 GB · About 11 min left", or "Estimating time left…" while the download rate is
    /// unknown. Verifying and moving are not downloads, so they never carry a meaningless estimate.
    private func progressDetail(_ progress: ModelBrowserRow.Progress) -> String {
        let done = progress.bytesDone.formatted(.byteCount(style: .file))
        let total = progress.bytesTotal.formatted(.byteCount(style: .file))
        var line = "\(done) of \(total)"
        if progress.phase == .preflight || progress.phase == .downloading {
            let remaining = agent.flatMap { browser.remainingText(for: $0.id) } ?? "Estimating time left…"
            line += " · \(remaining)"
        }
        return line
    }

    /// The card's bottom-trailing action: Cancel while downloading, Resume on a pause, Retry on a
    /// retryable failure. Getting ready has nothing to press.
    @ViewBuilder
    private var cardActionRow: some View {
        switch phase {
        case .downloading:
            HStack {
                Spacer()
                Button("Cancel") {
                    browser.cancelInstall()
                }
            }
        case .paused:
            HStack {
                Spacer()
                Button("Resume") {
                    Task { await installAgent() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!installActionEnabled)
            }
        case .failed(_, let retryable):
            if retryable {
                HStack {
                    Spacer()
                    Button("Retry") {
                        Task { await installAgent() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!installActionEnabled)
                }
            }
        case .gettingReady:
            if canCheckReadyAgain {
                HStack {
                    Spacer()
                    Button("Check Again") {
                        Task { await model.refreshModels() }
                    }
                }
            }
        case .unavailable, .unverified, .ready:
            EmptyView()
        }
    }

    /// The note under the card: while bytes move it says the app stays usable and a stop is not a loss; once
    /// stopped it says a retryable action continues from the partials.
    private var resumeNote: String? {
        switch phase {
        case .downloading:
            "You can use Canvas and Gallery while this downloads. If you cancel or quit, the download picks up where it stopped."
        case .paused:
            "The download continues from where it stopped. You can use Canvas and Gallery meanwhile."
        case .failed(_, let retryable):
            retryable ? "The download continues from where it stopped. You can use Canvas and Gallery meanwhile." : nil
        case .unavailable, .unverified, .ready, .gettingReady: nil
        }
    }

    private static func stepIcon(_ index: Int, current: Int) -> String {
        if index < current { return "checkmark.circle.fill" }
        if index == current { return "circle.fill" }
        return "circle"
    }

    private static func stepTone(_ index: Int, current: Int) -> Color {
        if index < current { return MCTone.success }
        if index == current { return Color.accentColor }
        return Color.secondary
    }

    /// The license line under the action: name and commercial-use terms from the catalog, the acceptance
    /// sentence, and the full-text link. Visible wherever an action accepts the license — Download, Resume
    /// and Retry alike — and nowhere else.
    @ViewBuilder
    private var licenseContent: some View {
        if showsLicenseLine, let license {
            VStack(spacing: MCSpacing.tight) {
                Text(licenseLine(license))
                    .font(.mcSupporting)
                    .foregroundStyle(.secondary)
                Text("By downloading you accept this license.")
                    .font(.mcSupporting)
                    .foregroundStyle(.secondary)
                if let url = license.content.url {
                    Link("Read the license", destination: url)
                        .font(.mcSupporting)
                }
            }
            .multilineTextAlignment(.center)
        }
    }

    private var showsLicenseLine: Bool {
        switch phase {
        case .ready, .paused: true
        case .failed(_, let retryable): retryable
        case .unavailable, .unverified, .downloading, .gettingReady: false
        }
    }

    /// "Apache License 2.0, version 2.0 · Commercial use allowed" — or "Not for commercial use", from the
    /// catalog's own `commercialUse`, never hard-coded.
    private func licenseLine(_ license: PendingLicense) -> String {
        let title = LicenseSheet.licenseTitle(name: license.content.licenseName, version: license.content.version)
        let use = license.content.commercialUse ? "Commercial use allowed" : "Not for commercial use"
        return "\(title) · \(use)"
    }

    /// A progress step change is announced; reaching Chat is announced as "Chat is ready." from
    /// `ChatModeView.body`. Leaving the live steps clears the memory, so Resume or Retry announces Step 1 again.
    private func announce(step: Int?) {
        guard let step else {
            announcedStep = nil
            return
        }
        guard step != announcedStep else { return }
        announcedStep = step
        AccessibilityNotification.Announcement("Step \(step + 1) of \(Self.steps.count): \(Self.steps[step])")
            .post()
    }
}
