import SwiftUI
import PDFKit

struct PDFReaderView: NSViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let selectedBlock: OCRBlock?
    let imageWidth: Int
    let imageHeight: Int
    let onPageChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.displayBox = .cropBox
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        view.document = document
        context.coordinator.observe(view, onPageChange: onPageChange)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            context.coordinator.clearAnnotation()
            view.document = document
            view.autoScales = true
        }
        guard let page = document.page(at: pageIndex) else { return }
        if view.currentPage !== page {
            view.go(to: page)
            view.autoScales = true
        }

        let annotationKey = selectedBlock.map { "\(pageIndex):\($0.id):\($0.bbox ?? [])" }
        guard context.coordinator.annotationKey != annotationKey
                || context.coordinator.annotatedPage !== page else { return }
        context.coordinator.clearAnnotation()
        context.coordinator.annotationKey = annotationKey
        context.coordinator.annotatedPage = page

        guard let bbox = selectedBlock?.bbox,
              let bounds = annotationBounds(bbox, on: page) else { return }
        let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        annotation.color = NSColor.controlAccentColor.withAlphaComponent(0.85)
        annotation.interiorColor = NSColor.controlAccentColor.withAlphaComponent(0.14)
        let border = PDFBorder()
        border.lineWidth = 1.5
        annotation.border = border
        annotation.shouldPrint = false
        page.addAnnotation(annotation)
        context.coordinator.annotation = annotation
        view.setNeedsDisplay(view.bounds)
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        coordinator.clearAnnotation()
        coordinator.stopObserving()
    }

    /// Surya uses a rendered, rotation-applied crop image with a top-left origin.
    /// PDF annotations use the unrotated crop box in PDF's bottom-left coordinate space.
    private func annotationBounds(_ bbox: [Double], on page: PDFPage) -> CGRect? {
        guard bbox.count == 4,
              bbox.allSatisfy({ $0.isFinite && (0...1000).contains($0) }),
              bbox[2] > bbox[0], bbox[3] > bbox[1],
              imageWidth > 0, imageHeight > 0,
              let transform = PDFRenderer.drawingTransform(
                page: page, pixelWidth: imageWidth, pixelHeight: imageHeight
              ) else { return nil }

        // Match PDFRenderer's transform exactly, including rotation, crop offsets,
        // and fractional scaling introduced by rounding the bitmap dimensions.
        let imageRect = CGRect(
            x: bbox[0] * Double(imageWidth) / 1000,
            y: (1000 - bbox[3]) * Double(imageHeight) / 1000,
            width: (bbox[2] - bbox[0]) * Double(imageWidth) / 1000,
            height: (bbox[3] - bbox[1]) * Double(imageHeight) / 1000
        )
        return imageRect.applying(transform.inverted())
    }

    final class Coordinator {
        var annotationKey: String?
        weak var annotatedPage: PDFPage?
        var annotation: PDFAnnotation?
        private var pageObserver: NSObjectProtocol?

        func observe(_ view: PDFView, onPageChange: @escaping (Int) -> Void) {
            pageObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak view] _ in
                guard let view, let page = view.currentPage, let document = view.document else { return }
                let index = document.index(for: page)
                guard index != NSNotFound else { return }
                // PDFKit may notify during a SwiftUI view update.
                DispatchQueue.main.async { onPageChange(index) }
            }
        }

        func stopObserving() {
            if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
            pageObserver = nil
        }

        func clearAnnotation() {
            if let annotation, let annotatedPage {
                annotatedPage.removeAnnotation(annotation)
            }
            annotation = nil
            annotatedPage = nil
            annotationKey = nil
        }

        deinit {
            stopObserving()
        }
    }
}
