import UIKit

/// One guide row (LIVE_TV_DESIGN.md, step 1): the channel (number, logo,
/// name) and its programmes across the visible two hours. As on Android
/// (`GuideRowStrip.kt`), the programmes are painted in one pass instead of
/// being a view each, so moving through the guide only redraws, never lays
/// out. The whole row is one focus item; the coordinator moves the time cursor.
final class LiveTVGuideRowCell: UICollectionViewCell {
    static let reuseID = "LiveTVGuideRowCell"
    static let height: CGFloat = 88
    /// Width of the channel part; the time ruler starts its strip here too.
    static let channelWidth: CGFloat = 400

    private let channelBackground = UIView()
    private let numberLabel = UILabel()
    private let logoView = UIImageView()
    private let placeholder = UIImageView(image: UIImage(systemName: "tv"))
    private let nameLabel = UILabel()
    private let favoriteIcon = UIImageView(image: UIImage(systemName: "star.fill"))
    private let archiveIcon = UIImageView(image: UIImage(systemName: "clock.arrow.circlepath"))
    let strip = LiveTVProgrammeStrip()

    private(set) var channel: XtreamLiveChannel?
    /// Called when the row's programmes arrive (not for cached ones).
    var onProgrammesLoaded: (() -> Void)?
    private var logoTask: Task<Void, Never>?
    private var logoURL: URL?
    private var programmeTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)

        channelBackground.layer.cornerRadius = LiveTVTheme.Metric.cornerRadius
        channelBackground.layer.cornerCurve = .continuous
        channelBackground.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(channelBackground)

        numberLabel.font = .monospacedDigitSystemFont(ofSize: LiveTVTheme.Font.small, weight: .semibold)
        numberLabel.textAlignment = .right
        numberLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        numberLabel.adjustsFontSizeToFitWidth = true
        numberLabel.minimumScaleFactor = 0.7

        let logoBox = UIView()
        logoBox.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        logoBox.layer.cornerRadius = 8
        logoBox.layer.cornerCurve = .continuous
        logoBox.clipsToBounds = true
        logoView.contentMode = .scaleAspectFit
        placeholder.tintColor = UIColor.white.withAlphaComponent(0.3)
        placeholder.contentMode = .center
        placeholder.preferredSymbolConfiguration = .init(pointSize: 24)
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

        nameLabel.font = .systemFont(ofSize: LiveTVTheme.Font.secondary, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for icon in [favoriteIcon, archiveIcon] {
            icon.contentMode = .scaleAspectFit
            icon.isHidden = true
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.preferredSymbolConfiguration = .init(pointSize: 18)
        }
        favoriteIcon.tintColor = .systemYellow
        archiveIcon.tintColor = UIColor.white.withAlphaComponent(0.5)

        let stack = UIStackView(arrangedSubviews: [numberLabel, logoBox, nameLabel, favoriteIcon, archiveIcon])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        strip.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(strip)

        let inset = LiveTVProgrammeStrip.verticalInset
        NSLayoutConstraint.activate([
            channelBackground.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            channelBackground.widthAnchor.constraint(equalToConstant: Self.channelWidth - 8),
            channelBackground.topAnchor.constraint(equalTo: contentView.topAnchor, constant: inset),
            channelBackground.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: channelBackground.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: channelBackground.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            numberLabel.widthAnchor.constraint(equalToConstant: 64),
            logoBox.widthAnchor.constraint(equalToConstant: 96),
            logoBox.heightAnchor.constraint(equalToConstant: 56),
            strip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Self.channelWidth),
            strip.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            strip.topAnchor.constraint(equalTo: contentView.topAnchor),
            strip.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        applyFocus(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with channel: XtreamLiveChannel, favorite: Bool, timeline: LiveTVTimeline, now: Date) {
        self.channel = channel
        numberLabel.text = channel.number.map(String.init) ?? ""
        nameLabel.text = channel.name
        archiveIcon.isHidden = channel.archiveDays == 0
        setFavorite(favorite)
        loadLogo(channel.logoURL.flatMap(URL.init(string:)))
        strip.update(timeline: timeline, now: now)
        loadProgrammes(for: channel)
    }

    func setFavorite(_ favorite: Bool) {
        favoriteIcon.isHidden = !favorite
    }

    /// Reloads after the guide changed (new import).
    func reloadProgrammes() {
        guard let channel else { return }
        strip.programmes = nil
        loadProgrammes(for: channel)
    }

    private func loadProgrammes(for channel: XtreamLiveChannel) {
        programmeTask?.cancel()
        if let cached = LiveTVGuideRows.shared.cached(channel) {
            strip.programmes = cached
            return
        }
        strip.programmes = nil
        let id = channel.streamID
        programmeTask = Task { [weak self] in
            // Rows that only fly past while scrolling fast aren't loaded.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let list = await LiveTVGuideRows.shared.programmes(for: channel)
            guard !Task.isCancelled, let self, self.channel?.streamID == id else { return }
            self.strip.programmes = list
            self.onProgrammesLoaded?()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        logoTask?.cancel()
        logoTask = nil
        programmeTask?.cancel()
        programmeTask = nil
        channel = nil
        logoURL = nil
        logoView.image = nil
        placeholder.isHidden = false
        strip.programmes = nil
        strip.cursor = nil
        setChannelHighlighted(false)
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
            guard let self, self.logoURL == url else { return }
            self.logoView.image = image
            self.placeholder.isHidden = true
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = isFocused
        coordinator.addCoordinatedAnimations({ [weak self] in
            self?.applyFocus(focused)
        })
    }

    /// The cursor is on the channel itself (white, like a focused list row).
    private var channelHighlighted = false

    func setChannelHighlighted(_ highlighted: Bool) {
        guard highlighted != channelHighlighted else { return }
        channelHighlighted = highlighted
        applyFocus(isFocused)
    }

    /// The strong highlight is where the cursor is: the programme (white
    /// tile) or the channel (white channel part). Otherwise the channel part
    /// of the focused row is only lifted a little.
    private func applyFocus(_ focused: Bool) {
        let onChannel = focused && channelHighlighted
        channelBackground.backgroundColor = onChannel ? .white
            : focused ? UIColor.white.withAlphaComponent(0.16) : .clear
        nameLabel.textColor = onChannel ? .black : .white
        numberLabel.textColor = onChannel ? UIColor.black.withAlphaComponent(0.6)
            : UIColor.white.withAlphaComponent(focused ? 0.8 : 0.55)
        archiveIcon.tintColor = onChannel ? UIColor.black.withAlphaComponent(0.6) : UIColor.white.withAlphaComponent(0.5)
    }
}

// MARK: - Programme strip

/// Draws one row's programmes for the visible window, the now line and,
/// on the focused row, the cursor's programme as a white tile.
final class LiveTVProgrammeStrip: UIView {
    static let verticalInset: CGFloat = 4
    private static let gap: CGFloat = 3

    var programmes: [XtreamProgram]? {
        didSet { if programmes != oldValue { setNeedsDisplay() } }
    }
    /// Set on the focused row only: the instant the cursor points at.
    var cursor: Date? {
        didSet { if cursor != oldValue { setNeedsDisplay() } }
    }
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

    // MARK: Drawing

    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    private static let titleFont = UIFont.systemFont(ofSize: LiveTVTheme.Font.small + 2, weight: .medium)
    private static let timeFont = UIFont.monospacedDigitSystemFont(ofSize: LiveTVTheme.Font.badge + 1, weight: .regular)
    private static let noInfoFont = UIFont.italicSystemFont(ofSize: LiveTVTheme.Font.small)
    private static let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let width = bounds.width
        guard width > 0 else { return }
        let height = bounds.height - Self.verticalInset * 2
        let top = Self.verticalInset
        let list = programmes ?? []
        let loading = programmes == nil
        let cursorBlockStart: Date? = cursor.map { LiveTVTimeline.block(at: $0, in: list).start }

        for block in timeline.visibleBlocks(in: list) {
            let x0 = max(0, CGFloat(timeline.fraction(of: block.start)) * width)
            let x1 = min(width, CGFloat(timeline.fraction(of: block.end)) * width)
            let tile = CGRect(x: x0 + Self.gap, y: top, width: x1 - x0 - Self.gap * 2, height: height)
            guard tile.width > 2 else { continue }
            let isCursor = cursorBlockStart == block.start
            let isNow = block.contains(now)
            let isPast = block.end <= now
            let path = UIBezierPath(roundedRect: tile, cornerRadius: 10)

            let fill: UIColor
            if isCursor {
                fill = .white
            } else if block.programme == nil {
                fill = UIColor.white.withAlphaComponent(0.035)
            } else if isNow {
                fill = UIColor.white.withAlphaComponent(0.13)
            } else {
                fill = UIColor.white.withAlphaComponent(isPast ? 0.04 : 0.08)
            }
            fill.setFill()
            path.fill()
            if isCursor, !LiveTVTheme.isWhiteAccent {
                LiveTVTheme.accentUIColor.setStroke()
                path.lineWidth = 3
                path.stroke()
            }

            // Progress of what's on now, along the bottom of the tile.
            if isNow, block.programme != nil {
                let fraction = now.timeIntervalSince(block.start) / max(1, block.end.timeIntervalSince(block.start))
                let bar = CGRect(x: tile.minX + 10, y: tile.maxY - 7, width: (tile.width - 20) * CGFloat(min(1, max(0, fraction))), height: 3)
                (isCursor ? UIColor.black.withAlphaComponent(0.55) : LiveTVTheme.markUIColor).setFill()
                UIBezierPath(roundedRect: bar, cornerRadius: 1.5).fill()
            }

            let textWidth = tile.width - 24
            guard textWidth > 24 else { continue }
            context.saveGState()
            context.clip(to: tile.insetBy(dx: 12, dy: 0))
            let primary: UIColor = isCursor ? .black : UIColor.white.withAlphaComponent(isPast ? 0.5 : 0.92)
            let secondary: UIColor = isCursor ? UIColor.black.withAlphaComponent(0.6) : UIColor.white.withAlphaComponent(0.5)
            if let programme = block.programme {
                let title = programme.title as NSString
                title.draw(in: CGRect(x: tile.minX + 12, y: tile.minY + 10, width: textWidth, height: 28), withAttributes: [
                    .font: Self.titleFont, .foregroundColor: primary, .paragraphStyle: Self.paragraph,
                ])
                let time = "\(programme.start.formatted(Self.timeStyle)) – \(programme.end.formatted(Self.timeStyle))" as NSString
                time.draw(in: CGRect(x: tile.minX + 12, y: tile.minY + 42, width: textWidth, height: 22), withAttributes: [
                    .font: Self.timeFont, .foregroundColor: secondary, .paragraphStyle: Self.paragraph,
                ])
            } else {
                let text = (loading ? "" : L10n.string("livetv_guide_no_info", fallback: "No information")) as NSString
                text.draw(in: CGRect(x: tile.minX + 12, y: tile.midY - 13, width: textWidth, height: 28), withAttributes: [
                    .font: Self.noInfoFont, .foregroundColor: secondary, .paragraphStyle: Self.paragraph,
                ])
            }
            context.restoreGState()
        }

        // Now line through the row (rows touch, so it reads as one line).
        let fraction = timeline.fraction(of: now)
        if fraction >= 0, fraction <= 1 {
            let x = CGFloat(fraction) * width
            LiveTVTheme.markUIColor.withAlphaComponent(0.9).setFill()
            context.fill(CGRect(x: x - 1, y: 0, width: 2, height: bounds.height))
        }
    }
}
