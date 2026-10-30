import AppKit
import MCLibrary
import SwiftUI

/// The gallery grid (HLD §6, §10): an `NSCollectionView` inside an `NSScrollView`, because SwiftUI lazy grids struggle
/// at 10k+ thumbnails. Items host the SwiftUI `ImageCell`. The model stays the single source of truth; this bridge
/// only keeps a diffable snapshot of the image ids and reconfigures the items whose selection state changed.
struct GalleryCollection: NSViewRepresentable {
    let model: AppModel
    /// Passed by value so SwiftUI re-runs `updateNSView` when the gallery or the selection changes.
    let images: [LibraryImage]
    let selection: Set<UUID>

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(images: images, selection: selection)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate {
        private enum Section { case main }

        /// Loads the next page when an item this close to the end is about to display.
        private static let pagingDistance = 12

        private let model: AppModel
        private weak var scrollView: NSScrollView?
        private weak var collectionView: NSCollectionView?
        private var dataSource: NSCollectionViewDiffableDataSource<Section, UUID>?
        /// Lookup for the item provider, which receives only an id. Rebuilt from the model on every update.
        private var imagesByID: [UUID: LibraryImage] = [:]
        /// The selection the items were last configured with, so changes reconfigure only the affected items.
        private var appliedSelection: Set<UUID> = []

        init(model: AppModel) {
            self.model = model
        }

        func makeScrollView() -> NSScrollView {
            let layout = GalleryLayout()
            layout.minimumInteritemSpacing = GalleryLayout.spacing
            layout.minimumLineSpacing = GalleryLayout.spacing

            let collectionView = GalleryCollectionView(frame: .zero)
            collectionView.collectionViewLayout = layout
            collectionView.register(GalleryCollectionItem.self, forItemWithIdentifier: GalleryCollectionItem.identifier)
            collectionView.isSelectable = false
            collectionView.backgroundColors = [.clear]
            collectionView.autoresizingMask = [.width, .height]
            collectionView.delegate = self

            let scrollView = NSScrollView()
            scrollView.documentView = collectionView
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder

            self.scrollView = scrollView
            self.collectionView = collectionView
            collectionView.onDelete = { [model = self.model] in Task { await model.deleteSelected() } }
            collectionView.onSelectAll = { [model = self.model] in model.selectAllGalleryImages() }
            dataSource = NSCollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
                self?.makeItem(collectionView, indexPath: indexPath, id: id)
            }
            return scrollView
        }

        /// Brings the grid in line with the model. Only the ids that changed are sent to the data source; an item whose
        /// image record or selection state changed is reconfigured, which re-runs the item provider for it.
        func update(images: [LibraryImage], selection: Set<UUID>) {
            guard let dataSource else { return }

            var ids: [UUID] = []
            var newByID: [UUID: LibraryImage] = [:]
            newByID.reserveCapacity(images.count)
            for image in images where newByID[image.id] == nil {
                newByID[image.id] = image
                ids.append(image.id)
            }

            var changed = Set<UUID>()
            for (id, image) in newByID {
                if let old = imagesByID[id], old != image { changed.insert(id) }
            }
            // Only tiles whose selected state flipped are reconfigured, so a click touches the tiles it changed.
            if selection != appliedSelection {
                changed.formUnion(selection.symmetricDifference(appliedSelection))
            }

            let shownIDs = dataSource.snapshot().itemIdentifiers
            let reconfigure = ids.filter { changed.contains($0) }
            imagesByID = newByID
            appliedSelection = selection
            guard ids != shownIDs || !reconfigure.isEmpty else { return }

            var snapshot = NSDiffableDataSourceSnapshot<Section, UUID>()
            snapshot.appendSections([.main])
            snapshot.appendItems(ids, toSection: .main)
            if !reconfigure.isEmpty {
                snapshot.reloadItems(reconfigure)
            }
            applyKeepingScroll(snapshot, dataSource: dataSource)
        }

        private func makeItem(_ collectionView: NSCollectionView, indexPath: IndexPath, id: UUID) -> NSCollectionViewItem? {
            guard let image = imagesByID[id],
                let item = collectionView.makeItem(withIdentifier: GalleryCollectionItem.identifier, for: indexPath)
                    as? GalleryCollectionItem
            else { return nil }
            item.configure(
                ImageCell(
                    model: model,
                    image: image,
                    thumbnailURL: model.thumbnailURL(for: image),
                    isSelected: appliedSelection.contains(id),
                    onSelect: { [weak self] in self?.select(id) },
                    onReusePrompt: { [model = self.model] in model.reusePrompt(of: image) },
                    onReuseSettings: { [model = self.model] in model.reuseSettings(of: image) }),
                onRightClick: { [model = self.model] in model.prepareGalleryMenu(for: id) })
            return item
        }

        /// A click on a tile: ⌘ toggles, ⇧ selects the range, and a plain click selects only that tile (R1). The grid then
        /// takes keyboard focus.
        private func select(_ id: UUID) {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            let click: GalleryClick = flags.contains(.command) ? .toggle : flags.contains(.shift) ? .range : .plain
            model.selectGalleryImage(id, click: click)
            collectionView?.window?.makeFirstResponder(collectionView)
        }

        /// Applies without animation and then restores the scroll position. The data source does not keep the visible
        /// content in place when rows are inserted above it, so a prepended image would push the view down. The anchor
        /// is the top visible item and its offset from the top of the clip view, and it is captured only when scrolled
        /// down: at the top, the newest image should stay in view.
        private func applyKeepingScroll(
            _ snapshot: NSDiffableDataSourceSnapshot<Section, UUID>,
            dataSource: NSCollectionViewDiffableDataSource<Section, UUID>
        ) {
            let anchor = scrollAnchor(dataSource: dataSource)
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                self?.restoreScroll(to: anchor, dataSource: dataSource)
            }
        }

        private func scrollAnchor(
            dataSource: NSCollectionViewDiffableDataSource<Section, UUID>
        ) -> (id: UUID, offset: CGFloat)? {
            guard let scrollView, let collectionView, let layout = collectionView.collectionViewLayout else { return nil }
            let clip = scrollView.contentView
            guard clip.bounds.minY > 0,
                let first = collectionView.indexPathsForVisibleItems().min(),
                let id = dataSource.itemIdentifier(for: first),
                let attributes = layout.layoutAttributesForItem(at: first)
            else { return nil }
            return (id, attributes.frame.minY - clip.bounds.minY)
        }

        private func restoreScroll(
            to anchor: (id: UUID, offset: CGFloat)?,
            dataSource: NSCollectionViewDiffableDataSource<Section, UUID>
        ) {
            guard let anchor, let scrollView, let collectionView, let layout = collectionView.collectionViewLayout,
                let indexPath = dataSource.indexPath(for: anchor.id)
            else { return }
            collectionView.layoutSubtreeIfNeeded()
            guard let attributes = layout.layoutAttributesForItem(at: indexPath) else { return }
            let clip = scrollView.contentView
            let target = NSRect(
                origin: NSPoint(x: clip.bounds.minX, y: attributes.frame.minY - anchor.offset),
                size: clip.bounds.size
            )
            clip.scroll(to: clip.constrainBoundsRect(target).origin)
            scrollView.reflectScrolledClipView(clip)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            willDisplay item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            guard indexPath.item >= imagesByID.count - Self.pagingDistance, model.hasMoreImages else { return }
            // The model ignores a trigger while a page is already loading, so repeated calls here are harmless.
            Task { await model.loadMoreImages() }
        }
    }
}

/// The collection view is the document of an `NSScrollView`, which does not size its document to the layout's content.
/// This keeps the frame at the clip width and at least the content height, so the scroll range matches the grid. It
/// takes keyboard focus when a tile is clicked, so Delete and ⌘A act on the gallery while the prompt field keeps typing
/// to itself (D37).
final class GalleryCollectionView: NSCollectionView {
    var onDelete: (() -> Void)?
    var onSelectAll: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Delete (51) and forward delete (117), with no modifier that would mean another shortcut.
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if plain, event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func selectAll(_ sender: Any?) {
        onSelectAll?()
    }

    override func layout() {
        if let clip = enclosingScrollView?.contentView, let grid = collectionViewLayout as? GalleryLayout {
            // Fit before the layout pass starts. The flow layout reads its item and inset sizes at the start of a pass, so
            // a fit made inside `prepare()` can leave the attributes computed from the previous width. When the vertical
            // scroller then narrows the clip, the next `layout()` fits again to the new width.
            grid.fit(width: clip.bounds.width)
            let content = grid.collectionViewContentSize
            let size = NSSize(width: clip.bounds.width, height: max(content.height, clip.bounds.height))
            if frame.size != size {
                setFrameSize(size)
            }
        }
        super.layout()
    }
}

/// A square-tile flow layout that re-fits the columns to the width. Columns are 100–120 pt, 8 pt apart, and the
/// leftover width is split as side margins, so the grid stays centred as the panel resizes.
final class GalleryLayout: NSCollectionViewFlowLayout {
    static let inset: CGFloat = 12
    static let spacing: CGFloat = 8
    static let minSide: CGFloat = 100
    static let maxSide: CGFloat = 120

    /// Sets the item and section sizes. Each property is written only when it changes, because a write invalidates the
    /// layout and would otherwise repeat forever.
    func fit(width: CGFloat) {
        // A scroll view that is not sized yet has no width, and a zero item size makes AppKit raise.
        guard width > 0 else { return }
        let available = max(0, width - 2 * Self.inset)
        let columns = max(1, Int((available + Self.spacing) / (Self.minSide + Self.spacing)))
        let side = min(Self.maxSide, (available - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let used = side * CGFloat(columns) + Self.spacing * CGFloat(columns - 1)
        let margin = Self.inset + max(0, available - used) / 2

        let size = NSSize(width: side, height: side)
        if itemSize != size {
            itemSize = size
        }
        if sectionInset.left != margin || sectionInset.right != margin || sectionInset.top != Self.inset {
            sectionInset = NSEdgeInsets(top: Self.inset, left: margin, bottom: Self.inset, right: margin)
        }
    }
}

/// The tile's container. A right-click would otherwise land on the hosted SwiftUI view, which would open its context menu
/// before the grid could apply the selection rule (R2). Returning itself from `hitTest` for a right-click lets the tile
/// update the selection first, then hand the click on to the hosted view.
final class GalleryItemView: NSView {
    var onRightClick: (() -> Void)?
    weak var hosted: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil, let event = NSApp.currentEvent else { return hit }
        let isContextClick =
            event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        return isContextClick ? self : hit
    }

    /// A control-click opens the context menu like a right-click, so it applies the selection rule first.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
        hosted?.rightMouseDown(with: event)
    }
}

/// One gallery tile. It hosts the SwiftUI `ImageCell` and is reused, so `configure` replaces the root view each time.
final class GalleryCollectionItem: NSCollectionViewItem {
    static var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("GalleryItem") }

    private var hostingView: NSHostingView<ImageCell>?
    private var itemView: GalleryItemView? { view as? GalleryItemView }

    override func loadView() {
        view = GalleryItemView()
    }

    func configure(_ cell: ImageCell, onRightClick: @escaping () -> Void) {
        itemView?.onRightClick = onRightClick
        if let hostingView {
            hostingView.rootView = cell
            return
        }
        let hosting = NSHostingView(rootView: cell)
        // The item's frame decides the size; the hosted view must not push its intrinsic size back into the layout.
        hosting.sizingOptions = []
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        view.addSubview(hosting)
        itemView?.hosted = hosting
        hostingView = hosting
    }
}
