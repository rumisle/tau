import Foundation

/// A user message's files as the server names them for the model, in its first text block (server/src/attachments.ts):
///
///     <attachments>
///     <image name="/…/tau.files/7f3a…/IMG_2041.jpg" type="image/jpeg" bytes="812044" width="2000" height="1500"/>
///     <file name="/…/tau.files/a81c…/report.pdf" type="application/pdf" bytes="1204331"/>
///     </attachments>
///
/// An `<image>` is also in the message as an image block, in the same order; a `<file>` only named. The chat shows the
/// files, not the block.
struct AttachmentLine: Equatable {
    enum Kind: String {
        case image
        case file
    }

    let kind: Kind
    let path: String
    let mimeType: String
    let bytes: Int64
    let pixelSize: CGSize?

    /// The file's name: its path's last component.
    var name: String {
        return (self.path as NSString).lastPathComponent
    }

    /// The server's ID: the directory the file is kept in.
    var fileId: String? {
        let directory = ((self.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return directory.count == 32 && directory.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) ? directory : nil
    }

    var file: FileAttachment {
        return FileAttachment(name: self.name, size: self.bytes, mimeType: self.mimeType, serverId: self.fileId, pixelSize: self.pixelSize)
    }

    private static let open = "<attachments>\n"
    private static let close = "\n</attachments>"
    private static let line = try! NSRegularExpression(pattern: "^<(image|file) name=\"([^\"]*)\" type=\"([^\"]*)\" bytes=\"(\\d+)\"(?: width=\"(\\d+)\" height=\"(\\d+)\")?/>$")

    /// The lines of a block, when `text` is exactly one; nil for any other text.
    static func parse(_ text: String) -> [AttachmentLine]? {
        guard text.hasPrefix(AttachmentLine.open), text.hasSuffix(AttachmentLine.close), text.count > AttachmentLine.open.count + AttachmentLine.close.count else {
            return nil
        }
        let body = String(text.dropFirst(AttachmentLine.open.count).dropLast(AttachmentLine.close.count))
        var lines: [AttachmentLine] = []
        for part in body.components(separatedBy: "\n") {
            let range = NSRange(part.startIndex..., in: part)
            guard let match = AttachmentLine.line.firstMatch(in: part, range: range) else {
                return nil
            }
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : Range(range, in: part).map { String(part[$0]) }
            }
            guard let kind = group(1).flatMap(Kind.init(rawValue:)), let path = group(2), let type = group(3), let bytes = group(4).flatMap({ Int64($0) }) else {
                return nil
            }
            var size: CGSize?
            if let width = group(5).flatMap(Double.init), let height = group(6).flatMap(Double.init), width > 0.0, height > 0.0 {
                size = CGSize(width: width, height: height)
            }
            lines.append(AttachmentLine(kind: kind, path: unescape(path), mimeType: unescape(type), bytes: bytes, pixelSize: size))
        }
        return lines
    }

    private static func unescape(_ value: String) -> String {
        return value.replacingOccurrences(of: "&#10;", with: "\n").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }
}
