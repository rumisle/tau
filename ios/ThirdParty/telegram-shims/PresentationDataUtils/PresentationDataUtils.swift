// tau shim for Telegram's PresentationDataUtils module: what the media picker uses, as in PresentationDataUtils.
import Foundation
import UIKit
import Display
import TelegramPresentationData
import SolidRoundedButtonNode

public extension SolidRoundedButtonTheme {
    convenience init(theme: PresentationTheme) {
        self.init(backgroundColor: theme.list.itemCheckColors.fillColor, backgroundColors: [], foregroundColor: theme.list.itemCheckColors.foregroundColor, disabledBackgroundColor: theme.list.plainBackgroundColor.mixedWith(theme.list.itemDisabledTextColor, alpha: 0.15), disabledForegroundColor: theme.list.itemDisabledTextColor)
    }
}

import SwiftSignalKit
import AccountContext

/// As in PresentationDataUtils/Sources/AlertTheme.swift, on Display's text alert.
public func textAlertController(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)? = nil, forceTheme: PresentationTheme? = nil, title: String?, text: String, actions: [TextAlertAction], actionLayout: TextAlertContentActionLayout = .horizontal, allowInputInset: Bool = true, parseMarkdown: Bool = false, dismissOnOutsideTap: Bool = true, linkAction: (([NSAttributedString.Key: Any], Int) -> Void)? = nil) -> ViewController {
    var presentationData = updatedPresentationData?.initial ?? context.sharedContext.currentPresentationData.with { $0 }
    if let forceTheme {
        presentationData = presentationData.withUpdated(theme: forceTheme)
    }
    let theme = AlertControllerTheme(presentationData: presentationData)
    // As Telegram's: standardTextAlertController, whose actions dismiss the alert before they run.
    return standardTextAlertController(theme: theme, title: title, text: text, actions: actions, actionLayout: actionLayout, allowInputInset: allowInputInset, parseMarkdown: parseMarkdown, dismissOnOutsideTap: dismissOnOutsideTap, linkAction: linkAction)
}
