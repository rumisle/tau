import Foundation
import UIKit
import SwiftSignalKit
import Display
import TelegramPresentationData
import AccountContext
import ComponentFlow
import AlertComponent
import AlertInputFieldComponent

/// The longest title a rename takes; the server refuses longer ones.
let maxChatTitleLength = 64

/// Rename Chat: Telegram's alert with a text field, from voiceChatTitleEditController (TelegramCallsUI), which edits a
/// voice chat's title the same way. `apply` gets the new title, or nothing when it is empty or unchanged.
func renameChatController(context: AccountContext, presentationData: PresentationData, title: String, apply: @escaping (String) -> Void) -> ViewController {
    let strings = presentationData.strings
    let inputState = AlertInputFieldComponent.ExternalState()

    var content: [AnyComponentWithIdentity<AlertComponentEnvironment>] = []
    content.append(AnyComponentWithIdentity(
        id: "title",
        component: AnyComponent(
            AlertTitleComponent(title: "Rename Chat")
        )
    ))
    content.append(AnyComponentWithIdentity(
        id: "text",
        component: AnyComponent(
            AlertTextComponent(content: .plain("Enter a new name for this chat."))
        )
    ))

    var applyImpl: (() -> Void)?
    content.append(AnyComponentWithIdentity(
        id: "input",
        component: AnyComponent(
            AlertInputFieldComponent(
                context: context,
                initialValue: title,
                placeholder: "Name",
                characterLimit: maxChatTitleLength,
                hasClearButton: true,
                isInitiallyFocused: true,
                externalState: inputState,
                returnKeyAction: {
                    applyImpl?()
                }
            )
        )
    ))

    var dismissImpl: (() -> Void)?
    let alertController = AlertScreen(
        configuration: AlertScreen.Configuration(allowInputInset: true),
        content: content,
        actions: [
            .init(title: strings.Common_Cancel),
            .init(title: strings.Common_Done, type: .default, action: {
                applyImpl?()
            }, autoDismiss: false)
        ],
        updatedPresentationData: (presentationData, .single(presentationData))
    )
    applyImpl = {
        let newValue = inputState.value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if !newValue.isEmpty && newValue != title {
            apply(newValue)
        }
        dismissImpl?()
    }
    dismissImpl = { [weak alertController] in
        alertController?.dismiss()
    }
    return alertController
}
