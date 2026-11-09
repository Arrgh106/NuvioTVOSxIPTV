import SwiftUI
import UIKit

/// The group sidebar as a `UICollectionView` with cell reuse, like the
/// channel list: the SwiftUI stack stuttered while scrolling through
/// hundreds of groups.
struct LiveTVGroupCollection: UIViewRepresentable {
    let groups: [LiveTVGroup]
    let selectedID: String
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
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
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.contentInset = UIEdgeInsets(top: 20, left: 0, bottom: 40, right: 0)
        context.coordinator.update(groups: groups, selectedID: selectedID, onSelect: onSelect, in: view)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.update(groups: groups, selectedID: selectedID, onSelect: onSelect, in: view)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        private var groups: [LiveTVGroup] = []
        private var selectedID = ""
        private var onSelect: (String) -> Void = { _ in }

        func update(groups: [LiveTVGroup], selectedID: String, onSelect: @escaping (String) -> Void, in view: UICollectionView) {
            self.onSelect = onSelect
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
            }
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard indexPath.item < groups.count else { return }
            onSelect(groups[indexPath.item].id)
        }
    }
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
