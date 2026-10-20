import Foundation
import UIKit
import Display
import AsyncDisplayKit

open class ZoomableContentGalleryItemNode: GalleryItemNode, ASScrollViewDelegate {
    public let scrollNode: ASScrollNode
    
    private var containerLayout: ContainerViewLayout?
    
    private var ignoreZoom = false
    private var ignoreZoomTransition: ContainedViewLayoutTransition?
    
    public var zoomableContent: (CGSize, ASDisplayNode)? {
        didSet {
            if oldValue?.1 !== self.zoomableContent?.1 {
                if let node = oldValue?.1 {
                    node.view.removeFromSuperview()
                }
                if let node = self.zoomableContent?.1 {
                    self.scrollNode.addSubnode(node)
                }
            }
            self.resetScrollViewContents(transition: .immediate)
            self.centerScrollViewContents(transition: .immediate)
        }
    }
    
    override public init() {
        self.scrollNode = ASScrollNode()
        if #available(iOSApplicationExtension 11.0, iOS 11.0, *) {
            self.scrollNode.view.contentInsetAdjustmentBehavior = .never
        }
    
        super.init()
        
        self.scrollNode.view.delegate = self.wrappedScrollViewDelegate
        self.scrollNode.view.showsVerticalScrollIndicator = false
        self.scrollNode.view.showsHorizontalScrollIndicator = false
        self.scrollNode.view.clipsToBounds = false
        self.scrollNode.view.scrollsToTop = false
        self.scrollNode.view.delaysContentTouches = false
        
        let edgeWidth: CGFloat = 44.0
        
        let tapRecognizer = TapLongTapOrDoubleTapGestureRecognizer(target: self, action: #selector(self.contentTap(_:)))
        tapRecognizer.tapActionAtPoint = { [weak self] location in
            if let strongSelf = self {
                let pointInNode = strongSelf.scrollNode.view.convert(location, to: strongSelf.view)
                if pointInNode.x < edgeWidth || pointInNode.x > strongSelf.frame.width - edgeWidth {
                    return .waitForSingleTap
                }
            }
            return .waitForDoubleTap
        }
        
        self.scrollNode.view.addGestureRecognizer(tapRecognizer)

        self.addSubnode(self.scrollNode)
    }
    
    open func contentTapAction() -> Bool {
        return false
    }
    
    open func contentDoubleTapAction(location: CGPoint) -> Bool {
        return false
    }
    
    @objc open func contentTap(_ recognizer: TapLongTapOrDoubleTapGestureRecognizer) {
        if recognizer.state == .ended {
            if let (gesture, location) = recognizer.lastRecognizedGestureAndLocation {
                let pointInNode = self.scrollNode.view.convert(location, to: self.view)
                if pointInNode.x < 44.0 || pointInNode.x > self.frame.width - 44.0 {
                } else {
                    switch gesture {
                        case .tap:
                            if self.contentTapAction() {
                                return
                            }
                            self.toggleControlsVisibility()
                        case .doubleTap:
                            if self.contentDoubleTapAction(location: pointInNode) {
                                return
                            }
                        
                            if let contentView = self.zoomableContent?.1.view, self.scrollNode.view.zoomScale.isLessThanOrEqualTo(self.scrollNode.view.minimumZoomScale) {
                                let pointInView = self.scrollNode.view.convert(location, to: contentView)
                                
                                let newZoomScale = self.scrollNode.view.maximumZoomScale
                                let scrollViewSize = self.scrollNode.view.bounds.size
                                
                                let w = scrollViewSize.width / newZoomScale
                                let h = scrollViewSize.height / newZoomScale
                                let x = pointInView.x - (w / 2.0)
                                let y = pointInView.y - (h / 2.0)
                                
                                let rectToZoomTo = CGRect(x: x, y: y, width: w, height: h)
                                
                                self.scrollNode.view.zoom(to: rectToZoomTo, animated: true)
                            } else {
                                self.scrollNode.view.setZoomScale(self.scrollNode.view.minimumZoomScale, animated: true)
                            }
                        default:
                            break
                    }
                }
            }
        }
    }
    
    override open func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationBarHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, navigationBarHeight: navigationBarHeight, transition: transition)
        
        var shouldResetContents = false
        if let containerLayout = self.containerLayout {
            shouldResetContents = !containerLayout.size.equalTo(layout.size)
        } else {
            shouldResetContents = true
        }
        self.containerLayout = layout
        
        if shouldResetContents {
            var previousFrame: CGRect?
            var previousScale: CGFloat?
            if let (_, contentNode) = self.zoomableContent {
                previousFrame = contentNode.view.frame
                let t = contentNode.layer.transform
                previousScale = sqrt((t.m11 * t.m11) + (t.m12 * t.m12) + (t.m13 * t.m13))
            }
            
            transition.updateFrame(node: self.scrollNode, frame: CGRect(origin: CGPoint(), size: layout.size))
            self.resetScrollViewContents(transition: .immediate)
            
            if let (_, contentNode) = self.zoomableContent, let previousFrame = previousFrame, let previousScale = previousScale {
                transition.animatePosition(node: contentNode, from: CGPoint(x: previousFrame.midX, y: previousFrame.midY))
                switch transition {
                    case .immediate:
                        break
                    case let .animated(duration, curve):
                        let t = contentNode.layer.transform
                        let currentScale = sqrt((t.m11 * t.m11) + (t.m12 * t.m12) + (t.m13 * t.m13))
                        
                        contentNode.layer.animateScale(from: previousScale, to: currentScale, duration: duration, timingFunction: curve.timingFunction)
                }
            }
        }
    }
    
    private func resetScrollViewContents(transition: ContainedViewLayoutTransition) {
        guard let (contentSize, contentNode) = self.zoomableContent else {
            return
        }
        
        let boundsSize = self.scrollNode.view.bounds.size
        if contentSize.width.isLessThanOrEqualTo(0.0) || contentSize.height.isLessThanOrEqualTo(0.0) || boundsSize.width.isLessThanOrEqualTo(0.0) || boundsSize.height.isLessThanOrEqualTo(0.0) {
            return
        }
        
        let normalizedContentSize = contentSize.fitted(boundsSize)
        
        self.ignoreZoom = true
        self.ignoreZoomTransition = transition
        self.scrollNode.view.minimumZoomScale = 1.0
        self.scrollNode.view.maximumZoomScale = 1.0
        //self.scrollView.normalZoomScale = 1.0
        self.scrollNode.view.zoomScale = 1.0
        
        if contentNode.view is TilingView {
            contentNode.frame = CGRect(origin: CGPoint(), size: normalizedContentSize)
            self.scrollNode.view.contentSize = normalizedContentSize
            contentNode.transform = CATransform3DIdentity
        } else {
            self.scrollNode.view.contentSize = contentSize
            contentNode.transform = CATransform3DIdentity
            contentNode.frame = CGRect(origin: CGPoint(), size: contentSize)
        }
        
        self.centerScrollViewContents(transition: transition)
        self.ignoreZoom = false
        
        let updatedZoomScale = self.scrollNode.view.zoomScale != self.scrollNode.view.minimumZoomScale
        self.scrollNode.view.zoomScale = self.scrollNode.view.minimumZoomScale
        if !updatedZoomScale {
            self.scrollViewDidZoom(self.scrollNode.view)
        }
        self.ignoreZoomTransition = nil
    }
    
    private func centerScrollViewContents(transition: ContainedViewLayoutTransition) {
        guard let (contentSize, contentNode) = self.zoomableContent else {
            return
        }
        
        let boundsSize = self.scrollNode.view.bounds.size
        if contentSize.width.isLessThanOrEqualTo(0.0) || contentSize.height.isLessThanOrEqualTo(0.0) || boundsSize.width.isLessThanOrEqualTo(0.0) || boundsSize.height.isLessThanOrEqualTo(0.0) {
            return
        }
        
        var minScale: CGFloat
        var maxScale: CGFloat
        
        if contentNode.view is TilingView {
            let normalizedContentSize = contentSize.fitted(boundsSize)
            
            let scaleWidth = boundsSize.width / normalizedContentSize.width
            let scaleHeight = boundsSize.height / normalizedContentSize.height
            minScale = min(scaleWidth, scaleHeight)
            minScale = 1.0
            
            maxScale = max(scaleWidth, scaleHeight)
            maxScale = max(maxScale, minScale * 4.0)
            
            if (abs(maxScale - minScale) < 0.01) {
                maxScale = minScale
            }
            
            if !self.scrollNode.view.minimumZoomScale.isEqual(to: minScale) {
                self.scrollNode.view.minimumZoomScale = minScale
            }
            
            if !self.scrollNode.view.maximumZoomScale.isEqual(to: maxScale) {
                self.scrollNode.view.maximumZoomScale = maxScale
            }
            
            if let contentView = contentNode.view as? TilingView {
                contentView.setMaximumZoomScale(maxScale, normalizedSize: normalizedContentSize)
            }
        } else {
            let scaleWidth = boundsSize.width / contentSize.width
            let scaleHeight = boundsSize.height / contentSize.height
            let minScale = min(scaleWidth, scaleHeight)
            
            maxScale = max(scaleWidth, scaleHeight)
            maxScale = max(maxScale, minScale * 3.0)
            
            if (abs(maxScale - minScale) < 0.01) {
                maxScale = minScale
            }
            
            if !self.scrollNode.view.minimumZoomScale.isEqual(to: minScale) {
                self.scrollNode.view.minimumZoomScale = minScale
            }
            
            if !self.scrollNode.view.maximumZoomScale.isEqual(to: maxScale) {
                self.scrollNode.view.maximumZoomScale = maxScale
            }
        }
        
        var contentFrame = contentNode.view.frame
        
        if boundsSize.width > contentFrame.size.width {
            contentFrame.origin.x = (boundsSize.width - contentFrame.size.width) / 2.0
        } else {
            contentFrame.origin.x = 0.0
        }
        
        if boundsSize.height >= contentFrame.size.height {
            contentFrame.origin.y = (boundsSize.height - contentFrame.size.height) / 2.0
        } else {
            contentFrame.origin.y = 0.0
        }
        
        if !self.ignoreZoom {
            transition.updateFrame(view: contentNode.view, frame: contentFrame)
        }
    }
    
    open func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return self.zoomableContent?.1.view
    }
    
    open func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if !self.ignoreZoom {
            self.centerScrollViewContents(transition: self.ignoreZoomTransition ?? .immediate)
        }
        if self.scrollNode.view.zoomScale.isEqual(to: self.scrollNode.view.minimumZoomScale) {
            self.scrollNode.view.isScrollEnabled = false
        } else {
            self.scrollNode.view.isScrollEnabled = true
        }
    }
    
    override open func contentSize() -> CGSize? {
        if let (_, contentNode) = self.zoomableContent {
            let size = contentNode.view.convert(contentNode.bounds, to: self.view).size
            return CGSize(width: floor(size.width), height: floor(size.height))
        }
        return nil
    }
}

// tau: TilingView, which the zoom code tells apart, from Items/ChatImageGalleryItem.swift, which is not copied.

private func zoomScale(for zoomLevel: CGFloat) -> CGFloat {
    return pow(2.0, zoomLevel - 1.0)
}

private func zoomLevel(for zoomScale: CGFloat) -> CGFloat {
    return log2(zoomScale) + 1.0
}

private final class TilingLayer: CATiledLayer {
    override var contentsScale: CGFloat {
        get {
            return super.contentsScale
        } set(value) {
            super.contentsScale = value
        }
    }
}

class TilingView: UIView {
    let image: CGImage
    let path: String
    var cachedScaledImage: UIImage?
    
    let imageSize: CGSize
    let tileSize: CGSize
    var normalizedSize: CGSize?
    
    override static var layerClass: AnyClass {
        return TilingLayer.self
    }
    
    private var tiledLayer: TilingLayer {
        return self.layer as! TilingLayer
    }
    
    init(image: CGImage, path: String) {
        self.image = image
        self.path = path
        
        self.tileSize = CGSize(width: 256.0, height: 256.0)
        self.imageSize = CGSize(width: image.width, height: image.height)
        
        super.init(frame: CGRect())
        
        self.tiledLayer.contentsScale = UIScreenScale
        let scale = self.tiledLayer.contentsScale
        self.tiledLayer.tileSize = CGSize(width: self.tileSize.width * scale, height: self.tileSize.height * scale)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override var intrinsicContentSize: CGSize {
        return self.imageSize
    }
    
    func setMaximumZoomScale(_ value: CGFloat, normalizedSize: CGSize) {
        if self.normalizedSize != normalizedSize {
            self.normalizedSize = normalizedSize
            
            /*let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(self.imageSize.width / 4.0, self.imageSize.height / 4.0))
            ]

            let startTime = CACurrentMediaTime()
            if let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: self.path) as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                self.cachedScaledImage = UIImage(cgImage: image)
            }
            print("create thumbnail: \((CACurrentMediaTime() - startTime) * 1000.0) ms")*/
        }
        
        let levels = max(1, Int(zoomLevel(for: value)))
        self.tiledLayer.levelsOfDetail = levels
        self.tiledLayer.levelsOfDetailBias = levels - 1
    }
    
    override func draw(_ rect: CGRect) {
        guard let normalizedSize = self.normalizedSize else {
            return
        }
        guard let context = UIGraphicsGetCurrentContext() else {
            return
        }
        let image = self.image
        let cachedScaledImage = self.cachedScaledImage
        let imageSize = self.imageSize
        context.setBlendMode(.copy)
        
        let contentScale = context.ctm.a
        let normalizedContentScale = contentScale / UIScreenScale
        
        let normalizedRect = rect
        
        let normalizationScale = imageSize.width / normalizedSize.width
        
        let normalizedCroppingRect = CGRect(origin: CGPoint(x: normalizedRect.minX * normalizationScale, y: normalizedRect.minY * normalizationScale), size: CGSize(width: normalizedRect.width * normalizationScale, height: normalizedRect.height * normalizationScale))
        
        let tileSizes: [CGFloat] = [
            //8192.0,
            //4096.0,
            2048.0,
            1024.0,
            512.0,
            256.0
        ]
        
        var maximumTileSize: CGFloat = tileSizes[0]
        for i in (0 ..< tileSizes.count).reversed() {
            if tileSizes[i] > normalizedCroppingRect.width {
                break
            }
            maximumTileSize = tileSizes[i]
        }
        
        let xMinTile = Int(floor(normalizedCroppingRect.minX / maximumTileSize))
        let xMaxTile = Int(ceil(normalizedCroppingRect.maxX / maximumTileSize))
        let yMinTile = Int(floor(normalizedCroppingRect.minY / maximumTileSize))
        let yMaxTile = Int(ceil(normalizedCroppingRect.maxY / maximumTileSize))
        
        for y in yMinTile ... yMaxTile {
            let imageMinY = floor(CGFloat(y) * maximumTileSize)
            var imageMaxY = ceil(CGFloat(y + 1) * maximumTileSize)
            imageMaxY = min(imageMaxY, imageSize.height)
            if imageMaxY <= imageMinY {
                continue
            }
            
            for x in xMinTile ... xMaxTile {
                let imageMinX = floor(CGFloat(x) * maximumTileSize)
                var imageMaxX = ceil(CGFloat(x + 1) * maximumTileSize)
                imageMaxX = min(imageMaxX, imageSize.width)
                if imageMaxX <= imageMinX {
                    continue
                }
                
                let imageRect = CGRect(origin: CGPoint(x: imageMinX, y: imageMinY), size: CGSize(width: imageMaxX - imageMinX, height: imageMaxY - imageMinY))
                
                let drawingRect = CGRect(origin: CGPoint(x: imageRect.minX / normalizationScale, y: imageRect.minY / normalizationScale), size: CGSize(width: imageRect.width / normalizationScale, height: imageRect.height / normalizationScale))
                
                var tileImage: CGImage?
                if normalizedContentScale < 1.1, let cachedScaledImage = cachedScaledImage {
                    let cachedScale = cachedScaledImage.size.width / self.imageSize.width
                    let scaledImageRect = CGRect(origin: CGPoint(x: imageRect.minX * cachedScale, y: imageRect.minY * cachedScale), size: CGSize(width: imageRect.width * cachedScale, height: imageRect.height * cachedScale))
                    tileImage = cachedScaledImage.cgImage!.cropping(to: scaledImageRect)
                } else {
                    tileImage = image.cropping(to: imageRect)
                }
                
                if let tileImage = tileImage {
                    var scaledSide = max(imageRect.width, imageRect.height)
                    let targetSide = max(drawingRect.width, drawingRect.height)
                    while true {
                        let maybeSide = round(scaledSide * 0.5)
                        if maybeSide < targetSide {
                            break
                        } else {
                            scaledSide = maybeSide
                        }
                    }
                    
                    /*let scaledSize = imageRect.size.fitted(CGSize(width: scaledSide, height: scaledSide))
                    let scaledImage = generateImage(scaledSize, contextGenerator: { size, scaledContext in
                        scaledContext.setBlendMode(.copy)
                        let startTime = CACurrentMediaTime()
                        scaledContext.draw(tileImage, in: CGRect(origin: CGPoint(), size: size))
                        print("draw scaled: \((CACurrentMediaTime() - startTime) * 1000.0) ms")
                    }, opaque: true, scale: UIScreenScale)
                    
                    if let scaledImage = scaledImage {
                        scaledImage.draw(in: drawingRect.insetBy(dx: -0.5, dy: -0.5), blendMode: .copy, alpha: 1.0)
                    }*/
                    
                    let startTime = CACurrentMediaTime()
                    context.translateBy(x: drawingRect.midX, y: drawingRect.midY)
                    context.scaleBy(x: 1.0, y: -1.0)
                    context.translateBy(x: -drawingRect.midX, y: -drawingRect.midY)
                    context.draw(tileImage, in: drawingRect.insetBy(dx: -0.5, dy: -0.5))
                    context.translateBy(x: drawingRect.midX, y: drawingRect.midY)
                    context.scaleBy(x: 1.0, y: -1.0)
                    context.translateBy(x: -drawingRect.midX, y: -drawingRect.midY)
                    print("draw direct: \((CACurrentMediaTime() - startTime) * 1000.0) ms")
                }
            }
        }
    }
    
    private func annotate(rect: CGRect, col: Int, row: Int, zoomLevel: CGFloat, scale: CGFloat, context: CGContext) {
        let lineWidth = 2.0 / scale
        let halfLineWidth = lineWidth / 2.0
        //let fontSize = 12.0 / scale
        
        //NSString *pointString = [NSString stringWithFormat:@"%@x(%@, %@) @%@x", @(zoomLevel), @(col), @(row), @([UIScreen mainScreen].scale)];
        //CGPoint textOrigin = CGPointMake(CGRectGetMinX(rect) + lineWidth, CGRectGetMinY(rect) + lineWidth);
        /*[pointString drawAtPoint:textOrigin withAttributes:@{
                                                             NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize],
                                                             NSForegroundColorAttributeName: [UIColor darkGrayColor]
                                                             }];*/
        context.setFillColor(UIColor.red.cgColor)
        context.setLineWidth(lineWidth)
        context.stroke(rect.insetBy(dx: halfLineWidth, dy: halfLineWidth))
    }
}
