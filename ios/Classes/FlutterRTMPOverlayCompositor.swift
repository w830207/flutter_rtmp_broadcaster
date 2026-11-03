import AVFoundation
import CoreImage
import UIKit

/// Composites still images (overlays) onto the frames sent to the stream.
///
/// Frames are rendered into a separate pixel buffer, so the capture buffer
/// used for the Flutter preview texture is left untouched. Overlays are drawn
/// after capture mirroring has been applied, so they are never mirrored.
@objc
public class FlutterRTMPOverlayCompositor: NSObject {
    private struct Item {
        let image: CIImage
        /// Normalized (0...1) rect in the output frame, origin at the top-left.
        let rect: CGRect
    }

    private let lock: NSLock = NSLock()
    private let context: CIContext = CIContext(options: [.cacheIntermediates: false])
    private var items: [Item] = []
    /// The overlays composited for one frame size, cached until items change.
    private var cachedLayer: CIImage? = nil
    private var cachedSize: CGSize = .zero
    private var pool: CVPixelBufferPool? = nil
    private var poolSize: CGSize = .zero
    private var poolFormat: OSType = 0

    /// Replaces all overlays. Each entry has `path`, `left`, `top`, `width`
    /// and `height`; the rect is normalized to the output frame. Entries are
    /// ordered bottom to top.
    @objc
    public func setOverlays(_ overlays: [[String: Any]]) {
        var newItems: [Item] = []
        for overlay: [String: Any] in overlays {
            guard let path: String = overlay["path"] as? String,
                  let left: NSNumber = overlay["left"] as? NSNumber,
                  let top: NSNumber = overlay["top"] as? NSNumber,
                  let width: NSNumber = overlay["width"] as? NSNumber,
                  let height: NSNumber = overlay["height"] as? NSNumber,
                  let image: CIImage = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
                continue
            }
            newItems.append(Item(
                image: image,
                rect: CGRect(
                    x: left.doubleValue,
                    y: top.doubleValue,
                    width: width.doubleValue,
                    height: height.doubleValue
                )
            ))
        }
        lock.lock()
        items = newItems
        cachedLayer = nil
        lock.unlock()
    }

    /// Returns [buffer] with the overlays drawn on top, or [buffer] itself
    /// when there is nothing to draw or compositing fails.
    func composite(_ buffer: CMSampleBuffer) -> CMSampleBuffer {
        guard let source: CVPixelBuffer = CMSampleBufferGetImageBuffer(buffer) else {
            return buffer
        }
        let size: CGSize = CGSize(
            width: CVPixelBufferGetWidth(source),
            height: CVPixelBufferGetHeight(source)
        )
        guard let layer: CIImage = overlayLayer(for: size),
              let target: CVPixelBuffer = makePixelBuffer(
                size: size,
                format: CVPixelBufferGetPixelFormatType(source)
              ) else {
            return buffer
        }
        let frame: CIImage = layer.composited(over: CIImage(cvPixelBuffer: source))
        context.render(frame, to: target)
        return makeSampleBuffer(target, timingFrom: buffer) ?? buffer
    }

    private func overlayLayer(for size: CGSize) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        if items.isEmpty {
            return nil
        }
        if let cached: CIImage = cachedLayer, cachedSize == size {
            return cached
        }
        var layer: CIImage = CIImage.empty()
        for item: Item in items {
            let extent: CGRect = item.image.extent
            let width: CGFloat = item.rect.width * size.width
            let height: CGFloat = item.rect.height * size.height
            let x: CGFloat = item.rect.minX * size.width
            // Core Image's origin is the bottom-left corner.
            let y: CGFloat = size.height - (item.rect.minY * size.height) - height
            let placed: CIImage = item.image
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(
                    scaleX: width / extent.width,
                    y: height / extent.height
                ))
                .transformed(by: CGAffineTransform(translationX: x, y: y))
            layer = placed.composited(over: layer)
        }
        cachedLayer = layer
        cachedSize = size
        return layer
    }

    private func makePixelBuffer(size: CGSize, format: OSType) -> CVPixelBuffer? {
        if pool == nil || poolSize != size || poolFormat != format {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var newPool: CVPixelBufferPool? = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = size
            poolFormat = format
        }
        guard let currentPool: CVPixelBufferPool = pool else {
            return nil
        }
        var pixelBuffer: CVPixelBuffer? = nil
        CVPixelBufferPoolCreatePixelBuffer(nil, currentPool, &pixelBuffer)
        return pixelBuffer
    }

    private func makeSampleBuffer(
        _ pixelBuffer: CVPixelBuffer,
        timingFrom source: CMSampleBuffer
    ) -> CMSampleBuffer? {
        var timing: CMSampleTimingInfo = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(source, at: 0, timingInfoOut: &timing) == noErr else {
            return nil
        }
        var format: CMVideoFormatDescription? = nil
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let videoFormat: CMVideoFormatDescription = format else {
            return nil
        }
        var sampleBuffer: CMSampleBuffer? = nil
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil,
            imageBuffer: pixelBuffer,
            formatDescription: videoFormat,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }
}
