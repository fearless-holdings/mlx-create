import SwiftUI

struct GallerySidebarWidth {
    private(set) var composerWidth: CGFloat = 260

    mutating func record(_ width: CGFloat, galleryOnly: Bool) {
        guard !galleryOnly, width.isFinite, width >= 200 else { return }
        composerWidth = width
    }
}

/// Keeps the full-window gallery's size out of the composer's split position (D33, D52).
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
            split.setPosition(split.bounds.width - memory.composerWidth - split.dividerThickness, ofDividerAt: 1)
            pendingRestore = false
        }

        @objc private func resized() {
            guard !pendingRestore, let split, split.arrangedSubviews.count == 3,
                let gallery = split.arrangedSubviews.last
            else { return }
            memory.record(gallery.frame.width, galleryOnly: galleryOnly)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
