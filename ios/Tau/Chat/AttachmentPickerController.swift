import UIKit
import Photos
import AVFoundation
import AsyncDisplayKit
import Display
import SwiftSignalKit
import ComponentFlow
import ComponentDisplayAdapters
import GlassBackgroundComponent
import TabBarComponent

/// The attachment menu, after Telegram's AttachmentController and MediaPickerScreen: a sheet with recent photos, a live
/// camera tile first, and Telegram's glass tab bar (Gallery, File) at the bottom. Selecting photos swaps the bar for a
/// send button.
final class AttachmentPickerController: ViewController {
    enum Result {
        case images([UIImage])
        case file
        case camera
    }

    private let theme: TauTheme
    private let completion: (Result) -> Void

    private var pickerNode: AttachmentPickerNode {
        return self.displayNode as! AttachmentPickerNode
    }

    init(theme: TauTheme, completion: @escaping (Result) -> Void) {
        self.theme = theme
        self.completion = completion
        super.init(navigationBarPresentationData: nil)
        self.statusBar.statusBarStyle = .Ignore
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        self.displayNode = AttachmentPickerNode(theme: self.theme, finish: { [weak self] result in
            guard let self else {
                return
            }
            self.pickerNode.animateOut(completion: { [weak self] in
                guard let self else {
                    return
                }
                self.presentingViewController?.dismiss(animated: false, completion: nil)
                if let result {
                    self.completion(result)
                }
            })
        })
        self.displayNodeDidLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.pickerNode.animateIn()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.pickerNode.containerLayoutUpdated(layout, transition: transition)
    }
}

private enum PickerTab: Hashable {
    case gallery
    case file
}

private final class AttachmentPickerNode: ASDisplayNode, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    private let theme: TauTheme
    private let finish: (AttachmentPickerController.Result?) -> Void

    private let dimNode = ASDisplayNode()
    private let sheetNode = ASDisplayNode()
    private let grabberNode = ASDisplayNode()
    private let titleNode = ImmediateTextNode()
    private var collectionView: UICollectionView?
    private let tabBarView = ComponentView<Empty>()
    private let sendBackgroundView = GlassBackgroundView()
    private let sendLabel = UILabel()

    private var assets: PHFetchResult<PHAsset>?
    private let imageManager = PHCachingImageManager()
    private var selected: [String] = []
    private var validLayout: ContainerViewLayout?
    private var sheetHeight: CGFloat = 0.0
    private var dragOffset: CGFloat = 0.0
    private var isDismissing = false

    private static let columns: CGFloat = 3.0
    private static let spacing: CGFloat = 2.0

    init(theme: TauTheme, finish: @escaping (AttachmentPickerController.Result?) -> Void) {
        self.theme = theme
        self.finish = finish
        super.init()
        self.dimNode.backgroundColor = UIColor(white: 0.0, alpha: 0.35)
        self.sheetNode.backgroundColor = theme.list.blocksBackgroundColor
        self.sheetNode.cornerRadius = 38.0
        self.sheetNode.layer.cornerCurve = .continuous
        self.sheetNode.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        self.sheetNode.clipsToBounds = true
        self.grabberNode.backgroundColor = theme.list.itemSecondaryTextColor.withAlphaComponent(0.4)
        self.grabberNode.cornerRadius = 2.5
        self.titleNode.attributedText = NSAttributedString(string: "Recents", font: Font.semibold(17.0), textColor: theme.list.itemPrimaryTextColor)
        self.addSubnode(self.dimNode)
        self.addSubnode(self.sheetNode)
        self.sheetNode.addSubnode(self.grabberNode)
        self.sheetNode.addSubnode(self.titleNode)
    }

    override func didLoad() {
        super.didLoad()
        self.dimNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.dimTapped)))

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = AttachmentPickerNode.spacing
        layout.minimumLineSpacing = AttachmentPickerNode.spacing
        let collectionView = UICollectionView(frame: CGRect(), collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(PhotoCell.self, forCellWithReuseIdentifier: "photo")
        collectionView.register(CameraCell.self, forCellWithReuseIdentifier: "camera")
        collectionView.alwaysBounceVertical = true
        self.sheetNode.view.addSubview(collectionView)
        self.collectionView = collectionView

        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.panned(_:)))
        pan.delegate = self
        self.sheetNode.view.addGestureRecognizer(pan)

        self.sendBackgroundView.alpha = 0.0
        self.sendBackgroundView.isAccessibilityElement = true
        self.sendBackgroundView.accessibilityIdentifier = "send-photos"
        self.sendBackgroundView.accessibilityTraits = .button
        self.sendLabel.font = Font.semibold(17.0)
        self.sendLabel.textAlignment = .center
        self.sendLabel.textColor = self.theme.chat.actionControlForegroundColor
        self.sendBackgroundView.contentView.addSubview(self.sendLabel)
        self.sendBackgroundView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.sendTapped)))
        self.view.addSubview(self.sendBackgroundView)

        self.loadAssets()
    }

    private func loadAssets() {
        let load: () -> Void = { [weak self] in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = 500
            let assets = PHAsset.fetchAssets(with: .image, options: options)
            DispatchQueue.main.async {
                self?.assets = assets
                self?.collectionView?.reloadData()
            }
        }
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited:
            load()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                if status == .authorized || status == .limited {
                    load()
                }
            }
        default:
            break
        }
    }

    // MARK: - Presentation

    func animateIn() {
        self.dimNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
        let offset = self.sheetHeight + 40.0
        self.sheetNode.layer.animatePosition(from: CGPoint(x: 0.0, y: offset), to: CGPoint(), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
        if let tabBar = self.tabBarView.view {
            tabBar.layer.animatePosition(from: CGPoint(x: 0.0, y: offset), to: CGPoint(), duration: 0.5, delay: 0.03, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
        }
    }

    func animateOut(completion: @escaping () -> Void) {
        guard !self.isDismissing else {
            return
        }
        self.isDismissing = true
        self.dimNode.layer.animateAlpha(from: self.dimNode.alpha, to: 0.0, duration: 0.25, removeOnCompletion: false)
        let offset = self.sheetHeight + 60.0
        for layer in [self.sheetNode.layer, self.tabBarView.view?.layer, self.sendBackgroundView.layer].compactMap({ $0 }) {
            layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: offset - self.dragOffset), duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeIn.rawValue, removeOnCompletion: false, additive: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: completion)
    }

    @objc private func dimTapped() {
        self.finish(nil)
    }

    @objc private func sendTapped() {
        guard let assets = self.assets else {
            return
        }
        let ids = self.selected
        var images: [String: UIImage] = [:]
        let group = DispatchGroup()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        assets.enumerateObjects { asset, _, _ in
            guard ids.contains(asset.localIdentifier) else {
                return
            }
            group.enter()
            self.imageManager.requestImage(for: asset, targetSize: CGSize(width: 1600.0, height: 1600.0), contentMode: .aspectFit, options: options) { image, _ in
                if let image {
                    images[asset.localIdentifier] = image
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.finish(.images(ids.compactMap { images[$0] }))
        }
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self.view).y
        switch recognizer.state {
        case .changed:
            self.dragOffset = max(0.0, translation)
            self.sheetNode.view.transform = CGAffineTransform(translationX: 0.0, y: self.dragOffset)
            self.tabBarView.view?.transform = CGAffineTransform(translationX: 0.0, y: self.dragOffset)
            self.sendBackgroundView.transform = CGAffineTransform(translationX: 0.0, y: self.dragOffset)
            self.dimNode.alpha = max(0.0, 1.0 - self.dragOffset / max(1.0, self.sheetHeight))
        case .ended, .cancelled:
            let velocity = recognizer.velocity(in: self.view).y
            if self.dragOffset > 120.0 || velocity > 800.0 {
                self.finish(nil)
            } else {
                self.dragOffset = 0.0
                UIView.animate(withDuration: 0.4, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.0, options: [], animations: {
                    self.sheetNode.view.transform = .identity
                    self.tabBarView.view?.transform = .identity
                    self.sendBackgroundView.transform = .identity
                    self.dimNode.alpha = 1.0
                })
            }
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }
        // Dragging down from the top of the grid moves the sheet, as Telegram's attachment sheet does.
        let velocity = pan.velocity(in: self.view)
        let atTop = (self.collectionView?.contentOffset.y ?? 0.0) <= 0.0
        return velocity.y > abs(velocity.x) && atTop
    }

    // MARK: - Layout

    func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        self.validLayout = layout
        let size = layout.size
        transition.updateFrame(node: self.dimNode, frame: CGRect(origin: CGPoint(), size: size))

        let tabBarHeight = self.updateTabBar(layout: layout, transition: transition)
        self.sheetHeight = min(size.height - layout.safeInsets.top - 40.0, floor(size.height * 0.62))
        let sheetFrame = CGRect(x: 0.0, y: size.height - self.sheetHeight, width: size.width, height: self.sheetHeight)
        transition.updateFrame(node: self.sheetNode, frame: sheetFrame)
        self.grabberNode.frame = CGRect(x: floor((size.width - 36.0) / 2.0), y: 6.0, width: 36.0, height: 5.0)
        let titleSize = self.titleNode.updateLayout(CGSize(width: size.width, height: 30.0))
        self.titleNode.frame = CGRect(origin: CGPoint(x: floor((size.width - titleSize.width) / 2.0), y: 20.0), size: titleSize)

        let gridTop: CGFloat = 54.0
        if let collectionView = self.collectionView {
            collectionView.frame = CGRect(x: 0.0, y: gridTop, width: size.width, height: self.sheetHeight - gridTop)
            collectionView.contentInset = UIEdgeInsets(top: 0.0, left: 0.0, bottom: tabBarHeight + 8.0, right: 0.0)
            collectionView.collectionViewLayout.invalidateLayout()
        }

        let sendSize = CGSize(width: size.width - 40.0, height: 52.0)
        let sendFrame = CGRect(x: 20.0, y: size.height - max(layout.intrinsicInsets.bottom, 8.0) - sendSize.height, width: sendSize.width, height: sendSize.height)
        self.sendBackgroundView.frame = sendFrame
        self.sendBackgroundView.update(size: sendSize, cornerRadius: sendSize.height / 2.0, isDark: self.theme.overallDarkAppearance, tintColor: .init(kind: .custom(style: .default, color: self.theme.chat.actionControlFillColor)), isInteractive: true, transition: ComponentTransition(transition))
        self.sendLabel.frame = CGRect(origin: CGPoint(), size: sendSize)
    }

    private func updateTabBar(layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) -> CGFloat {
        let bottomInset = max(layout.intrinsicInsets.bottom, 8.0)
        let sideInset: CGFloat = bottomInset <= 28.0 ? 20.0 : 12.0
        let items: [(PickerTab, String, String)] = [(.gallery, "Gallery", "TabPhoto"), (.file, "File", "TabFile")]
        let tabBarSize = self.tabBarView.update(
            transition: ComponentTransition(transition),
            component: AnyComponent(TabBarComponent(
                theme: self.theme.presentationTheme,
                strings: self.theme.presentationStrings,
                items: items.map { tab, title, animation in
                    TabBarComponent.Item(
                        content: .customItem(.init(id: AnyHashable(tab), title: title, icon: .animation(name: animation, offset: .zero))),
                        action: { [weak self] _ in
                            if tab == .file {
                                self?.finish(.file)
                            }
                        },
                        doubleTapAction: nil,
                        contextAction: nil
                    )
                },
                search: nil,
                selectedId: AnyHashable(PickerTab.gallery),
                outerInsets: UIEdgeInsets(top: 0.0, left: sideInset, bottom: bottomInset, right: sideInset)
            )),
            environment: {},
            containerSize: CGSize(width: layout.size.width - sideInset * 2.0, height: 100.0)
        )
        if let tabBar = self.tabBarView.view {
            if tabBar.superview == nil {
                self.view.insertSubview(tabBar, belowSubview: self.sendBackgroundView)
            }
            transition.updateFrame(view: tabBar, frame: CGRect(x: floor((layout.size.width - tabBarSize.width) / 2.0), y: layout.size.height - bottomInset - tabBarSize.height, width: tabBarSize.width, height: tabBarSize.height))
        }
        return tabBarSize.height + bottomInset
    }

    private func updateSendButton() {
        let count = self.selected.count
        self.sendLabel.text = count == 1 ? "Send 1 Photo" : "Send \(count) Photos"
        // View alpha, not layer opacity: glass effect views render wrongly under a layer opacity.
        UIView.animate(withDuration: 0.25) {
            self.sendBackgroundView.alpha = count > 0 ? 1.0 : 0.0
            self.tabBarView.view?.alpha = count > 0 ? 0.0 : 1.0
        }
        self.sendBackgroundView.isUserInteractionEnabled = count > 0
        if count > 0 && self.sendBackgroundView.alpha == 1.0 {
            self.sendBackgroundView.layer.animateScale(from: 0.96, to: 1.0, duration: 0.2, timingFunction: kCAMediaTimingFunctionSpring)
        }
    }

    // MARK: - Grid

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return 1 + (self.assets?.count ?? 0)
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let columns = AttachmentPickerNode.columns
        let side = floor((collectionView.bounds.width - AttachmentPickerNode.spacing * (columns - 1.0)) / columns)
        return CGSize(width: side, height: side)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if indexPath.item == 0 {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "camera", for: indexPath) as! CameraCell
            cell.start()
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "photo", for: indexPath) as! PhotoCell
        guard let asset = self.assets?.object(at: indexPath.item - 1) else {
            return cell
        }
        cell.assetIdentifier = asset.localIdentifier
        let scale = UIScreen.main.scale
        let side = self.collectionView(collectionView, layout: collectionView.collectionViewLayout, sizeForItemAt: indexPath).width * scale
        self.imageManager.requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: nil) { image, _ in
            if cell.assetIdentifier == asset.localIdentifier {
                cell.imageView.image = image
            }
        }
        cell.setSelectionIndex(self.selected.firstIndex(of: asset.localIdentifier).map { $0 + 1 }, color: self.theme.accentColor, animated: false)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if indexPath.item == 0 {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        if granted {
                            self.finish(.camera)
                        }
                    }
                }
            } else {
                self.finish(.camera)
            }
            return
        }
        guard let asset = self.assets?.object(at: indexPath.item - 1) else {
            return
        }
        if let index = self.selected.firstIndex(of: asset.localIdentifier) {
            self.selected.remove(at: index)
        } else {
            self.selected.append(asset.localIdentifier)
        }
        // Numbers follow the order of selection, as in Telegram.
        for cell in collectionView.visibleCells {
            if let cell = cell as? PhotoCell, let identifier = cell.assetIdentifier {
                cell.setSelectionIndex(self.selected.firstIndex(of: identifier).map { $0 + 1 }, color: self.theme.accentColor, animated: identifier == asset.localIdentifier)
            }
        }
        self.updateSendButton()
    }
}

private final class PhotoCell: UICollectionViewCell {
    let imageView = UIImageView()
    private let checkView = UILabel()
    var assetIdentifier: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.imageView.contentMode = .scaleAspectFill
        self.imageView.clipsToBounds = true
        self.contentView.addSubview(self.imageView)
        self.checkView.font = Font.semibold(13.0)
        self.checkView.textAlignment = .center
        self.checkView.textColor = .white
        self.checkView.layer.cornerRadius = 12.0
        self.checkView.layer.borderWidth = 1.5
        self.checkView.layer.borderColor = UIColor.white.cgColor
        self.checkView.clipsToBounds = true
        self.contentView.addSubview(self.checkView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.imageView.image = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.imageView.frame = self.contentView.bounds
        self.checkView.frame = CGRect(x: self.bounds.width - 30.0, y: 6.0, width: 24.0, height: 24.0)
    }

    func setSelectionIndex(_ index: Int?, color: UIColor, animated: Bool) {
        self.checkView.text = index.map(String.init) ?? ""
        self.checkView.backgroundColor = index == nil ? UIColor(white: 0.0, alpha: 0.15) : color
        self.imageView.alpha = 1.0
        if animated, index != nil {
            self.checkView.layer.animateScale(from: 0.6, to: 1.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
        }
    }
}

/// The first tile: what the camera sees, as Telegram's attachment menu shows it.
private final class CameraCell: UICollectionViewCell {
    private var session: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let iconView = UIImageView(image: UIImage(systemName: "camera.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24.0, weight: .medium)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.contentView.backgroundColor = UIColor(white: 0.1, alpha: 1.0)
        self.contentView.clipsToBounds = true
        self.iconView.tintColor = .white
        self.iconView.contentMode = .center
        self.contentView.addSubview(self.iconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            session?.stopRunning()
        }
    }

    func start() {
        guard self.session == nil, AVCaptureDevice.authorizationStatus(for: .video) == .authorized, let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), let input = try? AVCaptureDeviceInput(device: device) else {
            // Permission is asked for when the tile is tapped, not when the menu opens.
            return
        }
        let session = AVCaptureSession()
        session.sessionPreset = .medium
        if session.canAddInput(input) {
            session.addInput(input)
        }
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        self.contentView.layer.insertSublayer(previewLayer, at: 0)
        self.previewLayer = previewLayer
        self.session = session
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.previewLayer?.frame = self.contentView.bounds
        self.iconView.frame = self.contentView.bounds
    }
}
