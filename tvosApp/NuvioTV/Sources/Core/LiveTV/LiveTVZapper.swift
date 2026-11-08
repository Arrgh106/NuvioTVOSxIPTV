import Foundation

/// Channel up/down while a live channel plays. Holds the list the channel
/// was started from (the group shown in Live TV, as on Android) and turns a
/// step into the next channel's playback item. Up = next in the list,
/// down = previous, wrapping around at the ends.
@MainActor
final class LiveTVZapper {
    static let shared = LiveTVZapper()

    private(set) var channels: [XtreamLiveChannel] = []
    private(set) var currentIndex: Int?
    private var resolve: ((XtreamLiveChannel) -> LiveTVStore.PlaybackItem?)?

    var currentChannel: XtreamLiveChannel? {
        currentIndex.flatMap { channels.indices.contains($0) ? channels[$0] : nil }
    }

    /// Called when a channel is started from the Live TV list.
    func begin(
        channel: XtreamLiveChannel,
        in list: [XtreamLiveChannel],
        resolve: @escaping (XtreamLiveChannel) -> LiveTVStore.PlaybackItem?
    ) {
        channels = list
        currentIndex = list.firstIndex { $0.streamID == channel.streamID }
        self.resolve = resolve
    }

    /// The channel `delta` steps away and its playback item, or nil when
    /// there's nothing to switch to.
    func step(by delta: Int) -> (channel: XtreamLiveChannel, item: LiveTVStore.PlaybackItem)? {
        guard let resolve, let index = currentIndex, channels.count > 1 else { return nil }
        // Skip entries that can't be played (e.g. "##### …" separator rows
        // without a stream), at most one full round.
        var next = index
        for _ in 0..<channels.count {
            next = (next + delta % channels.count + channels.count) % channels.count
            if next == index { return nil }
            if let item = resolve(channels[next]) {
                currentIndex = next
                return (channels[next], item)
            }
        }
        return nil
    }
}
