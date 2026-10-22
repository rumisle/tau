import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import GalleryUI
import TelegramPresentationData

/// A photo in the media viewer: one image attachment of the conversation, a user's or a tool's. One on the server
/// shows as the chat has it and loads at full size when its page opens.
struct ImageGalleryEntry: Equatable {
    let attachmentId: Int
    let image: UIImage
    var remote: RemoteImage? = nil

    static func == (lhs: ImageGalleryEntry, rhs: ImageGalleryEntry) -> Bool {
        return lhs.attachmentId == rhs.attachmentId
    }
}

/// Where a photo grows from and shrinks back to: its node in the chat, and a way to add copies above the chat while
/// they move (Telegram's GalleryTransitionArguments).
final class ImageGalleryTransitionArguments {
    let transitionNode: (ASDisplayNode, CGRect, () -> (UIView?, UIView?))
    let addToTransitionSurface: (UIView) -> Void

    init(transitionNode: (ASDisplayNode, CGRect, () -> (UIView?, UIView?)), addToTransitionSurface: @escaping (UIView) -> Void) {
        self.transitionNode = transitionNode
        self.addToTransitionSurface = addToTransitionSurface
    }
}

final class ImageGalleryControllerPresentationArguments {
    let transitionArguments: (ImageGalleryEntry) -> ImageGalleryTransitionArguments?

    init(transitionArguments: @escaping (ImageGalleryEntry) -> ImageGalleryTransitionArguments?) {
        self.transitionArguments = transitionArguments
    }
}

/// Telegram's media viewer for the conversation's photos: GalleryUI's pager, zoom, swipe to dismiss and transitions
/// (copied), driven as InstantPageUI's InstantPageGalleryController drives them, with pages after its
/// InstantImageGalleryItem.
final class ImageGalleryController: ViewController {
    private var galleryNode: GalleryControllerNode {
        return self.displayNode as! GalleryControllerNode
    }

    private let context: AppContext
    private let entries: [ImageGalleryEntry]
    private let centralIndex: Int
    private let presentationData: PresentationData

    private let _ready = Promise<Bool>()
    override var ready: Promise<Bool> {
        return self._ready
    }
    private var didSetReady = false

    private let centralItemTitle = Promise<String>()
    private let centralItemFooterContentNode = Promise<(GalleryFooterContentNode?, GalleryOverlayContentNode?)>()
    private let centralItemAttributesDisposable = DisposableSet()

    /// The photo the viewer shows, hidden in the chat so it seems to have left it.
    private let _hiddenMedia = Promise<ImageGalleryEntry?>(nil)
    var hiddenMedia: Signal<ImageGalleryEntry?, NoError> {
        return self._hiddenMedia.get()
    }

    private let baseNavigationController: NavigationController?

    init(context: AppContext, entries: [ImageGalleryEntry], centralIndex: Int, baseNavigationController: NavigationController?) {
        self.context = context
        self.entries = entries
        self.centralIndex = centralIndex
        self.baseNavigationController = baseNavigationController
        self.presentationData = context.theme.presentationData

        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: ImageGalleryController.darkNavigationTheme, strings: NavigationBarStrings(presentationStrings: self.presentationData.strings)))

        let backItem = UIBarButtonItem(backButtonAppearanceWithTitle: self.presentationData.strings.Common_Back, target: self, action: #selector(self.donePressed))
        self.navigationItem.leftBarButtonItem = backItem
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self, action: #selector(self.sharePressed))

        self.statusBar.statusBarStyle = .White

        self.centralItemAttributesDisposable.add(self.centralItemTitle.get().start(next: { [weak self] title in
            self?.navigationItem.title = title
        }))
        self.centralItemAttributesDisposable.add(self.centralItemFooterContentNode.get().start(next: { [weak self] footerContentNode, _ in
            self?.galleryNode.updatePresentationState({
                $0.withUpdatedFooterContentNode(footerContentNode)
            }, transition: .immediate)
        }))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.centralItemAttributesDisposable.dispose()
    }

    /// GalleryController.darkNavigationTheme.
    static let darkNavigationTheme = NavigationBarTheme(overallDarkAppearance: true, buttonColor: .white, disabledButtonColor: UIColor(rgb: 0x525252), primaryTextColor: .white, backgroundColor: UIColor(white: 0.0, alpha: 0.6), enableBackgroundBlur: false, separatorColor: UIColor(white: 0.0, alpha: 0.8), badgeBackgroundColor: .clear, badgeStrokeColor: .clear, badgeTextColor: .clear, edgeEffectColor: .clear, accentButtonColor: .white, accentDisabledButtonColor: .white, accentForegroundColor: .black, style: .glass)

    @objc private func donePressed() {
        self.dismiss(forceAway: false)
    }

    @objc private func sharePressed() {
        guard let node = self.galleryNode.pager.centralItemNode(), node.index < self.entries.count else {
            return
        }
        let entry = self.entries[node.index]
        // The photo itself, when it is on the server.
        let share: (Any) -> Void = { [weak self] item in
            let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
            self?.view.window?.rootViewController?.present(controller, animated: true)
        }
        if let remote = entry.remote {
            let _ = (remote.data() |> take(1) |> deliverOnMainQueue).start(next: { data in
                share(data.flatMap { UIImage(data: $0) } ?? entry.image)
            })
        } else {
            share(entry.image)
        }
    }

    private func item(_ entry: ImageGalleryEntry, index: Int) -> GalleryItem {
        let title = self.entries.count > 1 ? self.presentationData.strings.Items_NOfM("\(index + 1)", "\(self.entries.count)").string : ""
        return ImageGalleryItem(entry: entry, title: title)
    }

    private func dismiss(forceAway: Bool) {
        var animatedOutNode = true
        var animatedOutInterface = false

        let completion = { [weak self] in
            if animatedOutNode && animatedOutInterface {
                self?._hiddenMedia.set(.single(nil))
                self?.presentingViewController?.dismiss(animated: false, completion: nil)
            }
        }

        if let centralItemNode = self.galleryNode.pager.centralItemNode(), let presentationArguments = self.presentationArguments as? ImageGalleryControllerPresentationArguments, !forceAway {
            if let transitionArguments = presentationArguments.transitionArguments(self.entries[centralItemNode.index]) {
                animatedOutNode = false
                centralItemNode.animateOut(to: transitionArguments.transitionNode, addToTransitionSurface: transitionArguments.addToTransitionSurface, completion: {
                    animatedOutNode = true
                    completion()
                })
            }
        }

        self.galleryNode.animateOut(animateContent: animatedOutNode, completion: {
            animatedOutInterface = true
            completion()
        })
    }

    override func loadDisplayNode() {
        let controllerInteraction = GalleryControllerInteraction(presentController: { [weak self] controller, arguments in
            self?.present(controller, in: .window(.root), with: arguments, blockInteraction: true)
        }, pushController: { _ in
        }, dismissController: { [weak self] in
            self?.dismiss(forceAway: true)
        }, replaceRootController: { _, _ in
        }, editMedia: { _ in
        }, controller: { [weak self] in
            return self
        }, currentItemNode: { [weak self] in
            return self?.galleryNode.pager.centralItemNode()
        })
        self.displayNode = GalleryControllerNode(context: self.context.telegram, controllerInteraction: controllerInteraction, titleView: nil)
        self.displayNodeDidLoad()

        self.galleryNode.statusBar = self.statusBar
        self.galleryNode.navigationBar = self.navigationBar

        self.galleryNode.transitionDataForCentralItem = { [weak self] in
            guard let self, let centralItemNode = self.galleryNode.pager.centralItemNode(), let presentationArguments = self.presentationArguments as? ImageGalleryControllerPresentationArguments, let transitionArguments = presentationArguments.transitionArguments(self.entries[centralItemNode.index]) else {
                return nil
            }
            return (transitionArguments.transitionNode, transitionArguments.addToTransitionSurface)
        }
        self.galleryNode.dismiss = { [weak self] in
            self?._hiddenMedia.set(.single(nil))
            self?.presentingViewController?.dismiss(animated: false, completion: nil)
        }
        self.galleryNode.completeCustomDismiss = { [weak self] _ in
            self?._hiddenMedia.set(.single(nil))
            self?.presentingViewController?.dismiss(animated: false, completion: nil)
        }

        self.galleryNode.pager.replaceItems(self.entries.enumerated().map { self.item($0.element, index: $0.offset) }, centralItemIndex: self.centralIndex)

        self.galleryNode.pager.centralItemIndexUpdated = { [weak self] index in
            guard let self else {
                return
            }
            var hiddenItem: ImageGalleryEntry?
            if let index {
                hiddenItem = self.entries[index]
                if let node = self.galleryNode.pager.centralItemNode() {
                    self.centralItemTitle.set(node.title())
                    self.centralItemFooterContentNode.set(node.footerContent())
                }
            }
            if self.didSetReady {
                self._hiddenMedia.set(.single(hiddenItem))
            }
        }

        let baseNavigationController = self.baseNavigationController
        self.galleryNode.baseNavigationController = { [weak baseNavigationController] in
            return baseNavigationController
        }

        let ready = self.galleryNode.pager.ready() |> timeout(2.0, queue: Queue.mainQueue(), alternate: .single(Void())) |> afterNext { [weak self] _ in
            self?.didSetReady = true
        }
        self._ready.set(ready |> map { true })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        var nodeAnimatesItself = false
        if let centralItemNode = self.galleryNode.pager.centralItemNode() {
            self.centralItemTitle.set(centralItemNode.title())
            self.centralItemFooterContentNode.set(centralItemNode.footerContent())
            if let presentationArguments = self.presentationArguments as? ImageGalleryControllerPresentationArguments, let transitionArguments = presentationArguments.transitionArguments(self.entries[centralItemNode.index]) {
                nodeAnimatesItself = true
                centralItemNode.activateAsInitial()
                centralItemNode.animateIn(from: transitionArguments.transitionNode, addToTransitionSurface: transitionArguments.addToTransitionSurface, completion: {})
                self._hiddenMedia.set(.single(self.entries[centralItemNode.index]))
            }
        }
        self.galleryNode.animateIn(animateContent: !nodeAnimatesItself, useSimpleAnimation: false)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.galleryNode.frame = CGRect(origin: CGPoint(), size: layout.size)
        self.galleryNode.containerLayoutUpdated(layout, navigationBarHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }
}

private final class ImageGalleryItem: GalleryItem {
    let entry: ImageGalleryEntry
    let title: String

    var id: AnyHashable {
        return self.entry.attachmentId
    }

    init(entry: ImageGalleryEntry, title: String) {
        self.entry = entry
        self.title = title
    }

    func node(synchronous: Bool) -> GalleryItemNode {
        let node = ImageGalleryItemNode()
        node.setImage(self.entry.image)
        if let remote = self.entry.remote {
            node.loadFull(remote)
        }
        node._title.set(.single(self.title))
        return node
    }

    func updateNode(node: GalleryItemNode, synchronous: Bool) {
        (node as? ImageGalleryItemNode)?._title.set(.single(self.title))
    }

    func thumbnailItem() -> (Int64, GalleryThumbnailItem)? {
        return nil
    }
}

/// InstantImageGalleryItemNode with the image at hand instead of fetched: a zoomable page, and the open and close
/// transitions between the chat's photo and the page (copied).
private final class ImageGalleryItemNode: ZoomableContentGalleryItemNode {
    private let imageNode: ASImageNode
    fileprivate let _ready = Promise<Void>()
    fileprivate let _title = Promise<String>()

    override init() {
        self.imageNode = ASImageNode()
        self.imageNode.displaysAsynchronously = false
        super.init()
        self.imageNode.view.contentMode = .scaleAspectFill
        self.imageNode.clipsToBounds = true
    }

    override func ready() -> Signal<Void, NoError> {
        return self._ready.get()
    }

    func setImage(_ image: UIImage) {
        self.imageNode.image = image
        self.zoomableContent = (image.size, self.imageNode)
        self._ready.set(.single(Void()))
    }

    private let fullDisposable = MetaDisposable()

    deinit {
        self.fullDisposable.dispose()
    }

    /// The photo at full size in place of the chat's, the same shape, once decoded.
    func loadFull(_ remote: RemoteImage) {
        self.fullDisposable.set((remote.full() |> deliverOnMainQueue).start(next: { [weak self] image in
            guard let self, let image else {
                return
            }
            self.imageNode.image = image
        }))
    }

    override func title() -> Signal<String, NoError> {
        return self._title.get()
    }

    override func animateIn(from node: (ASDisplayNode, CGRect, () -> (UIView?, UIView?)), addToTransitionSurface: (UIView) -> Void, completion: @escaping () -> Void) {
        var transformedFrame = node.0.view.convert(node.0.view.bounds, to: self.imageNode.view)
        let transformedSuperFrame = node.0.view.convert(node.0.view.bounds, to: self.imageNode.view.superview)
        let transformedSelfFrame = node.0.view.convert(node.0.view.bounds, to: self.view)
        let transformedCopyViewFinalFrame = self.imageNode.view.convert(self.imageNode.view.bounds, to: self.view)

        let surfaceCopyView = node.2().0!
        let copyView = node.2().0!

        addToTransitionSurface(surfaceCopyView)

        var transformedSurfaceFrame: CGRect?
        var transformedSurfaceFinalFrame: CGRect?
        if let contentSurface = surfaceCopyView.superview {
            transformedSurfaceFrame = node.0.view.convert(node.0.view.bounds, to: contentSurface)
            transformedSurfaceFinalFrame = self.imageNode.view.convert(self.imageNode.view.bounds, to: contentSurface)
        }

        if let transformedSurfaceFrame {
            surfaceCopyView.frame = transformedSurfaceFrame
        }

        self.view.insertSubview(copyView, belowSubview: self.scrollNode.view)
        copyView.frame = transformedSelfFrame

        copyView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, removeOnCompletion: false)

        surfaceCopyView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.25, removeOnCompletion: false)

        let positionDuration: Double = 0.21

        copyView.layer.animatePosition(from: CGPoint(x: transformedSelfFrame.midX, y: transformedSelfFrame.midY), to: CGPoint(x: transformedCopyViewFinalFrame.midX, y: transformedCopyViewFinalFrame.midY), duration: positionDuration, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, completion: { [weak copyView] _ in
            copyView?.removeFromSuperview()
        })
        let scale = CGSize(width: transformedCopyViewFinalFrame.size.width / transformedSelfFrame.size.width, height: transformedCopyViewFinalFrame.size.height / transformedSelfFrame.size.height)
        copyView.layer.animate(from: NSValue(caTransform3D: CATransform3DIdentity), to: NSValue(caTransform3D: CATransform3DMakeScale(scale.width, scale.height, 1.0)), keyPath: "transform", timingFunction: kCAMediaTimingFunctionSpring, duration: 0.25, removeOnCompletion: false)

        if let transformedSurfaceFrame, let transformedSurfaceFinalFrame {
            surfaceCopyView.layer.animatePosition(from: CGPoint(x: transformedSurfaceFrame.midX, y: transformedSurfaceFrame.midY), to: CGPoint(x: transformedSurfaceFinalFrame.midX, y: transformedSurfaceFinalFrame.midY), duration: positionDuration, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, completion: { [weak surfaceCopyView] _ in
                surfaceCopyView?.removeFromSuperview()
            })
            let scale = CGSize(width: transformedSurfaceFinalFrame.size.width / transformedSurfaceFrame.size.width, height: transformedSurfaceFinalFrame.size.height / transformedSurfaceFrame.size.height)
            surfaceCopyView.layer.animate(from: NSValue(caTransform3D: CATransform3DIdentity), to: NSValue(caTransform3D: CATransform3DMakeScale(scale.width, scale.height, 1.0)), keyPath: "transform", timingFunction: kCAMediaTimingFunctionSpring, duration: 0.25, removeOnCompletion: false)
        }

        self.imageNode.layer.animatePosition(from: CGPoint(x: transformedSuperFrame.midX, y: transformedSuperFrame.midY), to: self.imageNode.layer.position, duration: positionDuration, timingFunction: kCAMediaTimingFunctionSpring)
        self.imageNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.1)

        transformedFrame.origin = CGPoint()
        self.imageNode.layer.animateBounds(from: transformedFrame, to: self.imageNode.layer.bounds, duration: 0.25, timingFunction: kCAMediaTimingFunctionSpring)
    }

    override func animateOut(to node: (ASDisplayNode, CGRect, () -> (UIView?, UIView?)), addToTransitionSurface: (UIView) -> Void, completion: @escaping () -> Void) {
        var transformedFrame = node.0.view.convert(node.0.view.bounds, to: self.imageNode.view)
        let transformedSuperFrame = node.0.view.convert(node.0.view.bounds, to: self.imageNode.view.superview)
        let transformedSelfFrame = node.0.view.convert(node.0.view.bounds, to: self.view)
        let transformedCopyViewInitialFrame = self.imageNode.view.convert(self.imageNode.view.bounds, to: self.view)

        var positionCompleted = false
        var boundsCompleted = false
        var copyCompleted = false

        let copyView = node.2().0!
        let surfaceCopyView = node.2().0!

        addToTransitionSurface(surfaceCopyView)

        var transformedSurfaceFrame: CGRect?
        var transformedSurfaceCopyViewInitialFrame: CGRect?
        if let contentSurface = surfaceCopyView.superview {
            transformedSurfaceFrame = node.0.view.convert(node.0.view.bounds, to: contentSurface)
            transformedSurfaceCopyViewInitialFrame = self.imageNode.view.convert(self.imageNode.view.bounds, to: contentSurface)
        }

        self.view.insertSubview(copyView, belowSubview: self.scrollNode.view)
        copyView.frame = transformedSelfFrame

        let intermediateCompletion = { [weak copyView, weak surfaceCopyView] in
            if positionCompleted && boundsCompleted && copyCompleted {
                copyView?.removeFromSuperview()
                surfaceCopyView?.removeFromSuperview()
                completion()
            }
        }

        copyView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.08, removeOnCompletion: false)
        surfaceCopyView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.025, removeOnCompletion: false)

        copyView.layer.animatePosition(from: CGPoint(x: transformedCopyViewInitialFrame.midX, y: transformedCopyViewInitialFrame.midY), to: CGPoint(x: transformedSelfFrame.midX, y: transformedSelfFrame.midY), duration: 0.25, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        let scale = CGSize(width: transformedCopyViewInitialFrame.size.width / transformedSelfFrame.size.width, height: transformedCopyViewInitialFrame.size.height / transformedSelfFrame.size.height)
        copyView.layer.animate(from: NSValue(caTransform3D: CATransform3DMakeScale(scale.width, scale.height, 1.0)), to: NSValue(caTransform3D: CATransform3DIdentity), keyPath: "transform", timingFunction: kCAMediaTimingFunctionSpring, duration: 0.25, removeOnCompletion: false, completion: { _ in
            copyCompleted = true
            intermediateCompletion()
        })

        if let transformedSurfaceFrame, let transformedCopyViewInitialFrame = transformedSurfaceCopyViewInitialFrame {
            surfaceCopyView.layer.animatePosition(from: CGPoint(x: transformedCopyViewInitialFrame.midX, y: transformedCopyViewInitialFrame.midY), to: CGPoint(x: transformedSurfaceFrame.midX, y: transformedSurfaceFrame.midY), duration: 0.25, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
            let scale = CGSize(width: transformedCopyViewInitialFrame.size.width / transformedSurfaceFrame.size.width, height: transformedCopyViewInitialFrame.size.height / transformedSurfaceFrame.size.height)
            surfaceCopyView.layer.animate(from: NSValue(caTransform3D: CATransform3DMakeScale(scale.width, scale.height, 1.0)), to: NSValue(caTransform3D: CATransform3DIdentity), keyPath: "transform", timingFunction: kCAMediaTimingFunctionSpring, duration: 0.25, removeOnCompletion: false)
        }

        self.imageNode.layer.animatePosition(from: self.imageNode.layer.position, to: CGPoint(x: transformedSuperFrame.midX, y: transformedSuperFrame.midY), duration: 0.25, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, completion: { _ in
            positionCompleted = true
            intermediateCompletion()
        })

        self.imageNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.08, removeOnCompletion: false)

        transformedFrame.origin = CGPoint()
        self.imageNode.layer.animateBounds(from: self.imageNode.layer.bounds, to: transformedFrame, duration: 0.25, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, completion: { _ in
            boundsCompleted = true
            intermediateCompletion()
        })
    }
}
