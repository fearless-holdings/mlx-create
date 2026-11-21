import Foundation

/// The main window's three view modes (D54, KTD9). Stored as the case's name under `mainWindowMode`; values written by
/// builds that stored a Boolean still read back as the mode they meant.
public enum MainWindowMode: String, Sendable, CaseIterable {
    /// The conversation over the full-width gallery (D54), and the default on first launch.
    case chat
    /// The three-panel generation workspace.
    case canvas
    /// The gallery alone at full width (D52).
    case gallery

    /// The mode a stored value names: a case name, or the legacy `showsGalleryOnly` Boolean (`true` was Gallery). No
    /// stored value — or a string that names no case — is Chat, the first-launch mode (R1).
    static func stored(in defaults: UserDefaults, key: String) -> MainWindowMode {
        guard let object = defaults.object(forKey: key) else { return .chat }
        if let string = object as? String {
            return MainWindowMode(rawValue: string) ?? .chat
        }
        if let number = object as? NSNumber {
            return number.boolValue ? .gallery : .canvas
        }
        return .chat
    }
}
