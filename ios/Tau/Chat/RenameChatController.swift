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

/// A field of `fieldsAlertController`.
struct AlertField {
    var placeholder: String
    var value: String?
    var isSecure = false
    var keyboardType: UIKeyboardType = .default
    /// URLs, tokens and names: typed as they are, without capitals or corrections.
    var isVerbatim = false
}

/// Telegram's alert with several fields, from voiceChatUserNameController (TelegramCallsUI): Return moves to the next
/// field and Done on the last one applies. `apply` gets the trimmed values and returns false to shake the alert, as
/// Telegram's does for a wrong value, instead of closing it.
func fieldsAlertController(context: AccountContext, presentationData: PresentationData, title: String, text: String?, fields: [AlertField], doneTitle: String? = nil, apply: @escaping ([String]) -> Bool) -> ViewController {
    let strings = presentationData.strings
    let states = fields.map { _ in AlertInputFieldComponent.ExternalState() }
    var content: [AnyComponentWithIdentity<AlertComponentEnvironment>] = [
        AnyComponentWithIdentity(id: "title", component: AnyComponent(AlertTitleComponent(title: title))),
    ]
    if let text {
        content.append(AnyComponentWithIdentity(id: "text", component: AnyComponent(AlertTextComponent(content: .plain(text)))))
    }
    var applyImpl: (() -> Void)?
    for (index, field) in fields.enumerated() {
        let isLast = index == fields.count - 1
        content.append(AnyComponentWithIdentity(
            id: "field\(index)",
            component: AnyComponent(
                AlertInputFieldComponent(
                    context: context,
                    initialValue: field.value,
                    placeholder: field.placeholder,
                    hasClearButton: true,
                    isSecureTextEntry: field.isSecure,
                    returnKeyType: isLast ? .done : .next,
                    keyboardType: field.keyboardType,
                    autocapitalizationType: field.isVerbatim ? .none : .sentences,
                    autocorrectionType: field.isVerbatim ? .no : .default,
                    isInitiallyFocused: index == 0,
                    externalState: states[index],
                    returnKeyAction: {
                        if isLast {
                            applyImpl?()
                        } else {
                            states[index + 1].activateInput()
                        }
                    }
                )
            )
        ))
    }
    var dismissImpl: (() -> Void)?
    let alertController = AlertScreen(
        configuration: AlertScreen.Configuration(allowInputInset: true),
        content: content,
        actions: [
            .init(title: strings.Common_Cancel),
            .init(title: doneTitle ?? strings.Common_Done, type: .default, action: {
                applyImpl?()
            }, autoDismiss: false)
        ],
        updatedPresentationData: (presentationData, .single(presentationData))
    )
    applyImpl = {
        let values = states.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if apply(values) {
            dismissImpl?()
        } else {
            states.first?.animateError()
        }
    }
    dismissImpl = { [weak alertController] in
        alertController?.dismiss()
    }
    return alertController
}
