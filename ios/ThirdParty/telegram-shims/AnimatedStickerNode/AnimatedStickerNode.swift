// tau shim for Telegram's AnimatedStickerNode module (TGS stickers through rlottie). The media picker shows one in its
// "no access" placeholder.
import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit

public protocol AnimatedStickerNodeSource {
}

public final class AnimatedStickerNodeLocalFileSource: AnimatedStickerNodeSource {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public enum AnimatedStickerPlaybackMode: Equatable {
    case once
    case loop
    case still(AnimatedStickerPlaybackPosition)
    case count(Int)
}

public enum AnimatedStickerPlaybackPosition: Equatable {
    case start
    case end
}

public enum AnimatedStickerMode {
    case cached
    case direct(cachePathPrefix: String?)
}

open class AnimatedStickerNode: ASDisplayNode {
    public var visibility: Bool = false

    open func setup(source: AnimatedStickerNodeSource, width: Int, height: Int, playbackMode: AnimatedStickerPlaybackMode = .loop, mode: AnimatedStickerMode) {
    }

    open func updateLayout(size: CGSize) {
    }

    open func play(firstFrame: Bool = false, fromIndex: Int? = nil) {
    }
}
