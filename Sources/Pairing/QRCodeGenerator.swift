import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

enum QRCodeGenerator {
    /// 文字列を QR コード画像化する。外部ライブラリなし (CoreImage 標準フィルタ)。
    static func image(for string: String, scale: CGFloat = 10) -> NSImage? {
        let data = Data(string.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }

        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaled = outputImage.transformed(by: transform)

        let rep = NSCIImageRep(ciImage: scaled)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}
