import AppKit
import PDFKit

enum SampleDocument {
    /// This is an original, synthetic OCR fixture, not a published research paper.
    static func write(to url: URL) throws {
        let data = NSMutableData()
        var pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &pageBounds, nil) else {
            throw NativeOCRError.message("예제 PDF를 만들 수 없습니다.")
        }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(pageBounds)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        func draw(_ text: String, top: CGFloat, size: CGFloat, bold: Bool = false, height: CGFloat = 90) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            let attributes: [NSAttributedString.Key: Any] = [
                .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph
            ]
            (text as NSString).draw(in: CGRect(x: 52, y: 842 - top - height, width: 491, height: height), withAttributes: attributes)
        }

        draw("Surya Local OCR Check", top: 55, size: 25, bold: true, height: 45)
        draw("Synthetic research document · SwiftStudy", top: 108, size: 12, height: 25)
        draw("Abstract", top: 172, size: 18, bold: true, height: 30)
        draw("This document verifies local document recognition on a Mac. The application renders a PDF page and sends the image to an embedded model. No document is uploaded to an external service.", top: 215, size: 14, height: 120)
        draw("Method", top: 360, size: 18, bold: true, height: 30)
        draw("The pipeline uses PDFKit, llama.cpp, and Surya. It preserves text blocks and their positions so the original page can be checked alongside the extracted text.", top: 403, size: 14, height: 105)
        draw("Result", top: 535, size: 18, bold: true, height: 30)
        draw("Verification code: SURYA-2026. The expected value is 42. This synthetic example makes no scientific claims.", top: 578, size: 14, height: 100)
        draw("1", top: 786, size: 11, height: 20)

        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data as Data).write(to: url, options: .atomic)
    }
}
