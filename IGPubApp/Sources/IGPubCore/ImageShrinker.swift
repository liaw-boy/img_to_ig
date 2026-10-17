import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes an oversized JPEG fit the upload limit. Tries gentle steps first (same size, lower quality), then
/// smaller sizes. The result is a fresh sRGB JPEG with the orientation applied; location and camera metadata are not copied.
public enum ImageShrinker {
    /// (longest edge or nil for "as is", JPEG quality)
    static let steps: [(Int?, Double)] = [
        (nil, 0.97), (nil, 0.94), (nil, 0.90), (nil, 0.86),
        (4096, 0.92), (3200, 0.90), (2560, 0.88), (2048, 0.86), (1600, 0.84),
    ]

    public static func shrink(_ jpeg: Data, toAtMost limit: Int) throws -> Data {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 else {
            throw IGPubError("無法讀取照片，不能縮小")
        }
        let longest = max(w, h)
        let target = Int(Double(limit) * 0.97)          // leave a little room
        for (edge, quality) in steps {
            if let edge, edge >= longest { continue }   // never enlarge, never repeat the full-size step
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: edge ?? longest]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { continue }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality,
                                                  kCGImageDestinationOptimizeColorForSharing: true] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { continue }
            let data = out as Data
            if data.count <= target, data.starts(with: [0xFF, 0xD8, 0xFF]) { return data }
        }
        throw IGPubError("這張照片無法縮到 \(limit / (1024 * 1024)) MB 以內")
    }
}
