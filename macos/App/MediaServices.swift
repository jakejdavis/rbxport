import AppKit
import CoreGraphics
import ImageIO
import os

/// A decoded image that can cross actors: a `CGImage` is immutable once made.
struct SendableImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// Loads, decodes, downsizes and caches track artwork for the table and the info panel.
///
/// Bytes come from the backend (off the main actor), are decoded straight to a thumbnail no
/// bigger than the size asked for (ImageIO never inflates the full image), and the result is
/// kept in an `NSCache` keyed by track id and size bucket. At most `maxConcurrent` loads run.
@MainActor
final class ArtworkService {
    /// Thumbnails are cached at these edge lengths (pixels), so a resized column does not
    /// decode again for every width.
    static let buckets = [64, 128, 256, 512, 1024]

    static func bucket(for pixels: Int) -> Int {
        buckets.first { $0 >= pixels } ?? buckets[buckets.count - 1]
    }

    struct Key: Hashable, Sendable {
        let id: String
        let bucket: Int
    }

    private let cache = NSCache<NSString, NSImage>()
    private let loader: LazyLoader<Key, SendableImage>

    init(backend: any BackendProtocol, maxConcurrent: Int = 6, settle: Duration = .milliseconds(20), cacheLimit: Int = 600) {
        cache.countLimit = cacheLimit
        loader = LazyLoader(maxConcurrent: maxConcurrent, settle: settle) { key in
            guard let data = await backend.artwork(id: key.id) else { return nil }
            guard !Task.isCancelled, let image = ArtworkService.thumbnail(from: data, maxPixels: key.bucket) else {
                return nil
            }
            return SendableImage(cgImage: image)
        }
    }

    /// Decodes `data` to an image whose longer edge is at most `maxPixels`. Nil if it is not an image.
    nonisolated static func thumbnail(from data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func cacheKey(_ id: String, _ bucket: Int) -> NSString { "\(id)@\(bucket)" as NSString }

    /// The cached image for a track at roughly `pixels` across, if it is already decoded.
    func cached(id: String, pixels: Int) -> NSImage? {
        cache.object(forKey: cacheKey(id, Self.bucket(for: pixels)))
    }

    /// Asks for an image; `completion` gets nil when the track has no usable artwork. A cached
    /// image completes at once and returns nil (nothing to cancel).
    func request(id: String, pixels: Int, completion: @escaping @MainActor (NSImage?) -> Void) -> Ticket? {
        let bucket = Self.bucket(for: pixels)
        if let hit = cache.object(forKey: cacheKey(id, bucket)) {
            completion(hit)
            return nil
        }
        let ticket = loader.request(Key(id: id, bucket: bucket)) { [weak self] value in
            guard let value else { completion(nil); return }
            let image = NSImage(cgImage: value.cgImage, size: NSSize(width: value.cgImage.width, height: value.cgImage.height))
            self?.cache.setObject(image, forKey: self?.cacheKey(id, bucket) ?? "")
            completion(image)
        }
        return Ticket(inner: ticket)
    }

    func cancel(_ ticket: Ticket?) {
        if let ticket { loader.cancel(ticket.inner) }
    }

    /// Loads in flight (waiting for a slot or running).
    var inFlightCount: Int { loader.inFlightCount }

    func removeAll() { cache.removeAllObjects() }

    struct Ticket {
        fileprivate let inner: LazyLoader<Key, SendableImage>.Ticket
    }
}

/// Fetches waveform bytes and renders row previews, caching both.
///
/// A row must stay on screen for `settle` before anything is fetched; at most `maxConcurrent`
/// fetches are in flight; fetches for rows that scroll away are cancelled. Rendered bitmaps are
/// cached by track, pixel width and height, device scale and palette; the raw bytes by track and
/// palette, so a column resize re-renders without fetching again.
@MainActor
final class WaveformService {
    struct Style: Hashable, Sendable {
        let palette: WaveformPalette
        let pixelWidth: Int
        let pixelHeight: Int
        let topInset: Int
        let bottomInset: Int
    }

    struct Key: Hashable, Sendable {
        let id: String
        let style: Style
    }

    /// Raw waveform bytes by track and palette. `NSCache` is thread-safe; the box says so.
    private final class ByteCache: @unchecked Sendable {
        final class Entry { let data: Data; init(_ data: Data) { self.data = data } }
        let cache = NSCache<NSString, Entry>()
    }

    final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let bitmaps = NSCache<NSString, CGImageBox>()
    private let bytes = ByteCache()
    private let loader: LazyLoader<Key, SendableImage>
    private let fetchCount = OSAllocatedUnfairLock(initialState: 0)
    /// Byte fetches that reached the backend, for tests.
    var fetchesStarted: Int { fetchCount.withLock { $0 } }

    init(backend: any BackendProtocol, maxConcurrent: Int = 16, settle: Duration = .milliseconds(35), cacheLimit: Int = 500) {
        bitmaps.countLimit = cacheLimit
        let byteCache = bytes
        byteCache.cache.countLimit = cacheLimit * 2
        let fetchCount = fetchCount
        loader = LazyLoader(maxConcurrent: maxConcurrent, settle: settle) { key in
            let style = key.style
            let cacheKey = "\(key.id)#\(style.palette.rawValue)" as NSString
            var data = byteCache.cache.object(forKey: cacheKey)?.data
            if data == nil {
                fetchCount.withLock { $0 += 1 }
                data = try? await backend.waveform(id: key.id, kind: style.palette.kind)
                if let data, !data.isEmpty { byteCache.cache.setObject(ByteCache.Entry(data), forKey: cacheKey) }
            }
            guard let data, !data.isEmpty, !Task.isCancelled,
                let image = WaveformRenderer.render(
                    data: data, palette: style.palette, pixelWidth: style.pixelWidth, pixelHeight: style.pixelHeight,
                    topInset: style.topInset, bottomInset: style.bottomInset)
            else { return nil }
            return SendableImage(cgImage: image)
        }
    }

    private func bitmapKey(_ id: String, _ style: Style, scale: CGFloat) -> NSString {
        "\(id)|\(style.palette.rawValue)|\(style.pixelWidth)x\(style.pixelHeight)|\(style.topInset)|\(style.bottomInset)|\(scale)" as NSString
    }

    func cached(id: String, style: Style, scale: CGFloat) -> CGImage? {
        bitmaps.object(forKey: bitmapKey(id, style, scale: scale))?.image
    }

    /// Asks for a rendered preview. A cached one completes at once and returns nil.
    func request(id: String, style: Style, scale: CGFloat, completion: @escaping @MainActor (CGImage?) -> Void) -> Ticket? {
        if let hit = cached(id: id, style: style, scale: scale) {
            completion(hit)
            return nil
        }
        let ticket = loader.request(Key(id: id, style: style)) { [weak self] value in
            guard let value else { completion(nil); return }
            self?.bitmaps.setObject(CGImageBox(value.cgImage), forKey: self?.bitmapKey(id, style, scale: scale) ?? "")
            completion(value.cgImage)
        }
        return Ticket(inner: ticket)
    }

    func cancel(_ ticket: Ticket?) {
        if let ticket { loader.cancel(ticket.inner) }
    }

    var inFlightCount: Int { loader.inFlightCount }

    /// Drops everything cached (a library reload may have changed analysis).
    func removeAll() {
        bitmaps.removeAllObjects()
        bytes.cache.removeAllObjects()
    }

    struct Ticket {
        fileprivate let inner: LazyLoader<Key, SendableImage>.Ticket
    }
}

/// What Show in Finder needs from the workspace; `NSWorkspace` is the real one, tests bring a fake.
@MainActor
protocol FileRevealing {
    func activateFileViewerSelecting(_ fileURLs: [URL])
}

extension NSWorkspace: FileRevealing {}

/// Selects `urls` in a Finder window (Show in Finder).
@MainActor
func revealInFileViewer(_ urls: [URL], using workspace: any FileRevealing = NSWorkspace.shared) {
    guard !urls.isEmpty else { return }
    workspace.activateFileViewerSelecting(urls)
}
