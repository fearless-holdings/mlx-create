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
    let fullWindow: Bool
    /// Placeholder tiles before the images; only Chat mode passes any (KTD10).
    let pending: [PendingTile]
    /// Scrollable room under the last row — the folded chat container's height (R3).
    let bottomInset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            images: images, selection: selection, fullWindow: fullWindow, pending: pending,
            bottomInset: bottomInset)
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
        /// The placeholder tiles by their derived id, rebuilt on every update; Chat mode only (KTD10).
        private var pendingByID: [UUID: PendingTile] = [:]
        /// The selection the items were last configured with, so changes reconfigure only the affected items.
        private var appliedSelection: Set<UUID> = []
        private var isFullWindow = false

        /// Gallery mode opens with the grid focused, so Return and the arrow keys work before the first click. The view may not
        /// be in a window yet when the mode is restored at launch, so the focus move waits for the next run-loop turn.
        private func focusGridOnceInWindow() {
            DispatchQueue.main.async { [weak self] in
                guard let collectionView = self?.collectionView else { return }
                collectionView.window?.makeFirstResponder(collectionView)
            }
        }

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
            collectionView.register(PendingCollectionItem.self, forItemWithIdentifier: PendingCollectionItem.identifier)
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
            // The bottom inset comes from the chat container's height; nothing else adjusts it.
            scrollView.automaticallyAdjustsContentInsets = false

            self.scrollView = scrollView
            self.collectionView = collectionView
            collectionView.onDelete = { [model = self.model] in Task { await model.deleteSelected() } }
            collectionView.onSelectAll = { [model = self.model] in model.selectAllGalleryImages() }
            collectionView.onMove = { [weak self] offset in self?.moveSelection(by: offset) }
            collectionView.onOpen = { [model = self.model] in
                guard let id = model.galleryArrowOrigin else { return }
                if model.windowMode == .chat {
                    // Return in Chat mode opens the highlighted tile large; in Gallery mode it opens in Canvas.
                    model.selectGalleryImage(id, click: .plain)
                    model.chat.largeImageID = id
                } else {
                    model.openInCanvas(id)
                }
            }
            dataSource = NSCollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
                self?.makeItem(collectionView, indexPath: indexPath, id: id)
            }
            return scrollView
        }

        /// Brings the grid in line with the model. Only the ids that changed are sent to the data source; an item whose
        /// image record or selection state changed is reconfigured, which re-runs the item provider for it.
        func update(
            images: [LibraryImage], selection: Set<UUID>, fullWindow: Bool, pending: [PendingTile],
            bottomInset: CGFloat
        ) {
            guard let dataSource else { return }
            scrollView?.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
            if fullWindow != isFullWindow {
                isFullWindow = fullWindow
                if fullWindow { focusGridOnceInWindow() }
            }
            if let layout = collectionView?.collectionViewLayout as? GalleryLayout {
                let sides = fullWindow ? GalleryLayout.fullWindowSides : GalleryLayout.panelSides
                layout.minSide = sides.min
                layout.maxSide = sides.max
            }

            // Pending tiles are the first items: placeholders where the batch's images will land (R6).
            var ids: [UUID] = []
            var newPendingByID: [UUID: PendingTile] = [:]
            newPendingByID.reserveCapacity(pending.count)
            for tile in pending where newPendingByID[tile.id] == nil {
                newPendingByID[tile.id] = tile
                ids.append(tile.id)
            }
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
            pendingByID = newPendingByID
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
            if let tile = pendingByID[id] {
                let item =
                    collectionView.makeItem(
                        withIdentifier: PendingCollectionItem.identifier, for: indexPath)
                    as? PendingCollectionItem
                item?.configure(PendingTileCell(tile: tile))
                return item
            }
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
            // A plain click in Chat mode opens the tile large (R4); ⌘ and ⇧ keep their selection behaviour.
            if click == .plain, model.windowMode == .chat {
                model.chat.largeImageID = id
            }
            collectionView?.window?.makeFirstResponder(collectionView)
        }

        /// An arrow key: a plain click on the neighbour `offset` places away from the highlighted tile, scrolled into
        /// view, so the canvas shows it too. The ends clamp, so nothing wraps, and with nothing selected the first image
        /// is picked.
        private func moveSelection(by offset: Int) {
            let ids = model.galleryImages.map(\.id)
            guard let target = GalleryNavigation.move(from: model.galleryArrowOrigin, in: ids, by: offset) else { return }
            model.selectGalleryImage(target, click: .plain)
            if let indexPath = dataSource?.indexPath(for: target) {
                collectionView?.scrollToItems(at: [indexPath], scrollPosition: .nearestVerticalEdge)
            }
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
    /// An arrow key's move in the grid: -1 is the previous image, +1 the next, and a full row is the column count.
    var onMove: ((Int) -> Void)?
    var onOpen: (() -> Void)?

    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Delete, the arrow keys and the shortcuts each need no modifier that would mean another command. A shifted arrow
        // is left to the system: it does not mean "select the neighbour", and a ⇧-range must not collapse to one tile.
        let flags = event.modifierFlags
        let plain = flags.intersection([.command, .option, .control]).isEmpty
        if plain {
            let row = (collectionViewLayout as? GalleryLayout)?.columns ?? 1
            switch event.keyCode {
            case KeyCode.returnKey, KeyCode.keypadEnter:
                onOpen?()
                return
            case KeyCode.delete, KeyCode.forwardDelete:
                onDelete?()
                return
            // ← → ↑ ↓ move one image, like a plain click on it. The ends clamp, so nothing wraps.
            case KeyCode.left where !flags.contains(.shift):
                onMove?(-1)
                return
            case KeyCode.right where !flags.contains(.shift):
                onMove?(1)
                return
            case KeyCode.down where !flags.contains(.shift):
                onMove?(row)
                return
            case KeyCode.up where !flags.contains(.shift):
                onMove?(-row)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
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

final class GalleryLayout: NSCollectionViewFlowLayout {
    static let inset: CGFloat = MCSpacing.group
    static let spacing: CGFloat = MCSpacing.regular
    static let panelSides = (min: CGFloat(100), max: CGFloat(120))
    static let fullWindowSides = (min: CGFloat(160), max: CGFloat(200))
    var minSide: CGFloat = GalleryLayout.panelSides.min { didSet { if minSide != oldValue { invalidateLayout() } } }
    var maxSide: CGFloat = GalleryLayout.panelSides.max { didSet { if maxSide != oldValue { invalidateLayout() } } }

    /// The columns the last fit chose, so an up or down arrow can move by one row.
    private(set) var columns = 1

    /// Sets the item and section sizes. Each property is written only when it changes, because a write invalidates the
    /// layout and would otherwise repeat forever.
    func fit(width: CGFloat) {
        // A scroll view that is not sized yet has no width, and a zero item size makes AppKit raise.
        guard width > 0 else { return }
        let available = max(0, width - 2 * Self.inset)
        let fitted = max(1, Int((available + Self.spacing) / (minSide + Self.spacing)))
        let side = min(maxSide, (available - Self.spacing * CGFloat(fitted - 1)) / CGFloat(fitted))
        let used = side * CGFloat(fitted) + Self.spacing * CGFloat(fitted - 1)
        let margin = Self.inset + max(0, available - used) / 2

        if columns != fitted {
            columns = fitted
        }
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

/// One placeholder tile (KTD10): it hosts `PendingTileCell`, is never selectable, and answers no click or menu.
final class PendingCollectionItem: NSCollectionViewItem {
    static var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("PendingTileItem") }

    private var hostingView: NSHostingView<PendingTileCell>?

    override func loadView() {
        view = NSView()
    }

    func configure(_ cell: PendingTileCell) {
        if let hostingView {
            hostingView.rootView = cell
            return
        }
        let hosting = NSHostingView(rootView: cell)
        hosting.sizingOptions = []
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        view.addSubview(hosting)
        hostingView = hosting
    }
}
