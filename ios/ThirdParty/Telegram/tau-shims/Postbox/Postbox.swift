// tau shim for Telegram's Postbox module (its database): only the value types the copied modules use.
import Foundation
import CoreGraphics

public typealias PeerId = EnginePeerIdValue

public struct EnginePeerIdValue: Hashable, Comparable {
    public let namespace: Int32
    public let id: Int64

    public init(namespace: Int32, id: Int64) {
        self.namespace = namespace
        self.id = id
    }

    public static func <(lhs: EnginePeerIdValue, rhs: EnginePeerIdValue) -> Bool {
        return (lhs.namespace, lhs.id) < (rhs.namespace, rhs.id)
    }
}

public struct MediaId: Hashable, Comparable, CustomStringConvertible {
    public typealias Namespace = Int32
    public typealias Id = Int64

    public let namespace: Int32
    public let id: Int64

    public init(namespace: Int32, id: Int64) {
        self.namespace = namespace
        self.id = id
    }

    public var description: String {
        return "\(self.namespace):\(self.id)"
    }

    public static func <(lhs: MediaId, rhs: MediaId) -> Bool {
        return (lhs.namespace, lhs.id) < (rhs.namespace, rhs.id)
    }
}

public struct MessageId: Hashable, Comparable {
    public let peerId: PeerId
    public let namespace: Int32
    public let id: Int32

    public init(peerId: PeerId, namespace: Int32, id: Int32) {
        self.peerId = peerId
        self.namespace = namespace
        self.id = id
    }

    public static func <(lhs: MessageId, rhs: MessageId) -> Bool {
        return (lhs.peerId, lhs.namespace, lhs.id) < (rhs.peerId, rhs.namespace, rhs.id)
    }
}

public struct PixelDimensions: Hashable {
    public let width: Int32
    public let height: Int32

    public init(width: Int32, height: Int32) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        self.init(width: Int32(size.width), height: Int32(size.height))
    }

    public var cgSize: CGSize {
        return CGSize(width: CGFloat(self.width), height: CGFloat(self.height))
    }
}

public struct MediaResourceId: Hashable, CustomStringConvertible {
    public let stringRepresentation: String

    public init(_ stringRepresentation: String) {
        self.stringRepresentation = stringRepresentation
    }

    public var description: String {
        return self.stringRepresentation
    }
}

public protocol MediaResource: AnyObject {
    var id: MediaResourceId { get }
    var size: Int64? { get }
    func isEqual(to: MediaResource) -> Bool
}

public final class EmptyMediaResource: MediaResource {
    public init() {}
    public var id: MediaResourceId { MediaResourceId("empty") }
    public var size: Int64? { nil }
    public func isEqual(to: MediaResource) -> Bool { to is EmptyMediaResource }
}

public final class MediaResourceData {
    public let path: String
    public let offset: Int64
    public let size: Int64
    public let complete: Bool

    public init(path: String, offset: Int64, size: Int64, complete: Bool) {
        self.path = path
        self.offset = offset
        self.size = size
        self.complete = complete
    }
}

/// Telegram's media cache. tau has none; the type exists for signatures.
public final class MediaBox {
    public init() {}
}

public protocol Media: AnyObject {
    var id: MediaId? { get }
    func isEqual(to other: Media) -> Bool
}

public typealias PreferencesEntry = Any

public struct ItemCollectionId: Hashable {
    public let namespace: Int32
    public let id: Int64

    public init(namespace: Int32, id: Int64) {
        self.namespace = namespace
        self.id = id
    }
}
