import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import ActivityIndicator

/// A photo in the chat: one this phone has, or one on the server (`RemoteImage`), shown as Telegram shows media it is
/// still downloading: the placeholder color in the photo's own shape, a spinner in a dimmed circle once the wait is long
/// enough to notice, and the photo fading in when it comes. An image it already decoded shows at once, so laying a row
/// out again never blinks it.
final class ChatMediaImageNode: ASImageNode {
    private var shownKey: String?
    private var failed = false
    private let disposable = MetaDisposable()
    private var spinnerTimer: SwiftSignalKit.Timer?
    private var spinnerBackground: ASDisplayNode?
    private var spinner: ActivityIndicator?
    private var failedIcon: ASImageNode?

    override init() {
        super.init()
        self.contentMode = .scaleAspectFill
        self.clipsToBounds = true
        self.displaysAsynchronously = false
        self.isAccessibilityElement = true
        self.accessibilityIdentifier = "photo"
        self.accessibilityTraits = .image
    }

    deinit {
        self.disposable.dispose()
        self.spinnerTimer?.invalidate()
    }

    /// Whether it shows its photo yet: the media viewer opens only on one it has.
    var hasImage: Bool {
        return self.image != nil
    }

    func setAttachment(_ kind: MessageAttachment.Kind, placeholderColor: UIColor) {
        self.backgroundColor = placeholderColor
        switch kind {
        case let .image(image):
            self.shownKey = nil
            self.failed = false
            self.failedIcon?.isHidden = true
            self.disposable.set(nil)
            self.hideProgress()
            self.image = image
        case let .remote(remote):
            // The same photo, shown or on its way: nothing to do; failed: try again.
            guard self.shownKey != remote.key || self.failed else {
                return
            }
            self.shownKey = remote.key
            self.failed = false
            if let cached = remote.cachedDisplay {
                self.disposable.set(nil)
                self.hideProgress()
                self.image = cached
                return
            }
            self.image = nil
            self.failedIcon?.isHidden = true
            self.showProgressSoon()
            self.disposable.set((remote.display() |> deliverOnMainQueue).start(next: { [weak self] image in
                guard let self, self.shownKey == remote.key else {
                    return
                }
                self.hideProgress()
                if let image {
                    self.image = image
                    self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                } else {
                    self.showFailed()
                }
            }))
        case .file:
            break
        }
    }

    override func layout() {
        super.layout()
        let size = self.bounds.size
        let diameter: CGFloat = 44.0
        let frame = CGRect(x: floor((size.width - diameter) / 2.0), y: floor((size.height - diameter) / 2.0), width: diameter, height: diameter)
        self.spinnerBackground?.frame = frame
        self.spinner?.frame = frame.insetBy(dx: 10.0, dy: 10.0)
        if let icon = self.failedIcon, let image = icon.image {
            icon.frame = CGRect(x: floor((size.width - image.size.width) / 2.0), y: floor((size.height - image.size.height) / 2.0), width: image.size.width, height: image.size.height)
        }
    }

    /// After a moment: a photo from the disk cache comes before it would show.
    private func showProgressSoon() {
        self.spinnerTimer?.invalidate()
        let timer = SwiftSignalKit.Timer(timeout: 0.25, repeat: false, completion: { [weak self] in
            self?.showProgress()
        }, queue: Queue.mainQueue())
        self.spinnerTimer = timer
        timer.start()
    }

    private func showProgress() {
        guard self.image == nil, self.spinner == nil else {
            return
        }
        // Telegram's media status: a white spinner in a dimmed circle.
        let background = ASDisplayNode()
        background.isLayerBacked = true
        background.backgroundColor = UIColor(white: 0.0, alpha: 0.5)
        background.cornerRadius = 22.0
        let spinner = ActivityIndicator(type: .custom(.white, 24.0, 2.0, true))
        self.addSubnode(background)
        self.addSubnode(spinner)
        self.spinnerBackground = background
        self.spinner = spinner
        self.setNeedsLayout()
        background.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        spinner.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }

    private func hideProgress() {
        self.spinnerTimer?.invalidate()
        self.spinnerTimer = nil
        self.spinnerBackground?.removeFromSupernode()
        self.spinnerBackground = nil
        self.spinner?.removeFromSupernode()
        self.spinner = nil
    }

    /// Not on the server any more, or no image a phone can show: a photo glyph in its place.
    private func showFailed() {
        self.failed = true
        if self.failedIcon == nil {
            let icon = ASImageNode()
            icon.displaysAsynchronously = false
            icon.image = UIImage(systemName: "photo", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28.0, weight: .regular))?.withTintColor(UIColor(white: 1.0, alpha: 0.6), renderingMode: .alwaysOriginal)
            self.addSubnode(icon)
            self.failedIcon = icon
        }
        self.failedIcon?.isHidden = false
        self.setNeedsLayout()
    }
}
