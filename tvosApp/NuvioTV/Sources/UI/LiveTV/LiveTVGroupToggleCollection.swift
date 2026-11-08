import SwiftUI
import UIKit

/// The group manager's list (hundreds of groups) as a `UICollectionView`
/// with cell reuse; the SwiftUI stack stuttered and its rows overlapped.
struct LiveTVGroupToggleCollection: UIViewRepresentable {
    let groups: [LiveTVGroup]
    let hiddenIDs: Set<String>
    let onToggle: (LiveTVGroup) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .fractionalWidth(1), heightDimension: .absolute(LiveTVGroupToggleCell.height)))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(
            widthDimension: .fractionalWidth(1), heightDimension: .absolute(LiveTVGroupToggleCell.height)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 6
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)

        let view = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
        view.backgroundColor = .clear
        view.remembersLastFocusedIndexPath = true
        view.register(LiveTVGroupToggleCell.self, forCellWithReuseIdentifier: LiveTVGroupToggleCell.reuseID)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: 40, right: 0)
        context.coordinator.update(groups: groups, hiddenIDs: hiddenIDs, onToggle: onToggle, in: view)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.update(groups: groups, hiddenIDs: hiddenIDs, onToggle: onToggle, in: view)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        private var groups: [LiveTVGroup] = []
        private var hiddenIDs: Set<String> = []
        private var onToggle: (LiveTVGroup) -> Void = { _ in }

        func update(groups: [LiveTVGroup], hiddenIDs: Set<String>, onToggle: @escaping (LiveTVGroup) -> Void, in view: UICollectionView) {
            self.onToggle = onToggle
            if groups != self.groups {
                self.groups = groups
                self.hiddenIDs = hiddenIDs
                view.reloadData()
                return
            }
            guard hiddenIDs != self.hiddenIDs else { return }
            self.hiddenIDs = hiddenIDs
            // Restyle in place so focus stays on the row just toggled.
            for case let cell as LiveTVGroupToggleCell in view.visibleCells {
                if let id = cell.groupID { cell.setHidden(hiddenIDs.contains(id)) }
            }
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            groups.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: LiveTVGroupToggleCell.reuseID, for: indexPath) as! LiveTVGroupToggleCell
            if indexPath.item < groups.count {
                let group = groups[indexPath.item]
                cell.configure(with: group, hidden: hiddenIDs.contains(group.id))
            }
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard indexPath.item < groups.count else { return }
            onToggle(groups[indexPath.item])
        }
    }
}

final class LiveTVGroupToggleCell: UICollectionViewCell {
    static let reuseID = "LiveTVGroupToggleCell"
    static let height: CGFloat = 60

    private(set) var groupID: String?
    private let background = UIView()
    private let eye = UIImageView()
    private let nameLabel = UILabel()
    private let countLabel = UILabel()
    private var isGroupHidden = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.layer.cornerRadius = 12
        background.layer.cornerCurve = .continuous
        background.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(background)

        eye.contentMode = .scaleAspectFit
        eye.preferredSymbolConfiguration = .init(pointSize: 24)
        nameLabel.font = .systemFont(ofSize: 24)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .regular)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [eye, nameLabel, countLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 18
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
            eye.widthAnchor.constraint(equalToConstant: 36),
        ])
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with group: LiveTVGroup, hidden: Bool) {
        groupID = group.id
        nameLabel.text = group.name
        countLabel.text = group.count.formatted()
        isGroupHidden = hidden
        applyStyle()
    }

    func setHidden(_ hidden: Bool) {
        guard hidden != isGroupHidden else { return }
        isGroupHidden = hidden
        applyStyle()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations({ [weak self] in self?.applyStyle() })
    }

    private func applyStyle() {
        let focused = isFocused
        eye.image = UIImage(systemName: isGroupHidden ? "eye.slash" : "eye")
        background.backgroundColor = focused ? .white : .clear
        let base: UIColor = focused ? .black : .white
        let alpha: CGFloat = isGroupHidden && !focused ? 0.45 : 1
        nameLabel.textColor = base.withAlphaComponent(alpha)
        eye.tintColor = base.withAlphaComponent(alpha)
        countLabel.textColor = base.withAlphaComponent(alpha * 0.6)
        transform = focused ? CGAffineTransform(scaleX: 1.01, y: 1.01) : .identity
    }
}
