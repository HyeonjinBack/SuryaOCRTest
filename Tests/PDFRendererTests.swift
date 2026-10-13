import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import XCTest
@testable import SuryaStudy

final class PDFRendererTests: XCTestCase {
    private func makeDocument() throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw PDFRenderer.RenderError.cannotRender }
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFRenderer.RenderError.cannotRender
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 40, y: 70, width: 50, height: 50))
        context.endPDFPage()
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    func testRenderingRespectsCropAndEveryRightAngleRotation() throws {
        let document = try makeDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let crop = CGRect(x: 30, y: 40, width: 200, height: 300)
        page.setBounds(crop, for: .cropBox)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }

        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let rendered = try PDFRenderer.render(document: document, pageIndex: 0, to: url, dpi: 144)
            XCTAssertEqual(rendered.rotation, rotation)
            XCTAssertEqual(rendered.cropBounds, crop)
            XCTAssertEqual(rendered.pixelWidth, rotation % 180 == 0 ? 400 : 600)
            XCTAssertEqual(rendered.pixelHeight, rotation % 180 == 0 ? 600 : 400)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, rendered.pixelWidth)
            XCTAssertEqual(image.height, rendered.pixelHeight)
            let mapped = try XCTUnwrap(rendered.pdfRect(forNormalizedBBox: [0, 0, 1000, 1000]))
            XCTAssertEqual(mapped.minX, crop.minX, accuracy: 0.001)
            XCTAssertEqual(mapped.minY, crop.minY, accuracy: 0.001)
            XCTAssertEqual(mapped.width, crop.width, accuracy: 0.001)
            XCTAssertEqual(mapped.height, crop.height, accuracy: 0.001)

            // A non-central rectangle must round-trip through the render matrix.
            let original = CGRect(x: 45, y: 80, width: 35, height: 55)
            let pixels = original.applying(rendered.pdfToImageTransform)
            let box = [
                pixels.minX / Double(rendered.pixelWidth) * 1000,
                (1 - pixels.maxY / Double(rendered.pixelHeight)) * 1000,
                pixels.maxX / Double(rendered.pixelWidth) * 1000,
                (1 - pixels.minY / Double(rendered.pixelHeight)) * 1000
            ]
            let restored = try XCTUnwrap(rendered.pdfRect(forNormalizedBBox: box))
            XCTAssertEqual(restored.minX, original.minX, accuracy: 0.001)
            XCTAssertEqual(restored.minY, original.minY, accuracy: 0.001)
            XCTAssertEqual(restored.width, original.width, accuracy: 0.001)
            XCTAssertEqual(restored.height, original.height, accuracy: 0.001)
        }
    }

    func testInvalidPageAndAllocationSizeAreRejected() throws {
        let document = try makeDocument()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        XCTAssertThrowsError(try PDFRenderer.render(document: document, pageIndex: 1, to: url))
        XCTAssertThrowsError(try PDFRenderer.render(document: document, pageIndex: 0, to: url, dpi: .infinity))
        XCTAssertThrowsError(try PDFRenderer.render(document: document, pageIndex: 0, to: url, dpi: 0))
    }
}
