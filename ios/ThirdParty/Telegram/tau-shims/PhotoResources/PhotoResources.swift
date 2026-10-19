// tau shim for Telegram's PhotoResources module: only the API the copied modules use.
import Foundation
import UIKit

import Accelerate
import Display

// As in PhotoResources/Sources/PhotoResources.swift.
public func adjustSaturationInContext(context: DrawingContext, saturation: CGFloat) {
    var buffer = vImage_Buffer()
    buffer.data = context.bytes
    buffer.width = UInt(context.size.width * context.scale)
    buffer.height = UInt(context.size.height * context.scale)
    buffer.rowBytes = context.bytesPerRow

    let divisor: Int32 = 0x1000

    let rwgt: CGFloat = 0.3086
    let gwgt: CGFloat = 0.6094
    let bwgt: CGFloat = 0.0820

    let adjustSaturation = saturation

    let a = (1.0 - adjustSaturation) * rwgt + adjustSaturation
    let b = (1.0 - adjustSaturation) * rwgt
    let c = (1.0 - adjustSaturation) * rwgt
    let d = (1.0 - adjustSaturation) * gwgt
    let e = (1.0 - adjustSaturation) * gwgt + adjustSaturation
    let f = (1.0 - adjustSaturation) * gwgt
    let g = (1.0 - adjustSaturation) * bwgt
    let h = (1.0 - adjustSaturation) * bwgt
    let i = (1.0 - adjustSaturation) * bwgt + adjustSaturation

    let satMatrix: [CGFloat] = [
        a, b, c, 0,
        d, e, f, 0,
        g, h, i, 0,
        0, 0, 0, 1
    ]

    var matrix: [Int16] = satMatrix.map { value in
        return Int16(value * CGFloat(divisor))
    }

    vImageMatrixMultiply_ARGB8888(&buffer, &buffer, &matrix, divisor, nil, nil, vImage_Flags(kvImageDoNotTile))
}
