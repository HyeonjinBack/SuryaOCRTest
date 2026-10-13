import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct RenderedPage: Sendable {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let cropBounds: CGRect
    let rotation: Int
    /// PDF coordinates to bitmap coordinates, with a bottom-left origin.
    let pdfToImageTransform: CGAffineTransform

    /// Converts model coordinates (top-left, normalized 0...1000) to PDF points.
    func pdfRect(forNormalizedBBox bbox: [Double]) -> CGRect? {
        guard bbox.count == 4,
              bbox.allSatisfy({ $0.isFinite && (0...1000).contains($0) }),
              bbox[2] >= bbox[0], bbox[3] >= bbox[1] else { return nil }
        let imageRect = CGRect(
            x: bbox[0] * Double(pixelWidth) / 1000,
            y: (1000 - bbox[3]) * Double(pixelHeight) / 1000,
            width: (bbox[2] - bbox[0]) * Double(pixelWidth) / 1000,
            height: (bbox[3] - bbox[1]) * Double(pixelHeight) / 1000
        )
        return imageRect.applying(pdfToImageTransform.inverted())
    }
}

enum PDFRenderer {
    enum RenderError: Error, LocalizedError {
        case invalidPage
        case invalidSize
        case cannotRender
        case cannotWrite

        var errorDescription: String? {
            switch self {
            case .invalidPage: return "PDF 페이지를 읽을 수 없습니다."
            case .invalidSize: return "PDF 페이지 크기가 올바르지 않거나 지원 범위를 벗어납니다."
            case .cannotRender: return "PDF 페이지 이미지를 생성할 수 없습니다."
            case .cannotWrite: return "PDF 페이지 이미지를 저장할 수 없습니다."
            }
        }
    }

    /// Shared by rendering and the PDF highlight overlay. The Core Graphics
    /// fitting transform can retain a scale of 1 when asked to enlarge a page;
    /// request its native-size rotation/crop transform, then scale explicitly.
    static func drawingTransform(
        page: PDFPage, pixelWidth: Int, pixelHeight: Int
    ) -> CGAffineTransform? {
        guard let cgPage = page.pageRef, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let bounds = cgPage.getBoxRect(.cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0, rotation % 90 == 0 else { return nil }
        let rotated = rotation == 90 || rotation == 270
        let nativeWidth = rotated ? bounds.height : bounds.width
        let nativeHeight = rotated ? bounds.width : bounds.height
        let native = cgPage.getDrawingTransform(
            .cropBox, rect: CGRect(x: 0, y: 0, width: nativeWidth, height: nativeHeight),
            rotate: Int32(rotation) - cgPage.rotationAngle, preserveAspectRatio: true
        )
        let scale = min(Double(pixelWidth) / nativeWidth, Double(pixelHeight) / nativeHeight)
        let offsetX = (Double(pixelWidth) - nativeWidth * scale) / 2
        let offsetY = (Double(pixelHeight) - nativeHeight * scale) / 2
        return native.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
    }

    /// Synchronous work: use a document owned by the calling actor/queue.
    /// Do not share PDFDocument between the UI and a concurrent rendering task.
    static func render(
        document: PDFDocument, pageIndex: Int, to url: URL, dpi: Double = 144
    ) throws -> RenderedPage {
        guard pageIndex >= 0, let page = document.page(at: pageIndex), let cgPage = page.pageRef else {
            throw RenderError.invalidPage
        }
        let bounds = cgPage.getBoxRect(.cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        guard dpi.isFinite, dpi > 0, dpi <= 600, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0, rotation % 90 == 0 else {
            throw RenderError.invalidSize
        }
        let rotated = rotation == 90 || rotation == 270
        let width = ceil((rotated ? bounds.height : bounds.width) * dpi / 72)
        let height = ceil((rotated ? bounds.width : bounds.height) * dpi / 72)
        // Refuse pathological input before allocating a potentially huge bitmap.
        guard width <= 16_384, height <= 16_384, width * height <= 40_000_000 else {
            throw RenderError.invalidSize
        }
        let pixelWidth = Int(width)
        let pixelHeight = Int(height)
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw RenderError.cannotRender }
        let target = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(target)
        context.interpolationQuality = .high
        guard let transform = drawingTransform(page: page, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            throw RenderError.cannotRender
        }
        context.concatenate(transform)
        context.drawPDFPage(cgPage)
        guard let image = context.makeImage() else { throw RenderError.cannotRender }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw RenderError.cannotWrite }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.cannotWrite }
        return RenderedPage(
            url: url, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            cropBounds: bounds, rotation: rotation, pdfToImageTransform: transform
        )
    }
}
