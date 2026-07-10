import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

enum ImageProbe {
    static func size(ofFileAt path: String) -> CGSize? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    static func pixelCount(ofFileAt path: String) -> Int? {
        guard let size = size(ofFileAt: path) else { return nil }
        return Int(size.width) * Int(size.height)
    }

    /// `noUpscale` (=denoise-only) 時、出力を入力と同じピクセルサイズへ縮小して上書きする。
    enum ResizeError: Error { case decodeFailed, encodeFailed }

    static func resizePNG(atPath path: String, to targetSize: CGSize) throws {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ResizeError.decodeFailed
        }
        let width = max(1, Int(targetSize.width))
        let height = max(1, Int(targetSize.height))
        guard let colorSpace = cgImage.colorSpace,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ResizeError.decodeFailed
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { throw ResizeError.encodeFailed }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ResizeError.encodeFailed
        }
        CGImageDestinationAddImage(destination, resized, nil)
        guard CGImageDestinationFinalize(destination) else { throw ResizeError.encodeFailed }
    }
}
