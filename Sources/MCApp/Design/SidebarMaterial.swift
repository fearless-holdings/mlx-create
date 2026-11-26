import AppKit
import SwiftUI

/// A sidebar-material backdrop (N2-3): an `NSVisualEffectView`, because only it paints the window-chromatic
/// `.sidebar` material behind the composer and the canvas-mode gallery column.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
