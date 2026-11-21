import AppKit
import SwiftUI

/// Puts the main window's split-view dividers back after Gallery mode (D52). Both modes share one `HSplitView`; when Canvas
/// mode re-inserts the generation panel and the canvas column, the `NSSplitView` shares the gallery's full-window width out
/// unevenly and the gallery comes back wider. This records the pane widths while in Canvas mode and restores them on return,
/// or gives the gallery `defaultTrailingWidth` if the window opened in Gallery mode.
struct SplitPaneWidthKeeper: NSViewRepresentable {
    var galleryOnly: Bool
    var defaultTrailingWidth: CGFloat

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(view: view, galleryOnly: galleryOnly, defaultTrailingWidth: defaultTrailingWidth)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor final class Coordinator {
        private weak var splitView: NSSplitView?
        private var observer: NSObjectProtocol?
        private var galleryOnly: Bool?
        private var isRestoring = false
        private var paneWidths: [CGFloat]?

        func update(view: NSView, galleryOnly: Bool, defaultTrailingWidth: CGFloat) {
            let wasGalleryOnly = self.galleryOnly
            self.galleryOnly = galleryOnly
            if wasGalleryOnly == true && !galleryOnly {
                isRestoring = true
            }
            // At launch the view is not in the window yet, and the split view re-inserts its panes after this update.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.attach(from: view)
                if self.isRestoring { self.restore(defaultTrailingWidth: defaultTrailingWidth) }
            }
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        private func attach(from view: NSView) {
            guard splitView == nil else { return }
            var ancestor = view.superview
            while let candidate = ancestor, !(candidate is NSSplitView) { ancestor = candidate.superview }
            guard let found = ancestor as? NSSplitView else { return }
            splitView = found
            observer = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: found, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.record() }
            }
            record()
        }

        private func record() {
            guard galleryOnly == false, !isRestoring, let splitView, splitView.arrangedSubviews.count > 1 else { return }
            paneWidths = splitView.arrangedSubviews.map(\.frame.width)
        }

        private func restore(defaultTrailingWidth: CGFloat) {
            isRestoring = false
            guard let splitView else { return }
            let panes = splitView.arrangedSubviews
            guard panes.count > 1 else { return }
            let saved = paneWidths?.count == panes.count ? paneWidths : nil
            if let saved {
                var position: CGFloat = 0
                for index in 0..<(panes.count - 2) {
                    position += saved[index]
                    splitView.setPosition(position, ofDividerAt: index)
                    position += splitView.dividerThickness
                }
            }
            let trailingWidth = saved?.last ?? defaultTrailingWidth
            splitView.setPosition(splitView.bounds.width - trailingWidth - splitView.dividerThickness, ofDividerAt: panes.count - 2)
            record()
        }
    }
}
