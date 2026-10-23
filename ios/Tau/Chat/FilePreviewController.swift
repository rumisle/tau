import UIKit
import QuickLook
import UniformTypeIdentifiers

/// A file opened from the chat, as Telegram's DocumentPreviewController opens a document: Quick Look, with its share
/// button (Save to Files, other apps).
final class FilePreviewController: QLPreviewController, QLPreviewControllerDataSource {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        self.dataSource = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        return 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        return self.url as NSURL
    }
}

extension FileAttachment {
    /// A file picked on this device: its name, size and type from the file itself.
    init(local url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        self.init(name: url.lastPathComponent, size: Int64(values?.fileSize ?? 0), mimeType: type?.preferredMIMEType ?? "application/octet-stream", localURL: url)
    }
}
