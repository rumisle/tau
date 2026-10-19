// tau shim for Telegram's AlertComponent module: AlertScreen on Display's own text alert (AlertController), which
// tau copies.
import Foundation
import UIKit
import Display
import TelegramPresentationData
import AccountContext

open class AlertScreen: AlertController {
    public struct Action {
        public enum ActionType {
            case generic
            case `default`
            case destructive
            case defaultDestructive
        }

        public let title: String
        public let type: ActionType
        public let action: () -> Void

        public init(title: String, type: ActionType = .generic, action: @escaping () -> Void = {}) {
            self.title = title
            self.type = type
            self.action = action
        }
    }

    public init(context: AccountContext, title: String?, text: String, actions: [Action]) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let theme = AlertControllerTheme(presentationData: presentationData)
        var controller: AlertController?
        let mapped = actions.map { action -> TextAlertAction in
            let type: TextAlertActionType
            switch action.type {
            case .generic:
                type = .genericAction
            case .default:
                type = .defaultAction
            case .destructive:
                type = .destructiveAction
            case .defaultDestructive:
                type = .defaultDestructiveAction
            }
            return TextAlertAction(type: type, title: action.title, action: {
                controller?.dismissAnimated()
                action.action()
            })
        }
        let attributedTitle = title.map { NSAttributedString(string: $0, font: Font.semibold(17.0), textColor: theme.primaryColor) }
        let contentNode = TextAlertContentNode(theme: theme, title: attributedTitle, text: NSAttributedString(string: text, font: Font.regular(13.0), textColor: theme.primaryColor, paragraphAlignment: .center), actions: mapped, actionLayout: .horizontal, dismissOnOutsideTap: true)
        super.init(theme: theme, contentNode: contentNode)
        controller = self
    }

    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
