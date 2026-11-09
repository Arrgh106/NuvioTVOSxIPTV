import UIKit

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
