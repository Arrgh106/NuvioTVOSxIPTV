import SwiftUI
import UIKit

/// The guide (LIVE_TV_DESIGN.md, step 1): a time ruler over one row per
/// channel of the selected group. Up/Down move through channels (focus
/// engine, cell reuse: 50k channels cost the same as 10). Right/Left move a
/// time cursor through the row's programmes, the window follows in half hour
/// steps; Left on what's on now goes to the groups. OK plays the channel.
struct LiveTVGuideGrid: UIViewRepresentable {
    /// Changes whenever a different list is shown, so the guide reloads and
    /// scrolls back to the top.
    let listID: String
    let channels: [XtreamLiveChannel]
    var favoriteIDs: Set<Int> = []
    /// The channel watched last: focused (and scrolled to) when the guide
    /// comes back from the player, instead of focus landing on the groups.
    var focusChannelID: Int?
    let onSelect: (XtreamLiveChannel) -> Void
    var onToggleFavorite: (XtreamLiveChannel) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> LiveTVGuideGridView {
        let view = LiveTVGuideGridView()
        context.coordinator.attach(to: view)
        context.coordinator.pendingFocusID = focusChannelID
        context.coordinator.update(listID: listID, channels: channels, onSelect: onSelect)
        context.coordinator.updateFavorites(favoriteIDs, onToggle: onToggleFavorite)
        return view
    }

    func updateUIView(_ view: LiveTVGuideGridView, context: Context) {
        context.coordinator.update(listID: listID, channels: channels, onSelect: onSelect)
        context.coordinator.updateFavorites(favoriteIDs, onToggle: onToggleFavorite)
    }

    static func dismantleUIView(_ view: LiveTVGuideGridView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        private weak var view: LiveTVGuideGridView?
        private var listID: String?
        private var channels: [XtreamLiveChannel] = []
        private var onSelect: (XtreamLiveChannel) -> Void = { _ in }
        private var favoriteIDs: Set<Int> = []
        private var onToggleFavorite: (XtreamLiveChannel) -> Void = { _ in }
        private var timeline = LiveTVTimeline(now: Date())
        private var clock: Timer?
        private var rowsObserver: NSObjectProtocol?
        /// Channel to focus once it is in the list (see `focusChannelID`).
        var pendingFocusID: Int?
        private var preferredIndexPath: IndexPath?

        func attach(to view: LiveTVGuideGridView) {
            self.view = view
            let collection = view.collectionView
            collection.dataSource = self
            collection.delegate = self
            // Right: a swipe or a click on the right edge. Nothing is to the
            // right of the guide, so the focus engine never sees these.
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(moveRight))
            swipe.direction = .right
            collection.addGestureRecognizer(swipe)
            let press = UITapGestureRecognizer(target: self, action: #selector(moveRight))
            press.allowedPressTypes = [NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
            collection.addGestureRecognizer(press)

            view.ruler.update(timeline: timeline, now: Date())
            // The clock: the now line moves, and on now the window follows.
            clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            rowsObserver = NotificationCenter.default.addObserver(
                forName: LiveTVGuideRows.changedNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadVisibleProgrammes() }
            }
        }

        func detach() {
            clock?.invalidate()
            clock = nil
            if let rowsObserver { NotificationCenter.default.removeObserver(rowsObserver) }
            rowsObserver = nil
        }

        func update(listID: String, channels: [XtreamLiveChannel], onSelect: @escaping (XtreamLiveChannel) -> Void) {
            self.onSelect = onSelect
            guard let collection = view?.collectionView else { return }
            guard listID != self.listID || channels.count != self.channels.count else { return }
            let isNewList = listID != self.listID
            self.listID = listID
            self.channels = channels
            if isNewList { timeline.resetToNow(Date()); refreshAll() }
            collection.reloadData()
            if isNewList, !channels.isEmpty {
                collection.setContentOffset(CGPoint(x: 0, y: -collection.contentInset.top), animated: false)
            }
            focusPendingChannel()
        }

        /// Scrolls to the last watched channel and moves focus onto it.
        private func focusPendingChannel() {
            guard let id = pendingFocusID, let view,
                  let index = channels.firstIndex(where: { $0.streamID == id }) else { return }
            pendingFocusID = nil
            let indexPath = IndexPath(item: index, section: 0)
            preferredIndexPath = indexPath
            let collection = view.collectionView
            collection.layoutIfNeeded()
            collection.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            // After SwiftUI has placed its initial focus (on the groups).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak collection] in
                guard let collection, collection.window != nil,
                      let system = UIFocusSystem.focusSystem(for: collection) else { return }
                system.requestFocusUpdate(to: collection)
                system.updateFocusIfNeeded()
            }
        }

        func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
            preferredIndexPath
        }

        func updateFavorites(_ ids: Set<Int>, onToggle: @escaping (XtreamLiveChannel) -> Void) {
            onToggleFavorite = onToggle
            guard ids != favoriteIDs else { return }
            favoriteIDs = ids
            for cell in visibleRows {
                cell.setFavorite(cell.channel.map { ids.contains($0.streamID) } ?? false)
            }
        }

        // MARK: Time cursor

        private var visibleRows: [LiveTVGuideRowCell] {
            view?.collectionView.visibleCells.compactMap { $0 as? LiveTVGuideRowCell } ?? []
        }

        private var focusedRow: LiveTVGuideRowCell? {
            visibleRows.first { $0.isFocused }
        }

        @objc private func moveRight() {
            guard let cell = focusedRow else { return }
            let now = Date()
            let limit = now.addingTimeInterval(LiveTVGuide.futureWindow)
            let before = timeline
            timeline.moveRight(in: cell.strip.programmes ?? [], now: now, limit: limit)
            if timeline != before { refreshAll(now: now) }
        }

        /// Left inside the grid; false when focus should leave (to the groups).
        private func moveLeft() -> Bool {
            guard let cell = focusedRow else { return false }
            let now = Date()
            let before = timeline
            let moved = timeline.moveLeft(in: cell.strip.programmes ?? [], now: now)
            if timeline != before { refreshAll(now: now) }
            return moved
        }

        private func tick() {
            let now = Date()
            timeline.tick(now: now)
            refreshAll(now: now)
        }

        /// Window, now line and cursor on every visible row and the ruler.
        private func refreshAll(now: Date = Date()) {
            view?.ruler.update(timeline: timeline, now: now)
            for cell in visibleRows {
                cell.strip.update(timeline: timeline, now: now)
                cell.strip.cursor = cell.isFocused ? timeline.cursorTime(now: now) : nil
            }
        }

        private func reloadVisibleProgrammes() {
            for cell in visibleRows { cell.reloadProgrammes() }
        }

        // MARK: Data source

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            channels.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: LiveTVGuideRowCell.reuseID, for: indexPath) as! LiveTVGuideRowCell
            if indexPath.item < channels.count {
                let channel = channels[indexPath.item]
                cell.configure(with: channel, favorite: favoriteIDs.contains(channel.streamID), timeline: timeline, now: Date())
            }
            return cell
        }

        // MARK: Focus

        func collectionView(_ collectionView: UICollectionView, shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
            // Left from a row: back through time first; on now, out to the groups.
            if context.focusHeading.contains(.left), context.previouslyFocusedIndexPath != nil,
               context.previouslyFocusedItem is LiveTVGuideRowCell {
                return !moveLeft()
            }
            return true
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {
            let now = Date()
            (context.previouslyFocusedItem as? LiveTVGuideRowCell)?.strip.cursor = nil
            if let cell = context.nextFocusedItem as? LiveTVGuideRowCell {
                // Landed (on the last watched channel or elsewhere): from now
                // on the collection view remembers the focused row itself.
                preferredIndexPath = nil
                // Entering the guide from the groups starts on what's on now.
                if context.previouslyFocusedIndexPath == nil {
                    timeline.resetToNow(now)
                    refreshAll(now: now)
                }
                cell.strip.cursor = timeline.cursorTime(now: now)
            }
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard indexPath.item < channels.count else { return }
            onSelect(channels[indexPath.item])
        }

        func collectionView(
            _ collectionView: UICollectionView,
            contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
            point: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let indexPath = indexPaths.first, indexPath.item < channels.count else { return nil }
            let channel = channels[indexPath.item]
            let isFavorite = favoriteIDs.contains(channel.streamID)
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                let title = isFavorite
                    ? L10n.string("livetv_remove_favorite", fallback: "Remove from Favorites")
                    : L10n.string("livetv_add_favorite", fallback: "Add to Favorites")
                let action = UIAction(title: title, image: UIImage(systemName: isFavorite ? "star.slash" : "star")) { _ in
                    self?.onToggleFavorite(channel)
                }
                return UIMenu(title: channel.name, children: [action])
            }
        }
    }
}

// MARK: - Container

/// Time ruler on top, channel rows below.
final class LiveTVGuideGridView: UIView {
    let ruler = LiveTVTimeRuler()
    let collectionView: UICollectionView

    override init(frame: CGRect) {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.layout())
        super.init(frame: frame)
        collectionView.backgroundColor = .clear
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.clipsToBounds = true
        collectionView.register(LiveTVGuideRowCell.self, forCellWithReuseIdentifier: LiveTVGuideRowCell.reuseID)
        collectionView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 40, right: 0)

        for view in [ruler, collectionView] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            ruler.leadingAnchor.constraint(equalTo: leadingAnchor),
            ruler.trailingAnchor.constraint(equalTo: trailingAnchor),
            ruler.topAnchor.constraint(equalTo: topAnchor),
            ruler.heightAnchor.constraint(equalToConstant: LiveTVTimeRuler.height),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: ruler.bottomAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func layout() -> UICollectionViewLayout {
        let size = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1), heightDimension: .absolute(LiveTVGuideRowCell.height))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        // Rows touch (their tiles are inset), so the now line runs through.
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 0
        return UICollectionViewCompositionalLayout(section: section)
    }
}

// MARK: - Time ruler

/// "Today 21:34" over the channels, half hour marks over the programmes and
/// the now marker; drawn, not laid out.
final class LiveTVTimeRuler: UIView {
    static let height: CGFloat = 48

    private var timeline = LiveTVTimeline(now: Date())
    private var now = Date()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(timeline: LiveTVTimeline, now: Date) {
        guard timeline != self.timeline || abs(now.timeIntervalSince(self.now)) >= 1 else { return }
        self.timeline = timeline
        self.now = now
        setNeedsDisplay()
    }

    private static let slotFont = UIFont.monospacedDigitSystemFont(ofSize: LiveTVTheme.Font.small, weight: .semibold)
    private static let dayFont = UIFont.systemFont(ofSize: LiveTVTheme.Font.small, weight: .semibold)
    private static let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let stripX = LiveTVGuideRowCell.channelWidth
        let stripWidth = bounds.width - stripX
        guard stripWidth > 0 else { return }

        // Day and clock over the channel column.
        let calendar = Calendar.current
        let day: String
        if calendar.isDate(timeline.windowStart, inSameDayAs: now) {
            day = L10n.string("livetv_today", fallback: "Today")
        } else {
            day = timeline.windowStart.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        let label = "\(day)  ·  \(now.formatted(Self.timeStyle))" as NSString
        label.draw(at: CGPoint(x: 10, y: 10), withAttributes: [
            .font: Self.dayFont, .foregroundColor: UIColor.white.withAlphaComponent(0.85),
        ])

        // Half hour marks.
        let slots = Int(LiveTVTimeline.window / LiveTVTimeline.slot)
        for index in 0..<slots {
            let time = timeline.windowStart.addingTimeInterval(Double(index) * LiveTVTimeline.slot)
            let x = stripX + CGFloat(Double(index) / Double(slots)) * stripWidth
            UIColor.white.withAlphaComponent(0.18).setFill()
            context.fill(CGRect(x: x, y: bounds.height - 14, width: 1, height: 14))
            (time.formatted(Self.timeStyle) as NSString).draw(at: CGPoint(x: x + 8, y: 10), withAttributes: [
                .font: Self.slotFont, .foregroundColor: UIColor.white.withAlphaComponent(0.6),
            ])
        }

        // Now marker: a dot on the ruler where the line starts.
        let fraction = timeline.fraction(of: now)
        if fraction >= 0, fraction <= 1 {
            let x = stripX + CGFloat(fraction) * stripWidth
            LiveTVTheme.markUIColor.setFill()
            context.fillEllipse(in: CGRect(x: x - 5, y: bounds.height - 10, width: 10, height: 10))
            context.fill(CGRect(x: x - 1, y: bounds.height - 5, width: 2, height: 5))
        }
    }
}
