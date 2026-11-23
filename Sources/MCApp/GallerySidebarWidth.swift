import SwiftUI

struct GallerySidebarWidth {
    private(set) var composerWidth: CGFloat = 260
    private(set) var generationPanelWidth: CGFloat?

    mutating func record(_ width: CGFloat, galleryOnly: Bool) {
        guard !galleryOnly, width.isFinite, width >= 200 else { return }
        composerWidth = width
    }

    mutating func recordGenerationPanel(_ width: CGFloat, galleryOnly: Bool) {
        guard !galleryOnly, width.isFinite, width >= 320 else { return }
        generationPanelWidth = width
    }
}

/// Keeps the full-window gallery's size out of the composer's split positions (D33, D52): on return to Canvas mode the
/// generation panel and the gallery get back the widths they had there.
struct GallerySidebarSizing: NSViewRepresentable {
    var galleryOnly: Bool

    func makeNSView(context: Context) -> SizingView { SizingView() }

    func updateNSView(_ view: SizingView, context: Context) {
        view.setMode(galleryOnly)
    }

    final class SizingView: NSView {
        private var memory = GallerySidebarWidth()
        private var galleryOnly = true
        private var pendingRestore = false
        private weak var split: NSSplitView?

        func setMode(_ value: Bool) {
            if galleryOnly != value {
                pendingRestore = !value
                galleryOnly = value
            }
            DispatchQueue.main.async { [weak self] in self?.connectAndRestore() }
        }

        private func connectAndRestore() {
            var ancestor = superview
            while let view = ancestor, !(view is NSSplitView) { ancestor = view.superview }
            guard let split = ancestor as? NSSplitView else { return }
            if self.split !== split {
                NotificationCenter.default.removeObserver(self)
                self.split = split
                NotificationCenter.default.addObserver(
                    self, selector: #selector(resized), name: NSSplitView.didResizeSubviewsNotification, object: split)
            }
            guard pendingRestore, !galleryOnly, split.arrangedSubviews.count == 3 else { return }
            split.layoutSubtreeIfNeeded()
            if let panelWidth = memory.generationPanelWidth {
                split.setPosition(panelWidth, ofDividerAt: 0)
            }
            split.setPosition(split.bounds.width - memory.composerWidth - split.dividerThickness, ofDividerAt: 1)
            pendingRestore = false
        }

        @objc private func resized() {
            guard !pendingRestore, let split, split.arrangedSubviews.count == 3,
                let panel = split.arrangedSubviews.first, let gallery = split.arrangedSubviews.last
            else { return }
            memory.recordGenerationPanel(panel.frame.width, galleryOnly: galleryOnly)
            memory.record(gallery.frame.width, galleryOnly: galleryOnly)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
