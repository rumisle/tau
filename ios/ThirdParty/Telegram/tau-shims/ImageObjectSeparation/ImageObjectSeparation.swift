// tau shim for Telegram's ImageObjectSeparation module (cutting a subject out of a photo, for stickers).
import Foundation
import SwiftSignalKit
import AccountContext

public enum CutoutAvailability {
    case available
    case progress(Float)
    case unavailable
}

public func cutoutAvailability(context: AccountContext) -> Signal<CutoutAvailability, NoError> {
    return .single(.unavailable)
}
