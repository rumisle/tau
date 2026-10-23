import UIKit

/// Photos as they are sent, by the app and the share extension: JPEG, at most `maxPixels` on the long side.
enum ImageEncoding {
    /// pi's own limit for images (DEFAULT_IMAGE_LIMITS): within the high-resolution Claude's 2576 and the 2000 a request
    /// of more than 20 images allows each, and about OpenAI's `high` (2048). Larger only costs: models that take an
    /// image as it is (GPT-5.5's default `original`) bill it by its 32-pixel patches, the others shrink it themselves,
    /// and every turn sends it again and the database keeps it.
    static let maxPixels: CGFloat = 2000.0

    /// `image` at most `maxPixels` pixels on its long side (its pixels, whatever its scale), as JPEG.
    static func jpeg(_ image: UIImage, maxPixels: CGFloat = ImageEncoding.maxPixels, quality: CGFloat = 0.8) -> Data? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixels.width > 0.0, pixels.height > 0.0 else {
            return nil
        }
        let scale = min(1.0, maxPixels / max(pixels.width, pixels.height))
        let target = CGSize(width: max(1.0, floor(pixels.width * scale)), height: max(1.0, floor(pixels.height * scale)))
        // One point a pixel: the default format draws at the screen's scale, three times the pixels.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: CGPoint(), size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
