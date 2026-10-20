// tau shim for Telegram's UndoUI module (the toast at the top or bottom of the screen). Context menus check for one to
// dismiss it; tau shows its own toasts.
import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext

public enum UndoOverlayContent {
    case sticker(context: AccountContext, file: TelegramMediaFile, loop: Bool, title: String?, text: String, undoText: String?, customAction: (() -> Void)?)
    case image(image: UIImage, title: String?, text: String, round: Bool, undoText: String?)
    case info(title: String?, text: String, timeout: Double?, customUndoText: String?)
    case hidArchive(title: String, text: String, undo: Bool)
}

public enum UndoOverlayAction {
    case info
    case undo
    case commit
}

public final class UndoOverlayController: ViewController {
    public enum Position {
        case top
        case bottom
    }

    public var content: UndoOverlayContent

    public init(presentationData: PresentationData, content: UndoOverlayContent, elevatedLayout: Bool, position: Position = .bottom, animateInAsReplacement: Bool = false, action: @escaping (UndoOverlayAction) -> Bool) {
        self.content = content
        super.init(navigationBarPresentationData: nil)
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func dismissWithCommitAction() {
        self.dismiss()
    }
}
