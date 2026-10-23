import UIKit
import Photos
import Display
import SwiftSignalKit
import SSignalKit
import TelegramPresentationData
import AccountContext
import AttachmentUI
import MediaPickerUI
import LegacyComponents

/// What the attachment menu produced: photos with an optional caption, or a request for the file or camera picker.
enum TelegramAttachmentResult {
    case photos([UIImage], caption: String)
    case files
    case camera
}

/// Telegram's attachment menu (AttachmentUI's AttachmentController with MediaPickerUI's MediaPickerScreenImpl, both
/// copied), as ChatControllerOpenAttachmentMenu presents it: a glass sheet with the photo grid and its camera tile,
/// the tab bar of Gallery and File, and the caption field once photos are selected. What is written in the chat's field
/// becomes the caption (`initialCaption`, as ChatControllerOpenAttachmentMenu's `setCaption(inputText)`); `captionChanged`
/// hears it as it is edited, so a menu closed without sending can give it back.
func makeTelegramAttachmentMenu(context: TauAccountContext, presentationData: PresentationData, initialCaption: String = "", captionChanged: @escaping (String) -> Void = { _ in }, completion: @escaping (TelegramAttachmentResult) -> Void) -> AttachmentController {
    let updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>) = (presentationData, .single(presentationData))
    let controller = AttachmentController(context: context, updatedPresentationData: updatedPresentationData, style: .glass, chatLocation: nil, buttons: [.gallery, .file], initialButton: .gallery)
    controller.requestController = { [weak controller] type, present in
        switch type {
        case .gallery:
            let picker = MediaPickerScreenImpl(context: context, updatedPresentationData: updatedPresentationData, style: .glass, peer: nil, threadTitle: nil, chatLocation: nil, enableMultiselection: true, subject: .assets(nil, .default))
            picker.openCamera = { [weak controller] _ in
                controller?.dismiss(animated: true)
                completion(.camera)
            }
            picker.legacyCompletion = { _, signals, _, _, _, _, sendCompletion in
                resolveLegacyMediaSignals(signals, completion: { images, caption in
                    sendCompletion()
                    completion(.photos(images, caption: caption))
                })
            }
            var pickerContext = picker.mediaPickerContext
            if let base = pickerContext {
                if !initialCaption.isEmpty {
                    base.setCaption(NSAttributedString(string: initialCaption))
                }
                // The menu gives the picker each keystroke of the caption through its context.
                pickerContext = CaptionObservingPickerContext(base: base, captionChanged: captionChanged)
            }
            present(picker, pickerContext)
            return true
        case .file:
            controller?.dismiss(animated: true)
            completion(.files)
            return false
        default:
            return false
        }
    }
    return controller
}

/// The picker sends LegacyComponents result signals (TGMediaAssetsController.resultSignalsForSelectionContext), each
/// with a dictionary: an edited photo carries its image, a library photo its asset, which is loaded here at the size the
/// model gets.
private func resolveLegacyMediaSignals(_ signals: [Any], completion: @escaping ([UIImage], String) -> Void) {
    let group = DispatchGroup()
    var images: [Int: UIImage] = [:]
    var caption = ""
    let lock = NSLock()
    for (index, item) in signals.enumerated() {
        guard let signal = item as? SSignal else {
            continue
        }
        group.enter()
        var finished = false
        let finish = {
            if !finished {
                finished = true
                group.leave()
            }
        }
        _ = signal.start(next: { value in
            guard let dict = value as? [AnyHashable: Any] else {
                return
            }
            if let text = (dict["caption"] as? NSAttributedString)?.string, !text.isEmpty {
                lock.lock()
                caption = text
                lock.unlock()
            }
            if let image = dict["image"] as? UIImage {
                lock.lock()
                images[index] = image
                lock.unlock()
                finish()
            } else if let asset = dict["asset"] as? TGMediaAsset, let phAsset = asset.backingAsset {
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = true
                options.isSynchronous = false
                PHImageManager.default().requestImage(for: phAsset, targetSize: CGSize(width: ImageEncoding.maxPixels, height: ImageEncoding.maxPixels), contentMode: .aspectFit, options: options) { image, _ in
                    lock.lock()
                    images[index] = image ?? (dict["previewImage"] as? UIImage)
                    lock.unlock()
                    finish()
                }
            } else if let image = dict["previewImage"] as? UIImage {
                lock.lock()
                images[index] = image
                lock.unlock()
                finish()
            }
        }, error: { _ in
            finish()
        }, completed: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                finish()
            }
        })
    }
    group.notify(queue: .main) {
        completion(images.keys.sorted().compactMap { images[$0] }, caption)
    }
}

/// The picker's context, telling `captionChanged` each caption the menu sets.
private final class CaptionObservingPickerContext: AttachmentMediaPickerContext {
    private let base: AttachmentMediaPickerContext
    private let captionChanged: (String) -> Void

    init(base: AttachmentMediaPickerContext, captionChanged: @escaping (String) -> Void) {
        self.base = base
        self.captionChanged = captionChanged
    }

    var selectionCount: Signal<Int, NoError> { self.base.selectionCount }
    var caption: Signal<NSAttributedString?, NoError> { self.base.caption }
    var hasCaption: Bool { self.base.hasCaption }
    var captionIsAboveMedia: Signal<Bool, NoError> { self.base.captionIsAboveMedia }
    var canMakePaidContent: Bool { self.base.canMakePaidContent }
    var price: Int64? { self.base.price }
    var hasTimers: Bool { self.base.hasTimers }
    var loadingProgress: Signal<CGFloat?, NoError> { self.base.loadingProgress }
    var mainButtonState: Signal<AttachmentMainButtonState?, NoError> { self.base.mainButtonState }
    var secondaryButtonState: Signal<AttachmentMainButtonState?, NoError> { self.base.secondaryButtonState }
    var bottomPanelBackgroundColor: Signal<UIColor?, NoError> { self.base.bottomPanelBackgroundColor }

    func setCaptionIsAboveMedia(_ captionIsAboveMedia: Bool) {
        self.base.setCaptionIsAboveMedia(captionIsAboveMedia)
    }

    func setPrice(_ price: Int64) {
        self.base.setPrice(price)
    }

    func mainButtonAction() {
        self.base.mainButtonAction()
    }

    func secondaryButtonAction() {
        self.base.secondaryButtonAction()
    }

    func setCaption(_ caption: NSAttributedString) {
        self.base.setCaption(caption)
        self.captionChanged(caption.string)
    }

    func send(mode: AttachmentMediaPickerSendMode, attachmentMode: AttachmentMediaPickerAttachmentMode, parameters: ChatSendMessageActionSheetController.SendParameters?) {
        self.base.send(mode: mode, attachmentMode: attachmentMode, parameters: parameters)
    }

    func schedule(parameters: ChatSendMessageActionSheetController.SendParameters?) {
        self.base.schedule(parameters: parameters)
    }
}
