// tau shim for Telegram's LegacyMediaPickerUI module: its item generator turns LegacyComponents' picked assets into
// send descriptions. tau reads the selection itself, so the generator passes the item through.
import Foundation
import UIKit

public func legacyAssetPickerItemGenerator() -> ((Any?, NSAttributedString?, String?, String?) -> [AnyHashable: Any]?) {
    return { anyDict, caption, hash, uniqueId in
        var result: [AnyHashable: Any] = [:]
        if let dict = anyDict as? [AnyHashable: Any] {
            result = dict
        }
        if let caption {
            result["caption"] = caption
        }
        return result
    }
}
