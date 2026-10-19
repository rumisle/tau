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
/// the tab bar of Gallery and File, and the caption field once photos are selected.
func makeTelegramAttachmentMenu(context: TauAccountContext, presentationData: PresentationData, completion: @escaping (TelegramAttachmentResult) -> Void) -> AttachmentController {
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
            present(picker, picker.mediaPickerContext)
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
                PHImageManager.default().requestImage(for: phAsset, targetSize: CGSize(width: 1568.0, height: 1568.0), contentMode: .aspectFit, options: options) { image, _ in
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
