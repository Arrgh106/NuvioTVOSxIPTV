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
    /// Told what's in focus, for the info panel.
    var info: LiveTVInfoModel?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> LiveTVGuideGridView {
        let view = LiveTVGuideGridView()
        context.coordinator.attach(to: view)
        context.coordinator.infoModel = info
        context.coordinator.pendingFocusID = focusChannelID
        context.coordinator.update(listID: listID, channels: channels, onSelect: onSelect)
        context.coordinator.updateFavorites(favoriteIDs, onToggle: onToggleFavorite)
        return view
    }

    func updateUIView(_ view: LiveTVGuideGridView, context: Context) {
        context.coordinator.infoModel = info
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
        private var clockObserver: NSObjectProtocol?
        /// Channel to focus once it is in the list (see `focusChannelID`).
        var pendingFocusID: Int?
        weak var infoModel: LiveTVInfoModel?

        /// The focused row's channel and the block under the cursor (what's
        /// on now when the cursor is on the channel) for the info panel.
        private func publishInfo(now: Date = Date()) {
            guard let infoModel, let cell = focusedCell, let channel = cell.channel else { return }
            var info: LiveTVProgrammeInfo?
            if let programmes = cell.strip.programmes {
                let time = onChannel ? now : timeline.cursorTime(now: now)
                let block = LiveTVTimeline.block(at: time, in: programmes)
                info = LiveTVProgrammeInfo(
                    start: block.start, end: block.end,
                    title: block.programme?.title, description: block.programme?.description)
            }
            infoModel.show(.init(channel: channel, info: info))
        }
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
            // Left, the same way: handled here, never by the focus engine
            // (which opened the app's sidebar from inside the guide).
            let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleLeft))
            swipeLeft.direction = .left
            collection.addGestureRecognizer(swipeLeft)
            let pressLeft = UITapGestureRecognizer(target: self, action: #selector(handleLeft))
            pressLeft.allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue)]
            collection.addGestureRecognizer(pressLeft)
            // Tells one swipe from the next (a fast swipe keeps moving focus
            // after the swipe itself was handled).
            LiveTVFocusLinks.trackTouches(on: collection)
            let gate = view.leftTrap
            gate.name = "guide"
            gate.stay = { [weak self] in self?.focusedCell }
            gate.onward = { [LiveTVFocusLinks.groups].compactMap { $0 } }
            gate.canOpen = { [weak self] in self?.onChannel ?? false }
            LiveTVFocusLinks.guideGate = gate
            LiveTVFocusLinks.prepareGuideReturn = { [weak self] in
                guard let self, let collection = self.view?.collectionView else { return }
                // Otherwise the row started from wins over the one zapped to.
                collection.remembersLastFocusedIndexPath = false
                self.landOnChannel = true
                self.returnPending = true
                self.returnOffset = collection.contentOffset
            }
            LiveTVFocusLinks.guideWillReturn = { [weak self] in
                self?.scrollToReturnChannel()
            }

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
            clockObserver = NotificationCenter.default.addObserver(
                forName: LiveTVSettings.clockChangedNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.view?.ruler.setNeedsDisplay()
                    self?.reloadVisibleProgrammes()
                }
            }
        }

        func detach() {
            clock?.invalidate()
            clock = nil
            if let rowsObserver { NotificationCenter.default.removeObserver(rowsObserver) }
            rowsObserver = nil
            if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
            clockObserver = nil
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
            // SwiftUI gives the guide the first focus (prefersDefaultFocus in
            // LiveTVView); the collection then picks this row. It lands on the
            // channel itself, as it was left.
            landOnChannel = true
        }

        /// Next focus into the guide lands on the channel, not the programme.
        private var landOnChannel = false

        /// From going full screen until a row has focus again: coming back
        /// lands on the channel playing (on its own, not tied to the header
        /// and groups lock, which can end earlier).
        private var returnPending = false

        /// The channel playing last (after zapping that's not the one
        /// started here), in this list.
        private var returnIndexPath: IndexPath? {
            guard let id = LiveTVZapper.shared.currentChannel?.streamID,
                  let index = channels.firstIndex(where: { $0.streamID == id }) else { return nil }
            return IndexPath(item: index, section: 0)
        }

        /// Leaving full screen: the row is on screen before focus comes back.
        private func scrollToReturnChannel() {
            guard let collection = view?.collectionView else { return }
            guard returnPending, let indexPath = returnIndexPath else { return }
            preferredIndexPath = indexPath
            // Never stuck with one focusable row if focus lands elsewhere.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.returnPending else { return }
                self.returnPending = false
            }
            // The guide was scrolled while hidden: back where it was, so the
            // channel is where it was left.
            if let returnOffset, returnOffset != collection.contentOffset {
                collection.setContentOffset(returnOffset, animated: false)
            }
            collection.layoutIfNeeded()
            if !collection.indexPathsForVisibleItems.contains(indexPath) {
                collection.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
                collection.layoutIfNeeded()
            }
        }

        /// The guide's scroll position going full screen.
        private var returnOffset: CGPoint?

        /// Coming back from full screen only the channel playing can take
        /// focus: tvOS doesn't ask the guide where to land, it takes the row
        /// at the same place on screen.
        func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
            guard returnPending, let target = returnIndexPath else { return true }
            return indexPath == target
        }

        func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
            if returnPending || LiveTVFocusLinks.returningFromPlayer, let indexPath = returnIndexPath {
                if !collectionView.indexPathsForVisibleItems.contains(indexPath) {
                    collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
                }
                return indexPath
            }
            return preferredIndexPath
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
            if onChannel {
                // From the channel onto what's on now.
                setOnChannel(false)
                timeline.resetToNow(now)
                refreshAll(now: now)
                return
            }
            let limit = now.addingTimeInterval(LiveTVGuide.futureWindow)
            let before = timeline
            timeline.moveRight(in: cell.strip.programmes ?? [], now: now, limit: limit)
            if timeline != before { refreshAll(now: now) }
        }

        /// Left: back through time; on what's on now onto the channel; from
        /// the channel the focus engine itself moves on to the groups.
        @objc private func handleLeft() {
            // On the channel the focus guide on the left takes Left; a press
            // it held back restarts the pause.
            if onChannel {
                view?.leftTrap.holdIfClosed()
                return
            }
            guard let cell = focusedRow else { return }
            let now = Date()
            let before = timeline
            let moved = timeline.moveLeft(in: cell.strip.programmes ?? [], now: now)
            if !moved {
                setOnChannel(true)
                // From the channel the groups are the next step.
                LiveTVFocusLinks.endReturn("left on now")
            }
            if timeline != before || !moved { refreshAll(now: now) }
        }

        /// The cursor sits on the channel (number, logo, name) instead of a
        /// programme, like Android's channel column: one more Left reaches
        /// the groups. Ups and downs keep it there.
        private var onChannel = false
        /// The focused row, where the focus guide on the left leads back to.
        private weak var focusedCell: LiveTVGuideRowCell?

        private func setOnChannel(_ value: Bool) {
            onChannel = value
            // On the channel the way to the groups opens after a pause.
            if value { view?.leftTrap.hold() } else { view?.leftTrap.close() }
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
                cell.strip.cursor = cell.isFocused && !onChannel ? timeline.cursorTime(now: now) : nil
                cell.setChannelHighlighted(cell.isFocused && onChannel)
            }
            publishInfo(now: now)
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
                // Programmes arriving for the focused row update the panel.
                cell.onProgrammesLoaded = { [weak self, weak cell] in
                    guard let self, let cell, cell === self.focusedCell else { return }
                    self.publishInfo()
                }
            }
            return cell
        }

        // MARK: Focus

        func collectionView(_ collectionView: UICollectionView, shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
            // Focus leaves a row to the left only from the channel, and not
            // with the press or swipe that just put the cursor there.
            // Left out of the guide is decided by its focus guide (LiveTVLeftGate);
            // refusing here would make tvOS open the sidebar.
            return true
        }

        func collectionView(
            _ collectionView: UICollectionView,
            didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {
            let now = Date()
            if let previous = context.previouslyFocusedItem as? LiveTVGuideRowCell {
                previous.strip.cursor = nil
                previous.setChannelHighlighted(false)
            }
            if let cell = context.nextFocusedItem as? LiveTVGuideRowCell {
                focusedCell = cell
                view?.leftTrap.refresh()
                // Landed (on the last watched channel or elsewhere): from now
                // on the collection view remembers the focused row itself.
                preferredIndexPath = nil
                returnPending = false
                collectionView.remembersLastFocusedIndexPath = true
                if context.previouslyFocusedItem is LiveTVGuideRowCell {
                    LiveTVFocusLinks.endReturn("moved in guide")
                } else if LiveTVFocusLinks.returningFromPlayer {
                    // Stays set a moment: SwiftUI may still move focus on.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        LiveTVFocusLinks.endReturn("guide held 1.5 s")
                    }
                }
                if context.previouslyFocusedIndexPath == nil {
                    // Entering the guide (from the groups, the header or the
                    // player): on the channel, as on Android.
                    timeline.resetToNow(now)
                    setOnChannel(true)
                    landOnChannel = false
                    refreshAll(now: now)
                }
                cell.strip.cursor = onChannel ? nil : timeline.cursorTime(now: now)
                cell.setChannelHighlighted(onChannel)
                publishInfo(now: now)
            } else if context.previouslyFocusedItem is LiveTVGuideRowCell {
                // Left the guide (to the groups or the header).
                focusedCell = nil
                setOnChannel(false)
            }
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard indexPath.item < channels.count else { return }
            // Back from the player focus comes back here, on the channel.
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
    let leftTrap = LiveTVLeftGate()

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
        // Left of the rows, so a move to the left finds this before the
        // groups or the sidebar; it leads back into the guide (the row that
        // is focused), so the focus engine never takes focus out on Left.
        addLayoutGuide(leftTrap)
        NSLayoutConstraint.activate([
            leftTrap.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftTrap.widthAnchor.constraint(equalToConstant: 8),
            leftTrap.topAnchor.constraint(equalTo: collectionView.topAnchor),
            leftTrap.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor),
            ruler.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            ruler.trailingAnchor.constraint(equalTo: trailingAnchor),
            ruler.topAnchor.constraint(equalTo: topAnchor),
            ruler.heightAnchor.constraint(equalToConstant: LiveTVTimeRuler.height),
            collectionView.leadingAnchor.constraint(equalTo: leftTrap.trailingAnchor, constant: 4),
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
        let label = "\(day)  ·  \(LiveTVSettings.shared.time(now))" as NSString
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
            (LiveTVSettings.shared.time(time) as NSString).draw(at: CGPoint(x: x + 8, y: 10), withAttributes: [
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

// MARK: - Focus links

/// Views the guide moves focus to on its own (Left on now → groups).
@MainActor
enum LiveTVFocusLinks {
    static weak var groups: UICollectionView?

    /// From playing a channel until the guide has focus again: the groups
    /// can't take focus, so coming back from the player lands in the guide
    /// (tvOS would pick the groups, the first thing on the left).
    static var returningFromPlayer: Bool {
        get { LiveTVReturnLock.shared.locked }
        set { if LiveTVReturnLock.shared.locked != newValue { LiveTVReturnLock.shared.locked = newValue } }
    }

    static weak var guideGate: LiveTVLeftGate?
    static weak var groupGate: LiveTVLeftGate?

    /// Set by the guide: readies it for focus coming back from full screen.
    static var prepareGuideReturn: (() -> Void)?
    /// Set by the guide: full screen is ending, scroll to the channel.
    static var guideWillReturn: (() -> Void)?

    /// Going full screen: coming back, focus lands in the guide on the
    /// channel playing then (header and groups wait until it has).
    static func beginReturn() {
        returningFromPlayer = true
        prepareGuideReturn?()
    }

    static func endReturn(_ reason: String) {
        guard returningFromPlayer else { return }
        returningFromPlayer = false
    }

    /// Fast presses stop on the channel and in the groups: the next step
    /// to the left needs this much quiet.
    static let pause: TimeInterval = 0.45

    // One touch on the remote's surface. A fast swipe goes on moving focus
    // after the guide handled it; a step out of the guide or the groups
    // needs a new touch (or a press after the swipe has settled).
    private(set) static var touchSession = 0
    private static var touchActiveSince: Date?
    private static var touchEnded = Date.distantPast

    static func trackTouches(on view: UIView) {
        let pan = UIPanGestureRecognizer(target: TouchTracker.shared, action: #selector(TouchTracker.pan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = TouchTracker.shared
        view.addGestureRecognizer(pan)
    }

    /// A finger on the remote (a touch left open stops counting after 2 s).
    static var isTouching: Bool {
        guard let since = touchActiveSince else { return false }
        return Date().timeIntervalSince(since) < 2
    }

    fileprivate static func touchBegan() {
        touchSession &+= 1
        touchActiveSince = Date()
    }

    /// The swipe is over: gates still waiting for it start their pause.
    fileprivate static func touchFinished() {
        touchActiveSince = nil
        touchEnded = Date()
        guideGate?.holdIfClosed()
        groupGate?.holdIfClosed()
    }
}

/// A focus guide on the left edge of the guide or the groups. Closed it
/// leads back onto the focused row or group (never a dead end: tvOS opens
/// the app's sidebar when focus can't move left); open it leads on (to the
/// groups, or nowhere, so the sidebar opens). It opens after a pause with
/// no finger on the remote, so fast presses and one long swipe stop here.
final class LiveTVLeftGate: UIFocusGuide {
    var name = ""
    var stay: () -> UIFocusEnvironment? = { nil }
    var onward: () -> [UIFocusEnvironment] = { [] }
    var canOpen: () -> Bool = { true }
    private(set) var isOpen = false
    private var timer: Timer?

    /// Closes now and opens after the pause.
    func hold() {
        close()
        timer = Timer.scheduledTimer(withTimeInterval: LiveTVFocusLinks.pause, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tryOpen() }
        }
    }

    /// A press or swipe that was held back: the pause starts again.
    @objc func holdIfClosed() {
        if !isOpen { hold() }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        isOpen = false
        refresh()
    }

    private func tryOpen() {
        timer = nil
        // Still swiping: opens once the finger is off (touchFinished).
        guard canOpen(), !LiveTVFocusLinks.isTouching else { return }
        isOpen = true
        refresh()
    }

    func refresh() {
        let targets = isOpen ? onward() : [stay()].compactMap { $0 }
        preferredFocusEnvironments = targets
        isEnabled = !targets.isEmpty
    }
}

/// Back from the player: header and groups stay out of reach until the
/// guide has focus (SwiftUI side of `LiveTVFocusLinks.returningFromPlayer`).
@MainActor
final class LiveTVReturnLock: ObservableObject {
    static let shared = LiveTVReturnLock()
    @Published var locked = false
}

/// Watches touches only; never takes them from the focus engine.
@MainActor
private final class TouchTracker: NSObject, UIGestureRecognizerDelegate {
    static let shared = TouchTracker()

    @objc func pan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began: LiveTVFocusLinks.touchBegan()
        case .ended, .cancelled, .failed: LiveTVFocusLinks.touchFinished()
        default: break
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}
