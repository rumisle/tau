// tau shim for Telegram's EntityKeyboard module (the emoji, sticker and GIF keyboard). Context menus reference its
// content type for the expanded reaction picker, which tau never shows.
import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramCore

public final class EmojiPagerContentComponent: Component {
    public final class Item {
        public enum Icon: Equatable {
            case none
            case locked
            case premium
            case text(String)
            case customFile(TelegramMediaFile)
        }
    }

    public static func ==(lhs: EmojiPagerContentComponent, rhs: EmojiPagerContentComponent) -> Bool {
        return lhs === rhs
    }

    public final class View: UIView {
        func update(component: EmojiPagerContentComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
            return availableSize
        }
    }

    public func makeView() -> View {
        return View()
    }

    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}
