// tau shim for Telegram's Camera module (the modern camera of stories and avatars). The attachment menu's camera tile
// is LegacyComponents' TGAttachmentCameraView, which tau copies; these types keep the picker's other modes compiling.
import Foundation
import UIKit
import SwiftSignalKit

public protocol CameraProtocol: AnyObject {
    func startCapture()
    func stopCapture(invalidate: Bool)
}

public protocol CameraSimplePreviewView: UIView {
    var isPreviewing: Signal<Bool, NoError> { get }
    var isEnabled: Bool { get set }
    func resetPlaceholder(front: Bool)
    func removePlaceholder(delay: Double)
}

public final class Camera {
    public enum Position: Equatable {
        case back
        case front
        case unspecified
    }
}

public final class CameraHolder {
    public let camera: CameraProtocol
    public let previewView: CameraSimplePreviewView
    public let parentView: UIView
    public let restore: () -> Void

    public init(camera: CameraProtocol, previewView: CameraSimplePreviewView, parentView: UIView, restore: @escaping () -> Void) {
        self.camera = camera
        self.previewView = previewView
        self.parentView = parentView
        self.restore = restore
    }
}
