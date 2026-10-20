// tau shim for Telegram's TelegramCore module (its account, network and sync layer): only the value types the copied
// modules use, with Telegram's shapes. Nothing here talks to Telegram.
import Foundation
import UIKit
@_exported import Postbox
@_exported import SwiftSignalKit

public enum Namespaces {
    public enum Media {
        public static let CloudFile: Int32 = 1
        public static let LocalFile: Int32 = 2
        public static let CloudImage: Int32 = 3
    }

    public enum Peer {
        public static let CloudUser: Int32 = 0
    }
}

public enum EngineMedia {
    public typealias Id = MediaId
}

public final class CloudDocumentMediaResource: MediaResource {
    public let datacenterId: Int
    public let fileId: Int64
    public let accessHash: Int64
    public let size: Int64?
    public let fileReference: Data?
    public let fileName: String?

    public init(datacenterId: Int, fileId: Int64, accessHash: Int64, size: Int64?, fileReference: Data?, fileName: String?) {
        self.datacenterId = datacenterId
        self.fileId = fileId
        self.accessHash = accessHash
        self.size = size
        self.fileReference = fileReference
        self.fileName = fileName
    }

    public var id: MediaResourceId { MediaResourceId("telegram-cloud-document-\(self.datacenterId)-\(self.fileId)") }

    public func isEqual(to: MediaResource) -> Bool {
        return (to as? CloudDocumentMediaResource)?.fileId == self.fileId
    }
}

public final class CloudDocumentSizeMediaResource: MediaResource {
    public let datacenterId: Int32
    public let documentId: Int64
    public let accessHash: Int64
    public let sizeSpec: String
    public let fileReference: Data?

    public init(datacenterId: Int32, documentId: Int64, accessHash: Int64, sizeSpec: String, fileReference: Data?) {
        self.datacenterId = datacenterId
        self.documentId = documentId
        self.accessHash = accessHash
        self.sizeSpec = sizeSpec
        self.fileReference = fileReference
    }

    public var id: MediaResourceId { MediaResourceId("telegram-cloud-document-size-\(self.datacenterId)-\(self.documentId)-\(self.sizeSpec)") }
    public var size: Int64? { nil }

    public func isEqual(to: MediaResource) -> Bool {
        return (to as? CloudDocumentSizeMediaResource)?.id == self.id
    }
}

public final class LocalFileMediaResource: MediaResource {
    public let fileId: Int64
    public let size: Int64?

    public init(fileId: Int64, size: Int64? = nil) {
        self.fileId = fileId
        self.size = size
    }

    public var id: MediaResourceId { MediaResourceId("local-file-\(self.fileId)") }

    public func isEqual(to: MediaResource) -> Bool {
        return (to as? LocalFileMediaResource)?.fileId == self.fileId
    }
}

public struct TelegramMediaImageRepresentation: Equatable {
    public let dimensions: PixelDimensions
    public let resource: MediaResource
    public let progressiveSizes: [Int32]
    public let immediateThumbnailData: Data?
    public let hasVideo: Bool
    public let isPersonal: Bool

    public init(dimensions: PixelDimensions, resource: MediaResource, progressiveSizes: [Int32], immediateThumbnailData: Data?, hasVideo: Bool, isPersonal: Bool) {
        self.dimensions = dimensions
        self.resource = resource
        self.progressiveSizes = progressiveSizes
        self.immediateThumbnailData = immediateThumbnailData
        self.hasVideo = hasVideo
        self.isPersonal = isPersonal
    }

    public static func ==(lhs: TelegramMediaImageRepresentation, rhs: TelegramMediaImageRepresentation) -> Bool {
        return lhs.dimensions == rhs.dimensions && lhs.resource.isEqual(to: rhs.resource)
    }
}

public enum TelegramMediaFileAttribute {
    case FileName(fileName: String)
    case ImageSize(size: PixelDimensions)
    case Animated
    case CustomEmoji(isPremium: Bool, isSingleColor: Bool, alt: String, packReference: Any?)
}

public final class TelegramMediaFile: Media, Equatable {
    public let fileId: MediaId
    public let partialReference: Any?
    public let resource: MediaResource
    public let previewRepresentations: [TelegramMediaImageRepresentation]
    public let videoThumbnails: [Any]
    public let immediateThumbnailData: Data?
    public let mimeType: String
    public let size: Int64?
    public let attributes: [TelegramMediaFileAttribute]
    public let alternativeRepresentations: [Media]

    public init(fileId: MediaId, partialReference: Any?, resource: MediaResource, previewRepresentations: [TelegramMediaImageRepresentation], videoThumbnails: [Any], immediateThumbnailData: Data?, mimeType: String, size: Int64?, attributes: [TelegramMediaFileAttribute], alternativeRepresentations: [Media]) {
        self.fileId = fileId
        self.partialReference = partialReference
        self.resource = resource
        self.previewRepresentations = previewRepresentations
        self.videoThumbnails = videoThumbnails
        self.immediateThumbnailData = immediateThumbnailData
        self.mimeType = mimeType
        self.size = size
        self.attributes = attributes
        self.alternativeRepresentations = alternativeRepresentations
    }

    public var id: MediaId? { self.fileId }

    public var dimensions: PixelDimensions? {
        for attribute in self.attributes {
            if case let .ImageSize(size) = attribute {
                return size
            }
        }
        return nil
    }

    public var fileName: String? {
        for attribute in self.attributes {
            if case let .FileName(fileName) = attribute {
                return fileName
            }
        }
        return nil
    }

    public func isEqual(to other: Media) -> Bool {
        return (other as? TelegramMediaFile)?.fileId == self.fileId
    }

    public static func ==(lhs: TelegramMediaFile, rhs: TelegramMediaFile) -> Bool {
        return lhs.fileId == rhs.fileId
    }
}

// MARK: Wallpapers, as in TelegramCore/Sources/SyncCore/SyncCore_TelegramWallpaper.swift

public struct WallpaperSettings: Codable, Equatable {
    public var blur: Bool
    public var motion: Bool
    public var colors: [UInt32]
    public var intensity: Int32?
    public var rotation: Int32?
    public var emoticon: String?

    public init(blur: Bool = false, motion: Bool = false, colors: [UInt32] = [], intensity: Int32? = nil, rotation: Int32? = nil, emoticon: String? = nil) {
        self.blur = blur
        self.motion = motion
        self.colors = colors
        self.intensity = intensity
        self.rotation = rotation
        self.emoticon = emoticon
    }
}

public enum TelegramWallpaper: Equatable {
    public struct Gradient: Equatable {
        public var id: Int64?
        public var colors: [UInt32]
        public var settings: WallpaperSettings

        public init(id: Int64?, colors: [UInt32], settings: WallpaperSettings) {
            self.id = id
            self.colors = colors
            self.settings = settings
        }
    }

    public struct File: Equatable {
        public var id: Int64
        public var accessHash: Int64
        public var isCreator: Bool
        public var isDefault: Bool
        public var isPattern: Bool
        public var isDark: Bool
        public var slug: String
        public var file: TelegramMediaFile
        public var settings: WallpaperSettings

        public init(id: Int64, accessHash: Int64, isCreator: Bool, isDefault: Bool, isPattern: Bool, isDark: Bool, slug: String, file: TelegramMediaFile, settings: WallpaperSettings) {
            self.id = id
            self.accessHash = accessHash
            self.isCreator = isCreator
            self.isDefault = isDefault
            self.isPattern = isPattern
            self.isDark = isDark
            self.slug = slug
            self.file = file
            self.settings = settings
        }
    }

    case builtin(WallpaperSettings)
    case color(UInt32)
    case gradient(Gradient)
    case image([TelegramMediaImageRepresentation], WallpaperSettings)
    case file(File)
    case emoticon(String)

    public static func emoticonWallpaper(emoticon: String) -> TelegramWallpaper {
        return .emoticon(emoticon)
    }

    public var hasWallpaper: Bool {
        if case .color = self {
            return false
        }
        return true
    }

    public var settings: WallpaperSettings? {
        switch self {
        case let .builtin(settings), let .image(_, settings):
            return settings
        case let .file(file):
            return file.settings
        case let .gradient(gradient):
            return gradient.settings
        case .color, .emoticon:
            return nil
        }
    }

    public func isBasicallyEqual(to wallpaper: TelegramWallpaper) -> Bool {
        switch (self, wallpaper) {
        case (.builtin, .builtin):
            return true
        case let (.color(lhs), .color(rhs)):
            return lhs == rhs
        case let (.gradient(lhs), .gradient(rhs)):
            return lhs.colors == rhs.colors
        case let (.file(lhs), .file(rhs)):
            return lhs.slug == rhs.slug && lhs.settings.colors == rhs.settings.colors && lhs.settings.intensity == rhs.settings.intensity
        case let (.emoticon(lhs), .emoticon(rhs)):
            return lhs == rhs
        default:
            return self == wallpaper
        }
    }

    public func withUpdatedSettings(_ settings: WallpaperSettings) -> TelegramWallpaper {
        switch self {
        case .builtin:
            return .builtin(settings)
        case .color, .emoticon:
            return self
        case var .gradient(gradient):
            gradient.settings = settings
            return .gradient(gradient)
        case let .image(representations, _):
            return .image(representations, settings)
        case var .file(file):
            file.settings = settings
            return .file(file)
        }
    }
}

// MARK: Themes, as in TelegramCore/Sources/SyncCore/SyncCore_TelegramTheme.swift

public enum TelegramBaseTheme: Int32, Codable {
    case classic
    case day
    case night
    case tinted
}

public struct TelegramThemeSettings: Codable, Equatable {
    public var baseTheme: TelegramBaseTheme
    public var accentColor: UInt32
    public var outgoingAccentColor: UInt32?
    public var messageColors: [UInt32]
    public var animateMessageColors: Bool

    public init(baseTheme: TelegramBaseTheme, accentColor: UInt32, outgoingAccentColor: UInt32?, messageColors: [UInt32], animateMessageColors: Bool) {
        self.baseTheme = baseTheme
        self.accentColor = accentColor
        self.outgoingAccentColor = outgoingAccentColor
        self.messageColors = messageColors
        self.animateMessageColors = animateMessageColors
    }
}

public final class TelegramTheme: Equatable {
    public let id: Int64
    public let accessHash: Int64
    public let slug: String
    public let title: String
    public let emoticon: String?
    public let settings: [TelegramThemeSettings]?

    public init(id: Int64, accessHash: Int64, slug: String, title: String, emoticon: String?, settings: [TelegramThemeSettings]?) {
        self.id = id
        self.accessHash = accessHash
        self.slug = slug
        self.title = title
        self.emoticon = emoticon
        self.settings = settings
    }

    public static func ==(lhs: TelegramTheme, rhs: TelegramTheme) -> Bool {
        return lhs.id == rhs.id && lhs.title == rhs.title && lhs.settings == rhs.settings
    }
}

// MARK: Payments

public struct StarsAmount: Equatable, Hashable, Comparable {
    public static let zero = StarsAmount(value: 0, nanos: 0)

    public var value: Int64
    public var nanos: Int32

    public init(value: Int64, nanos: Int32) {
        self.value = value
        self.nanos = nanos
    }

    public var stringValue: String {
        return "\(self.value)"
    }

    public static func <(lhs: StarsAmount, rhs: StarsAmount) -> Bool {
        return (lhs.value, lhs.nanos) < (rhs.value, rhs.nanos)
    }
}

/// A Telegram collectible. Themes carry one optionally; tau never sets it.
public enum StarGift: Equatable {
}

// MARK: Reactions

public struct MessageReaction: Equatable {
    public enum Reaction: Hashable, Comparable, Codable {
        case builtin(String)
        case custom(Int64)
        case stars

        public static func <(lhs: Reaction, rhs: Reaction) -> Bool {
            switch (lhs, rhs) {
            case let (.builtin(l), .builtin(r)):
                return l < r
            case let (.custom(l), .custom(r)):
                return l < r
            case (.builtin, _):
                return true
            default:
                return false
            }
        }
    }

    public var value: Reaction
    public var count: Int32
    public var chosenOrder: Int?

    public init(value: Reaction, count: Int32, chosenOrder: Int?) {
        self.value = value
        self.count = count
        self.chosenOrder = chosenOrder
    }
}

/// Telegram's network connection. tau has none; the type exists for signatures.
public final class Network {
}

public typealias EngineItemCollectionId = ItemCollectionId

public enum MediaResourceUserLocation: Equatable {
    case other
    case peer(PeerId)
}

public enum UpdateMessageReaction {
    case builtin(String)
    case custom(fileId: Int64, file: TelegramMediaFile?)
    case stars

    public var reaction: MessageReaction.Reaction {
        switch self {
        case let .builtin(value):
            return .builtin(value)
        case let .custom(fileId, _):
            return .custom(fileId)
        case .stars:
            return .stars
        }
    }
}

public struct MessageTextEntity: Equatable {
    public enum EntityType: Equatable {
        case Bold
        case Italic
        case Code
        case Pre(language: String?)
        case Url
        case TextUrl(url: String)
        case Strikethrough
        case Underline
        case Spoiler
        case CustomEmoji(stickerPack: ItemCollectionId?, fileId: Int64)
        case BlockQuote(isCollapsed: Bool)
    }

    public var range: Range<Int>
    public var type: EntityType

    public init(range: Range<Int>, type: EntityType) {
        self.range = range
        self.type = type
    }
}

/// A signed-in Telegram account. tau has none; the type exists for signatures.
public final class Account {
    public let postbox = Postbox()
    public let peerId = PeerId(namespace: 0, id: 0)

    public init() {}
}

public struct EngineMediaResource: Equatable {
    public struct Id: Hashable {
        public var stringRepresentation: String

        public init(_ stringRepresentation: String) {
            self.stringRepresentation = stringRepresentation
        }
    }

    private let resource: MediaResource

    public init(_ resource: MediaResource) {
        self.resource = resource
    }

    public var id: Id {
        return Id(self.resource.id.stringRepresentation)
    }

    public func _asResource() -> MediaResource {
        return self.resource
    }

    public static func ==(lhs: EngineMediaResource, rhs: EngineMediaResource) -> Bool {
        return lhs.resource.isEqual(to: rhs.resource)
    }
}

/// A chat partner. tau's agent conversations are none of Telegram's peers; the media picker only asks whether one is
/// a secret chat.
public enum EnginePeer: Equatable {
    case user(PeerId)
    case legacyGroup(PeerId)
    case channel(PeerId)
    case secretChat(PeerId)

    public typealias Id = PeerId

    public var id: PeerId {
        switch self {
        case let .user(id), let .legacyGroup(id), let .channel(id), let .secretChat(id):
            return id
        }
    }
}

public enum EngineMessage: Equatable {
    public typealias Id = MessageId

    /// tau has no Telegram messages, so no value exists.
    public var timestamp: Int32 {
        switch self {}
    }
}

extension EnginePeerIdValue {
    public init(_ value: Int64) {
        self.init(namespace: 0, id: value)
    }
}

extension Namespaces {
    public enum Message {
        public static let Cloud: Int32 = 0
        public static let Local: Int32 = 1
    }
}

extension Namespaces.Peer {
    public static let SecretChat: Int32 = 3
}

/// An attachment-menu bot (a mini app in the attachment menu). tau has none.
public struct AttachMenuBot: Equatable {
    public struct Peer: Equatable {
        public var id: PeerId
        public var compactDisplayTitle: String
    }

    public let peer: Peer
    public let shortName: String

    public init(peer: Peer, shortName: String) {
        self.peer = peer
        self.shortName = shortName
    }
}

public enum FileMediaReference {
    case standalone(media: TelegramMediaFile)

    public var media: TelegramMediaFile {
        switch self {
        case let .standalone(media):
            return media
        }
    }
}

public struct LimitsConfiguration: Equatable {
    public static let defaultValue = LimitsConfiguration()

    public var maxMessageEditingInterval: Int32 = 2 * 24 * 60 * 60
    public var maxMediaCaptionLength: Int32 = 1024

    public init() {}
}

public struct AppConfiguration {
    public var data: [String: Any]?

    public static let defaultValue = AppConfiguration(data: nil)

    public init(data: [String: Any]?) {
        self.data = data
    }
}

/// A scheduled message's time that means "when the recipient comes online".
public let scheduleWhenOnlineTimestamp: Int32 = 0x7ffffffe
