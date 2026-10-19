// tau shim for Telegram's ChatSendMessageActionUI module (the long-press send menu: silent, scheduled, effects).
import Foundation
import UIKit
import Display
import ComponentFlow
import SwiftSignalKit

public enum ChatSendMessageContextScreenMediaPreviewLayoutType {
    case message
    case media
    case videoMessage
}

public protocol ChatSendMessageContextScreenMediaPreview: AnyObject {
    var isReady: Signal<Bool, NoError> { get }
    var view: UIView { get }
    var globalClippingRect: CGRect? { get }
    var layoutType: ChatSendMessageContextScreenMediaPreviewLayoutType { get }

    func animateIn(transition: ComponentTransition)
    func animateOut(transition: ComponentTransition)
    func animateOutOnSend(transition: ComponentTransition)
    func update(containerSize: CGSize, transition: ComponentTransition) -> CGSize
}
