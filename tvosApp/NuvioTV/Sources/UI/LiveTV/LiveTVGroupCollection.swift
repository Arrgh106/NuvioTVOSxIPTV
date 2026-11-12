import SwiftUI
import UIKit

/// The group sidebar as a `UICollectionView` with cell reuse, like the
/// channel list: the SwiftUI stack stuttered while scrolling through
/// hundreds of groups.
struct LiveTVGroupCollection: UIViewRepresentable {
    let groups: [LiveTVGroup]
    let selectedID: String
    /// The number of channels beside each group (a Live TV option).
    var showCounts = true
    let onSelect: (String) -> Void
    /// Long press on a provider group: rename it (step 10a).
    var onRename: (LiveTVGroup) -> Void = { _ in }
    /// Reorder Groups (step 10b): set while it runs, to the group picked up
    /// first.
    var reorderStartID: String?
    var onReorderStart: (LiveTVGroup) -> Void = { _ in }
    var onReorderPicked: (String?) -> Void = { _ in }
    /// Menu: the groups in the order they were left in.
    var onReorderDone: ([String]) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> LiveTVGroupContainer {
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .fractionalWidth(1), heightDimension: .absolute(LiveTVGroupCell.height)))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(
            widthDimension: .fractionalWidth(1), heightDimension: .absolute(LiveTVGroupCell.height)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)

        let view = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
        view.backgroundColor = .clear
        view.remembersLastFocusedIndexPath = true
        view.register(LiveTVGroupCell.self, forCellWithReuseIdentifier: LiveTVGroupCell.reuseID)
        LiveTVFocusLinks.groups = view
        LiveTVFocusLinks.trackTouches(on: view)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.contentInset = UIEdgeInsets(top: 20, left: 0, bottom: 40, right: 0)
        context.coordinator.showCounts = showCounts
        context.coordinator.onRename = onRename
        context.coordinator.setReorderCallbacks(start: onReorderStart, picked: onReorderPicked, done: onReorderDone)
        context.coordinator.update(groups: groups, selectedID: selectedID, onSelect: onSelect, in: view)
        let container = LiveTVGroupContainer(collectionView: view)
        let gate = container.leftTrap
        gate.name = "groups"
        gate.canOpen = { [weak coordinator = context.coordinator] in !(coordinator?.isReordering ?? false) }
        // Menu while reordering: save and finish, never the app's sidebar.
        container.takesMenu = { [weak coordinator = context.coordinator] in coordinator?.isReordering ?? false }
        container.onMenu = { [weak coordinator = context.coordinator] in coordinator?.finishReorder() }
        gate.stay = { [weak coordinator = context.coordinator] in coordinator?.focusedCell }
        LiveTVFocusLinks.groupGate = gate
        context.coordinator.gate = gate
        // A press the gate held back restarts its pause.
        let pressLeft = UITapGestureRecognizer(target: gate, action: #selector(LiveTVLeftGate.holdIfClosed))
        pressLeft.allowedPressTypes = [NSNumber(value: UIPress.PressType.leftArrow.rawValue)]
        view.addGestureRecognizer(pressLeft)
        return container
    }

    func updateUIView(_ container: LiveTVGroupContainer, context: Context) {
        if context.coordinator.showCounts != showCounts {
            context.coordinator.showCounts = showCounts
            for case let cell as LiveTVGroupCell in container.collectionView.visibleCells {
                cell.setShowsCount(showCounts)
            }
        }
        context.coordinator.onRename = onRename
        context.coordinator.setReorderCallbacks(start: onReorderStart, picked: onReorderPicked, done: onReorderDone)
        context.coordinator.update(groups: groups, selectedID: selectedID, onSelect: onSelect, in: container.collectionView)
        context.coordinator.updateReorder(reorderStartID, in: container.collectionView)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        private var groups: [LiveTVGroup] = []
        private var selectedID = ""
        private var onSelect: (String) -> Void = { _ in }
        var onRename: (LiveTVGroup) -> Void = { _ in }
        var showCounts = true
        private var onReorderStart: (LiveTVGroup) -> Void = { _ in }
        private var onReorderPicked: (String?) -> Void = { _ in }
        private var onReorderDone: ([String]) -> Void = { _ in }
        /// Reorder Groups runs: OK picks a group up and puts it down where
        /// focus is, Menu saves. Search, Favorites, Recent and All stay on top.
        private(set) var isReordering = false
        private var pickedID: String?
        private weak var collection: UICollectionView?

        func setReorderCallbacks(
            start: @escaping (LiveTVGroup) -> Void, picked: @escaping (String?) -> Void,
            done: @escaping ([String]) -> Void
        ) {
            onReorderStart = start
            onReorderPicked = picked
            onReorderDone = done
        }

        func updateReorder(_ startID: String?, in view: UICollectionView) {
            collection = view
            if let startID, !isReordering {
                isReordering = true
                pickedID = groups.contains { $0.id == startID && !$0.isSpecial } ? startID : nil
                restyleMoving(in: view)
            } else if startID == nil, isReordering {
                isReordering = false
                pickedID = nil
                restyleMoving(in: view)
            }
        }

        func finishReorder() {
            guard isReordering else { return }
            let ids = groups.filter { !$0.isSpecial }.map(\.id)
            isReordering = false
            pickedID = nil
            if let collection { restyleMoving(in: collection) }
            onReorderDone(ids)
        }

        private func reorderSelect(at index: Int, in view: UICollectionView) {
            guard let picked = pickedID else {
                let group = groups[index]
                guard !group.isSpecial else { return }
                pickedID = group.id
                restyleMoving(in: view)
                onReorderPicked(group.name)
                return
            }
            pickedID = nil
            // Onto Search, Favorites, Recent or All: the first place below them.
            let first = groups.firstIndex { !$0.isSpecial } ?? 0
            let target = max(index, first)
            if let from = groups.firstIndex(where: { $0.id == picked }), from != target {
                groups = LiveTVListOrder.move(groups, from: from, to: target)
                view.performBatchUpdates {
                    view.moveItem(at: IndexPath(item: from, section: 0), to: IndexPath(item: target, section: 0))
                }
            }
            restyleMoving(in: view)
            onReorderPicked(nil)
        }

        private func restyleMoving(in view: UICollectionView) {
            for case let cell as LiveTVGroupCell in view.visibleCells {
                cell.setMoving(isReordering && pickedID != nil && cell.groupID == pickedID)
            }
        }

        func update(groups: [LiveTVGroup], selectedID: String, onSelect: @escaping (String) -> Void, in view: UICollectionView) {
            self.onSelect = onSelect
            // While reordering the list here is the one being arranged.
            guard !isReordering else { return }
            if groups != self.groups, groups.map(\.id) == self.groups.map(\.id) {
                // Same groups, other names or counts: relabel, focus stays.
                self.groups = groups
                self.selectedID = selectedID
                for case let cell as LiveTVGroupCell in view.visibleCells {
                    guard let indexPath = view.indexPath(for: cell), indexPath.item < groups.count else { continue }
                    cell.configure(with: groups[indexPath.item], selected: groups[indexPath.item].id == selectedID)
                    cell.setShowsCount(showCounts)
                }
                return
            }
            if groups != self.groups {
                self.groups = groups
                self.selectedID = selectedID
                view.reloadData()
                return
            }
            guard selectedID != self.selectedID else { return }
            self.selectedID = selectedID
            // Only restyle the visible cells; no reload, so focus stays put.
            for case let cell as LiveTVGroupCell in view.visibleCells {
                cell.setSelected(cell.groupID == selectedID)
            }
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            groups.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: LiveTVGroupCell.reuseID, for: indexPath) as! LiveTVGroupCell
            if indexPath.item < groups.count {
                let group = groups[indexPath.item]
                cell.configure(with: group, selected: group.id == selectedID)
                cell.setShowsCount(showCounts)
                cell.setMoving(isReordering && pickedID != nil && group.id == pickedID)
            }
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard indexPath.item < groups.count else { return }
            if isReordering {
                reorderSelect(at: indexPath.item, in: collectionView)
                return
            }
            onSelect(groups[indexPath.item].id)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
            point: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard !isReordering, let indexPath = indexPaths.first, indexPath.item < groups.count else { return nil }
            let group = groups[indexPath.item]
            // Search, Favorites, Recently watched and All keep their names and places.
            guard !group.isSpecial else { return nil }
            let several = groups.filter { !$0.isSpecial }.count > 1
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                var children: [UIMenuElement] = [
                    UIAction(
                        title: L10n.string("livetv_rename_group", fallback: "Rename Group"),
                        image: UIImage(systemName: "pencil")
                    ) { _ in self?.onRename(group) },
                ]
                if several {
                    children.append(UIAction(
                        title: L10n.string("livetv_reorder_groups", fallback: "Reorder Groups"),
                        image: UIImage(systemName: "arrow.up.arrow.down")
                    ) { _ in self?.onReorderStart(group) })
                }
                return UIMenu(title: group.name, children: children)
            }
        }

        // MARK: Focus

        /// While reordering focus stays in the groups.
        func collectionView(_ collectionView: UICollectionView, shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
            guard isReordering, !(context.nextFocusedItem is LiveTVGroupCell) else { return true }
            return context.focusHeading == .left
        }

        /// Not while coming back from the player: focus goes to the guide.
        func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
            !LiveTVFocusLinks.returningFromPlayer
        }

        /// The focused group, where the gate on the left leads back to.
        weak var focusedCell: LiveTVGroupCell?
        weak var gate: LiveTVLeftGate?

        func collectionView(
            _ collectionView: UICollectionView,
            didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
            with coordinator: UIFocusAnimationCoordinator
        ) {
            guard context.nextFocusedItem is LiveTVGroupCell else { return }
            focusedCell = context.nextFocusedItem as? LiveTVGroupCell
            if context.previouslyFocusedItem is LiveTVGroupCell {
                gate?.refresh()
            } else {
                // Just arrived: the press or swipe that brought focus here
                // doesn't go on into the sidebar.
                gate?.hold()
            }
        }
    }
}

/// The group list with a focus guide on its left edge (see `LiveTVLeftGate`).
final class LiveTVGroupContainer: LiveTVMenuTakingView {
    let collectionView: UICollectionView
    let leftTrap = LiveTVLeftGate()

    init(collectionView: UICollectionView) {
        self.collectionView = collectionView
        super.init(frame: .zero)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)
        addLayoutGuide(leftTrap)
        NSLayoutConstraint.activate([
            leftTrap.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftTrap.widthAnchor.constraint(equalToConstant: 8),
            leftTrap.topAnchor.constraint(equalTo: topAnchor),
            leftTrap.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leftTrap.trailingAnchor, constant: 2),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class LiveTVGroupCell: UICollectionViewCell {
    static let reuseID = "LiveTVGroupCell"
    static let height: CGFloat = 64

    private(set) var groupID: String?
    private let background = UIView()
    private let nameLabel = UILabel()
    private let countLabel = UILabel()
    private var isGroupSelected = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.layer.cornerRadius = LiveTVTheme.Metric.cornerRadius
        background.layer.cornerCurve = .continuous
        background.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(background)

        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .regular)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [nameLabel, countLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            background.topAnchor.constraint(equalTo: contentView.topAnchor),
            background.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with group: LiveTVGroup, selected: Bool) {
        groupID = group.id
        nameLabel.text = group.name
        countLabel.text = group.count.formatted()
        isGroupSelected = selected
        applyStyle()
    }

    func setShowsCount(_ shows: Bool) {
        countLabel.isHidden = !shows
    }

    /// Picked up in Reorder Groups (step 10b).
    func setMoving(_ moving: Bool) {
        background.layer.borderWidth = moving ? 4 : 0
        background.layer.borderColor = (LiveTVTheme.isWhiteAccent ? UIColor.systemOrange : LiveTVTheme.accentUIColor).cgColor
    }

    func setSelected(_ selected: Bool) {
        guard selected != isGroupSelected else { return }
        isGroupSelected = selected
        applyStyle()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations({ [weak self] in self?.applyStyle() })
    }

    private func applyStyle() {
        let focused = isFocused
        // The selected group carries the app's accent (Match Theme).
        let selectedFill = LiveTVTheme.accentUIColor.withAlphaComponent(
            LiveTVTheme.isWhiteAccent ? 0.14 : 0.28)
        background.backgroundColor = focused ? .white : (isGroupSelected ? selectedFill : .clear)
        nameLabel.font = .systemFont(ofSize: 24, weight: isGroupSelected ? .bold : .regular)
        nameLabel.textColor = focused ? .black : .white
        countLabel.textColor = focused ? UIColor.black.withAlphaComponent(0.6) : UIColor.white.withAlphaComponent(0.6)
        transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
    }
}
