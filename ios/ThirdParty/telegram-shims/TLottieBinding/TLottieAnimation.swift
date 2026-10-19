// tau shim for Telegram-iOS TLottieBinding, the Rust "tlottie" renderer, which needs a Rust toolchain to build. Telegram
// picks a backend through LottieRenderingSettings; tau always uses rlottie, so this one only has to compile: it keeps
// TLottieAnimation's interface and never loads.
import Foundation
import CoreGraphics

public enum TLottieFitzModifier: Int32 {
    case none
    case type12
    case type3
    case type4
    case type5
    case type6
}

public final class TLottieAnimation: NSObject {
    public let frameCount: Int32 = 0
    public let frameRate: Int32 = 0
    public let duration: Double = 0.0
    public let dimensions: CGSize = .zero

    public init?(data: Data, fitzModifier: TLottieFitzModifier, colorReplacements: [AnyHashable: Any]?) {
        return nil
    }

    public func renderFrame(with index: Int32, into buffer: UnsafeMutablePointer<UInt8>, width: Int32, height: Int32, bytesPerRow: Int32) {
    }
}
