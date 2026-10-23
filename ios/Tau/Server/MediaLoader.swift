import UIKit
import ImageIO
import SwiftSignalKit

/// An image an entry has on its server, sent as a reference (server/src/media.ts, docs/media.md): a photo the user
/// sent, or one a tool returned (the read tool's). The chat lays it out from its declared size and shows it once
/// fetched.
final class RemoteImage {
    /// The server's own conversation ID, the one `media.get` takes.
    let conversationId: Int
    let entryId: Int
    /// Its place among the entry's images.
    let index: Int
    let mimeType: String
    let bytes: Int
    /// As its header declares it, in pixels; nil when the server could not read it.
    let pixelSize: CGSize?
    /// The file it was sent from, kept by the server (docs/files.md): an edit sends that again, not the image.
    var fileId: String?
    /// Only a file, not an entry's image (one the agent sent): fetched from `/files/<id>`.
    let isFile: Bool
    fileprivate let loader: MediaLoader

    fileprivate init(conversationId: Int, entryId: Int, index: Int, mimeType: String, bytes: Int, pixelSize: CGSize?, loader: MediaLoader, fileId: String? = nil) {
        self.conversationId = conversationId
        self.entryId = entryId
        self.index = index
        self.mimeType = mimeType
        self.bytes = bytes
        self.pixelSize = pixelSize
        self.loader = loader
        self.fileId = fileId
        self.isFile = fileId != nil
    }

    var key: String {
        if self.isFile, let fileId = self.fileId {
            return "file-\(fileId)"
        }
        return "\(self.conversationId)-\(self.entryId)-\(self.index)"
    }

    /// What the chat shows: at most `MediaLoader.displayPixels` on its long side, decoded off the main thread.
    func display() -> Signal<UIImage?, NoError> {
        return self.loader.image(self, maxPixels: MediaLoader.displayPixels)
    }

    /// The display image when it is decoded already, so a row laid out again shows it at once.
    var cachedDisplay: UIImage? {
        return self.loader.cached(self, maxPixels: MediaLoader.displayPixels)
    }

    /// What the media viewer zooms into.
    func full() -> Signal<UIImage?, NoError> {
        return self.loader.image(self, maxPixels: MediaLoader.fullPixels)
    }

    /// The image as the server has it, for sending it again (an edited message keeps its photos).
    func data() -> Signal<Data?, NoError> {
        return self.loader.data(self)
    }
}

/// One server's images: fetched with `media.get` once, kept in Caches (entries never change, so neither do their
/// images), decoded downsampled. What it decodes it checks first: a known format, and a size a phone can hold, so a
/// tool's output cannot make the app decode a 30000-pixel image or something that is not one.
final class MediaLoader {
    static let displayPixels: CGFloat = 1280.0
    static let fullPixels: CGFloat = 4096.0
    /// Larger than this, an image is not decoded at all.
    private static let maxPixelCount = 80_000_000
    private static let types: Set<String> = ["public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp"]

    private let request: (String, JSONObject, @escaping (Result<JSONObject, RequestError>) -> Void) -> Void
    /// A kept file's bytes over HTTP (server/src/http-files.ts): an image the agent sent.
    var fetchFile: ((String, @escaping (Data?) -> Void) -> Void)?
    let directory: URL
    private let queue = Queue(name: "tau.media")
    private let decoded = NSCache<NSString, UIImage>()
    /// Fetches in flight, by key, with who waits for each; main queue.
    private var waiting: [String: [(Data?) -> Void]] = [:]

    init(namespace: String, request: @escaping (String, JSONObject, @escaping (Result<JSONObject, RequestError>) -> Void) -> Void) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let safe = namespace.replacingOccurrences(of: "[^A-Za-z0-9]", with: "_", options: .regularExpression)
        self.directory = base.appendingPathComponent("tau-media/\(safe)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.request = request
        self.decoded.totalCostLimit = 96 * 1024 * 1024
    }

    /// An image block of an entry: inline data decoded as before, a reference as one to fetch.
    func image(conversationId: Int, entryId: Int, index: Int, block: JSONObject) -> RemoteImage? {
        guard let media = block.object("media") else {
            return nil
        }
        var size: CGSize?
        if let width = media.double("width"), let height = media.double("height"), width > 0.0, height > 0.0 {
            size = CGSize(width: width, height: height)
        }
        return RemoteImage(conversationId: conversationId, entryId: entryId, index: media.int("index") ?? index, mimeType: block.string("mimeType") ?? "", bytes: media.int("bytes") ?? 0, pixelSize: size, loader: self)
    }

    /// An image the agent sent, by its file (server/src/send-file.ts): shown as the user's photos are.
    func fileImage(id: String, mimeType: String, bytes: Int, pixelSize: CGSize?) -> RemoteImage {
        return RemoteImage(conversationId: 0, entryId: 0, index: 0, mimeType: mimeType, bytes: bytes, pixelSize: pixelSize, loader: self, fileId: id)
    }

    private func file(_ key: String) -> URL {
        return self.directory.appendingPathComponent(key)
    }

    /// An image this phone sent: it has it already, so it is never fetched back.
    func seed(conversationId: Int, entryId: Int, index: Int, data: Data) {
        let url = self.file("\(conversationId)-\(entryId)-\(index)")
        self.queue.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func data(_ image: RemoteImage) -> Signal<Data?, NoError> {
        let key = image.key
        let url = self.file(key)
        return Signal { [weak self] subscriber in
            guard let self else {
                subscriber.putNext(nil)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let cancelled = Atomic<Bool>(value: false)
            self.queue.async {
                if let data = try? Data(contentsOf: url) {
                    subscriber.putNext(data)
                    subscriber.putCompletion()
                    return
                }
                Queue.mainQueue().async {
                    guard !cancelled.with({ $0 }) else {
                        return
                    }
                    self.fetch(image, key: key, url: url) { data in
                        subscriber.putNext(data)
                        subscriber.putCompletion()
                    }
                }
            }
            return ActionDisposable {
                let _ = cancelled.swap(true)
            }
        }
    }

    /// One `media.get` however many wait for it.
    private func fetch(_ image: RemoteImage, key: String, url: URL, completion: @escaping (Data?) -> Void) {
        if self.waiting[key] != nil {
            self.waiting[key]?.append(completion)
            return
        }
        self.waiting[key] = [completion]
        if image.isFile, let fileId = image.fileId {
            guard let fetchFile = self.fetchFile else {
                self.waiting[key] = nil
                completion(nil)
                return
            }
            fetchFile(fileId) { [weak self] data in
                guard let self else {
                    return
                }
                let waiting = self.waiting.removeValue(forKey: key) ?? []
                if let data {
                    self.queue.async {
                        try? data.write(to: url, options: .atomic)
                    }
                }
                for completion in waiting {
                    completion(data)
                }
            }
            return
        }
        self.request("media.get", ["conversationId": image.conversationId, "entryId": image.entryId, "index": image.index]) { [weak self] result in
            guard let self else {
                return
            }
            var data: Data?
            if case let .success(value) = result, let base64 = value.string("data") {
                data = Data(base64Encoded: base64)
            }
            let waiting = self.waiting.removeValue(forKey: key) ?? []
            if let data {
                self.queue.async {
                    try? data.write(to: url, options: .atomic)
                }
            }
            for completion in waiting {
                completion(data)
            }
        }
    }

    func cached(_ image: RemoteImage, maxPixels: CGFloat) -> UIImage? {
        return self.decoded.object(forKey: "\(image.key)@\(Int(maxPixels))" as NSString)
    }

    func image(_ image: RemoteImage, maxPixels: CGFloat) -> Signal<UIImage?, NoError> {
        let cacheKey = "\(image.key)@\(Int(maxPixels))" as NSString
        if let cached = self.decoded.object(forKey: cacheKey) {
            return .single(cached)
        }
        return self.data(image)
        |> mapToQueue { [weak self] data -> Signal<UIImage?, NoError> in
            guard let data else {
                return .single(nil)
            }
            return Signal { subscriber in
                self?.queue.async {
                    let decoded = MediaLoader.decode(data, maxPixels: maxPixels)
                    if let decoded {
                        self?.decoded.setObject(decoded, forKey: cacheKey, cost: Int(decoded.size.width * decoded.size.height * decoded.scale * decoded.scale * 4.0))
                    }
                    subscriber.putNext(decoded)
                    subscriber.putCompletion()
                }
                return EmptyDisposable
            }
        }
        |> deliverOnMainQueue
    }

    /// The image at most `maxPixels` on its long side, or nil when it is no image of a known format, or too large to
    /// decode. ImageIO reads the header first; the thumbnail decode never holds the full bitmap.
    static func decode(_ data: Data, maxPixels: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), let type = CGImageSourceGetType(source) as String?, MediaLoader.types.contains(type) else {
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0, width * height <= MediaLoader.maxPixelCount else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels, CGFloat(max(width, height))),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    var diskBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear() {
        self.decoded.removeAllObjects()
        let directory = self.directory
        self.queue.async {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
