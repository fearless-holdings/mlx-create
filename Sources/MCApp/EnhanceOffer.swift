import Foundation
import MCCatalog
import MCEnhancer

/// A word an enhancement added to the prompt: the word, and where it sits in the enhanced text, in characters.
struct AddedWord: Equatable {
    let text: String
    let range: Range<Int>
}

/// Finds the words an enhancement added to the prompt (U8, R15). A word is kept when the prompt has it too, wherever it
/// moved and whatever its case. Each kept occurrence cancels one occurrence in the prompt, so a word repeated beyond
/// the prompt's count is marked.
enum EnhanceWordDiff {
    static func added(in enhanced: String, comparedTo original: String) -> [AddedWord] {
        var kept: [String: Int] = [:]
        for word in words(in: original) {
            kept[word.text.lowercased(), default: 0] += 1
        }
        return words(in: enhanced).filter { word in
            let key = word.text.lowercased()
            guard let count = kept[key], count > 0 else { return true }
            kept[key] = count - 1
            return false
        }
    }

    private static func words(in text: String) -> [AddedWord] {
        var words: [AddedWord] = []
        var start: Int?
        var current = ""
        for (offset, character) in text.enumerated() {
            if isWordCharacter(character) {
                if start == nil { start = offset }
                current.append(character)
            } else if let begin = start {
                appendWord(current, range: begin..<offset, to: &words)
                start = nil
                current = ""
            }
        }
        if let begin = start {
            appendWord(current, range: begin..<text.count, to: &words)
        }
        return words
    }

    /// A run of word characters counts only when it holds a letter or a digit, so a lone dash is not a word.
    private static func appendWord(_ text: String, range: Range<Int>, to words: inout [AddedWord]) {
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        words.append(AddedWord(text: text, range: range))
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "-"
    }
}

/// When the prompt enhancer is offered as an optional extra (F2, R16). It is offered while the catalog lists one and it
/// is not installed. There is no persisted dismissal: the offer stays until the enhancer is installed.
enum EnhancerOffer {
    static func isOffered(_ status: EnhancerStatus?) -> Bool {
        status.map { !$0.isInstalled } ?? false
    }
}

/// The one-time note that an Enhance reloads the image model (R14). Shown the first time an Enhance would reload it on
/// this Mac, then remembered in preferences.
enum EnhanceReloadNote {
    static let defaultsKey = "enhanceReloadNoteShown"
    static let text = "Enhance unloads the image model to make room, and the image model reloads when the enhancement finishes."

    static func isDue(willReloadImageModel: Bool, defaults: UserDefaults) -> Bool {
        willReloadImageModel && !defaults.bool(forKey: defaultsKey)
    }

    static func markShown(in defaults: UserDefaults) {
        defaults.set(true, forKey: defaultsKey)
    }
}

/// Why Enhance cannot run on a family, shown as a caption and in the button's hint (U8).
@MainActor
enum EnhanceAvailability {
    /// A probe prompt for the enhancer's own refusal: the enhancer refuses a family with no prompt pack and returns the
    /// reason, and otherwise builds a request, which is discarded here. Nothing is sent.
    private static let probePrompt = "probe"

    /// The reason Enhance cannot run, or nil when it can. A missing selection gives the no-model reason.
    static func blockReason(family: ModelFamily?) -> String? {
        guard let family else { return AppModel.noModelReason }
        if case .unavailable(let reason) = PromptEnhancer.request(
            prompt: probePrompt, family: family, enhancerModelID: probePrompt)
        {
            return reason
        }
        return nil
    }
}

/// The state of the inline enhancer install sheet, read from the catalog's enhancer row (F2, R16).
enum EnhancerInstallPhase: Equatable {
    /// The catalog lists no enhancer.
    case unavailable
    /// Not installed. Install opens the license sheet, or Resume continues a partial install.
    case ready
    /// Downloading. Cancel stops it and keeps the partial files.
    case downloading(ModelBrowserRow.Progress)
    /// The install failed. `retryable` is whether Retry can clear it.
    case failed(message: String, retryable: Bool)
    case installed

    static func phase(for row: ModelBrowserRow?) -> EnhancerInstallPhase {
        guard let row else { return .unavailable }
        switch row.state {
        case .installed:
            return .installed
        case .installing(let progress):
            return .downloading(progress)
        case .failed(let message):
            return .failed(message: message, retryable: row.action == .retry)
        case .available, .interrupted, .missingFiles, .unverified:
            return .ready
        }
    }
}
