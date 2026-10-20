import Foundation
import UIKit
import Display
import ContextUI
import ContextControllerImpl
import ContextMenuScreen

/// Telegram's interface modules declare factories that the app fills in at launch, so interfaces (ContextUI) do not
/// depend on implementations (ContextControllerImpl). As in TelegramUI/Sources/AppDelegate.swift.
func installTelegramComponentFactories() {
    // The dark pill menu over selected text (TextSelectionNode's Copy / Share / Look Up).
    setContextMenuControllerProvider { arguments in
        return ContextMenuControllerImpl(arguments)
    }
    makeContextControllerImpl = { context, presentationData, configuration, recognizer, gesture, workaroundUseLegacyImplementation, disableScreenshots, hideReactionPanelTail in
        return ContextControllerImpl(
            context: context,
            presentationData: presentationData,
            configuration: configuration,
            recognizer: recognizer,
            gesture: gesture,
            workaroundUseLegacyImplementation: workaroundUseLegacyImplementation,
            disableScreenshots: disableScreenshots,
            hideReactionPanelTail: hideReactionPanelTail
        )
    }
    makeContextControllerActionsStackNodeImpl = { context, getController, requestDismiss, requestUpdate in
        return ContextControllerActionsStackNodeImpl(
            context: context,
            getController: getController,
            requestDismiss: requestDismiss,
            requestUpdate: requestUpdate
        )
    }
    makeContextControllerActionsListStackItemImpl = { id, items, reactionItems, previewReaction, tip, tipSignal, dismissed in
        return ContextControllerActionsListStackItem(
            id: id,
            items: items,
            reactionItems: reactionItems,
            previewReaction: previewReaction,
            tip: tip,
            tipSignal: tipSignal,
            dismissed: dismissed
        )
    }
    makeContextActionNodeImpl = { presentationData, action, getController, actionSelected, requestLayout, requestUpdateAction in
        return ContextActionNode(
            presentationData: presentationData,
            action: action,
            getController: getController,
            actionSelected: actionSelected,
            requestLayout: requestLayout,
            requestUpdateAction: requestUpdateAction
        )
    }
    makePeekControllerImpl = { presentationData, content, sourceView, activateImmediately in
        return PeekControllerImpl(
            presentationData: presentationData,
            content: content,
            sourceView: sourceView,
            activateImmediately: activateImmediately
        )
    }
    makePinchControllerImpl = { sourceNode, disableScreenshots, getContentAreaInScreenSpace in
        return PinchControllerImpl(
            sourceNode: sourceNode,
            disableScreenshots: disableScreenshots,
            getContentAreaInScreenSpace: getContentAreaInScreenSpace
        )
    }
}
