import SwiftUI
import UIKit

/// The channel list as a `UICollectionView`: cells are reused, so a group
/// with tens of thousands of channels costs the same as one with ten. A
/// SwiftUI lazy stack keeps every row it ever showed and its focus search
/// hung with ~56k rows.
struct LiveTVChannelCollection: UIViewRepresentable {
    /// Changes whenever a different list is shown (group switch, reload), so
    /// the view reloads and scrolls back to the top.
    let listID: String
    let channels: [XtreamLiveChannel]
    var favoriteIDs: Set<Int> = []
    let onSelect: (XtreamLiveChannel) -> Void
    /// Long press (context menu): add to / remove from Favorites.
    var onToggleFavorite: (XtreamLiveChannel) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        let view = UICollectionView(frame: .zero, collectionViewLayout: Self.layout())
        view.backgroundColor = .clear
        view.remembersLastFocusedIndexPath = true
        view.register(LiveTVChannelCell.self, forCellWithReuseIdentifier: LiveTVChannelCell.reuseID)
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.contentInset = UIEdgeInsets(top: 20, left: 0, bottom: 40, right: 0)
        context.coordinator.update(listID: listID, channels: channels, onSelect: onSelect, in: view)
        context.coordinator.updateFavorites(favoriteIDs, onToggle: onToggleFavorite, in: view)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.update(listID: listID, channels: channels, onSelect: onSelect, in: view)
        context.coordinator.updateFavorites(favoriteIDs, onToggle: onToggleFavorite, in: view)
    }

    private static func layout() -> UICollectionViewLayout {
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .fractionalWidth(1), heightDimension: .absolute(LiveTVChannelCell.height)))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(
            widthDimension: .fractionalWidth(1), heightDimension: .absolute(LiveTVChannelCell.height)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 8
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        return UICollectionViewCompositionalLayout(section: section)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        private var listID: String?
        private var channels: [XtreamLiveChannel] = []
        private var onSelect: (XtreamLiveChannel) -> Void = { _ in }
        private var favoriteIDs: Set<Int> = []
        private var onToggleFavorite: (XtreamLiveChannel) -> Void = { _ in }

        func updateFavorites(_ ids: Set<Int>, onToggle: @escaping (XtreamLiveChannel) -> Void, in view: UICollectionView) {
            onToggleFavorite = onToggle
            guard ids != favoriteIDs else { return }
            favoriteIDs = ids
            for case let cell as LiveTVChannelCell in view.visibleCells {
                cell.setFavorite(cell.streamIDValue.map(ids.contains) ?? false)
            }
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

        func update(
            listID: String,
            channels: [XtreamLiveChannel],
            onSelect: @escaping (XtreamLiveChannel) -> Void,
            in view: UICollectionView
        ) {
            self.onSelect = onSelect
            guard listID != self.listID || channels.count != self.channels.count else { return }
            let isNewList = listID != self.listID
            self.listID = listID
            self.channels = channels
            view.reloadData()
            if isNewList, !channels.isEmpty {
                view.setContentOffset(CGPoint(x: 0, y: -view.contentInset.top), animated: false)
            }
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            channels.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: LiveTVChannelCell.reuseID, for: indexPath) as! LiveTVChannelCell
            if indexPath.item < channels.count {
                let channel = channels[indexPath.item]
                cell.configure(with: channel)
                cell.setFavorite(favoriteIDs.contains(channel.streamID))
            }
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard indexPath.item < channels.count else { return }
            onSelect(channels[indexPath.item])
        }
    }
}

// MARK: - Cell

final class LiveTVChannelCell: UICollectionViewCell {
    static let reuseID = "LiveTVChannelCell"
    static let height: CGFloat = 92

    private let background = UIView()
    private let numberLabel = UILabel()
    private let logoView = UIImageView()
    private let placeholder = UIImageView(image: UIImage(systemName: "tv"))
    private let nameLabel = UILabel()
    /// "Now: Title · 20:15–21:00" from the short EPG, filled in when it arrives.
    private let epgLabel = UILabel()
    private var epgTask: Task<Void, Never>?
    private var streamID: Int?
    private let archiveIcon = UIImageView(image: UIImage(systemName: "clock.arrow.circlepath"))
    private let favoriteIcon = UIImageView(image: UIImage(systemName: "star.fill"))
    var streamIDValue: Int? { streamID }
    private var logoTask: Task<Void, Never>?
    private var logoURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)

        background.layer.cornerRadius = 14
        background.layer.cornerCurve = .continuous
        background.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(background)

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        numberLabel.textAlignment = .right

        let logoBox = UIView()
        logoBox.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        logoBox.layer.cornerRadius = 8
        logoBox.layer.cornerCurve = .continuous
        logoBox.clipsToBounds = true
        logoView.contentMode = .scaleAspectFit
        placeholder.tintColor = UIColor.white.withAlphaComponent(0.3)
        placeholder.contentMode = .center
        placeholder.preferredSymbolConfiguration = .init(pointSize: 30)
        for view in [placeholder, logoView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            logoBox.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: logoBox.leadingAnchor, constant: 4),
                view.trailingAnchor.constraint(equalTo: logoBox.trailingAnchor, constant: -4),
                view.topAnchor.constraint(equalTo: logoBox.topAnchor, constant: 4),
                view.bottomAnchor.constraint(equalTo: logoBox.bottomAnchor, constant: -4),
            ])
        }

        nameLabel.font = .systemFont(ofSize: 26, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        archiveIcon.contentMode = .scaleAspectFit
        archiveIcon.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        epgLabel.font = .systemFont(ofSize: 20, weight: .regular)
        epgLabel.lineBreakMode = .byTruncatingTail
        epgLabel.isHidden = true
        let textStack = UIStackView(arrangedSubviews: [nameLabel, epgLabel])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        favoriteIcon.contentMode = .scaleAspectFit
        favoriteIcon.tintColor = .systemYellow
        favoriteIcon.isHidden = true
        favoriteIcon.setContentHuggingPriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [numberLabel, logoBox, textStack, favoriteIcon, archiveIcon])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 24
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
            numberLabel.widthAnchor.constraint(equalToConstant: 80),
            logoBox.widthAnchor.constraint(equalToConstant: 120),
            logoBox.heightAnchor.constraint(equalToConstant: 68),
        ])
        applyFocus(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with channel: XtreamLiveChannel) {
        numberLabel.text = channel.number.map(String.init) ?? ""
        nameLabel.text = channel.name
        archiveIcon.isHidden = channel.archiveDays == 0
        loadLogo(channel.logoURL.flatMap(URL.init(string:)))
        loadEPG(channel.streamID)
    }

    func setFavorite(_ favorite: Bool) {
        favoriteIcon.isHidden = !favorite
    }

    private func loadEPG(_ id: Int) {
        streamID = id
        if let cached = LiveTVEPG.shared.cached(id) {
            showEPG(cached)
            return
        }
        epgTask = Task { [weak self] in
            // Skip rows that only fly past while scrolling fast.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let info = await LiveTVEPG.shared.nowNext(for: id)
            guard !Task.isCancelled, let self, self.streamID == id else { return }
            self.showEPG(info)
        }
    }

    private func showEPG(_ info: LiveTVEPG.NowNext?) {
        guard let now = info?.now else {
            epgLabel.text = nil
            epgLabel.isHidden = true
            return
        }
        epgLabel.text = "\(now.title)  ·  \(now.timeRange)"
        epgLabel.isHidden = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        logoTask?.cancel()
        logoTask = nil
        epgTask?.cancel()
        epgTask = nil
        streamID = nil
        epgLabel.text = nil
        epgLabel.isHidden = true
        logoURL = nil
        logoView.image = nil
        placeholder.isHidden = false
    }

    private func loadLogo(_ url: URL?) {
        logoURL = url
        guard let url else { return }
        if let cached = LiveTVLogoCache.shared.image(for: url) {
            logoView.image = cached
            placeholder.isHidden = true
            return
        }
        logoTask = Task { [weak self] in
            guard let image = await LiveTVLogoCache.shared.load(url) else { return }
            await MainActor.run {
                guard let self, self.logoURL == url else { return }
                self.logoView.image = image
                self.placeholder.isHidden = true
            }
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations({ [weak self] in
            guard let self else { return }
            self.applyFocus(self.isFocused)
        })
    }

    private func applyFocus(_ focused: Bool) {
        let text: UIColor = focused ? .black : .white
        background.backgroundColor = focused ? .white : .clear
        nameLabel.textColor = text
        epgLabel.textColor = focused ? UIColor.black.withAlphaComponent(0.65) : UIColor.white.withAlphaComponent(0.55)
        numberLabel.textColor = focused ? UIColor.black.withAlphaComponent(0.6) : UIColor.white.withAlphaComponent(0.6)
        archiveIcon.tintColor = focused ? UIColor.black.withAlphaComponent(0.6) : UIColor.white.withAlphaComponent(0.6)
        transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
    }
}

// MARK: - Logo cache

/// Channel logos, kept in memory while the app runs. Many providers serve the
/// same few hundred logos for thousands of channels.
final class LiveTVLogoCache: @unchecked Sendable {
    static let shared = LiveTVLogoCache()

    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 600
        return cache
    }()

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func load(_ url: URL) async -> UIImage? {
        if let cached = image(for: url) { return cached }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true,
              let image = UIImage(data: data) else { return nil }
        // Decode off the main thread and shrink: logos are shown at 120×68.
        let thumbnail = image.preparingThumbnail(of: CGSize(width: 240, height: 136)) ?? image
        cache.setObject(thumbnail, forKey: url as NSURL)
        return thumbnail
    }
}
