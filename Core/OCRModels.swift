import Foundation

struct OCRBlock: Identifiable, Codable, Sendable {
    let id: String
    /// The original model label. No canonicalization or confidence is invented.
    let label: String
    /// Inner HTML; keep tables, math, and model-emitted markup for export.
    let html: String
    let text: String
    /// Top-left-origin x0, y0, x1, y1, normalized to 0...1000.
    let bbox: [Double]?

    func pixelBBox(imageWidth: Int, imageHeight: Int) -> [Double]? {
        guard let bbox, bbox.count == 4, imageWidth > 0, imageHeight > 0 else { return nil }
        return [
            bbox[0] * Double(imageWidth) / 1000,
            bbox[1] * Double(imageHeight) / 1000,
            bbox[2] * Double(imageWidth) / 1000,
            bbox[3] * Double(imageHeight) / 1000
        ]
    }
}

struct OCRPageResult: Codable, Sendable {
    /// Zero-based index in the original PDF, not the printed page number.
    let pageIndex: Int
    let imageWidth: Int
    let imageHeight: Int
    let rawHTML: String
    /// The order emitted by the model is preserved as the reading order.
    let blocks: [OCRBlock]
    let elapsedSeconds: Double
    let coordinateSpace: String

    init(
        pageIndex: Int, imageWidth: Int, imageHeight: Int,
        rawHTML: String, blocks: [OCRBlock], elapsedSeconds: Double
    ) {
        self.pageIndex = pageIndex
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.rawHTML = rawHTML
        self.blocks = blocks
        self.elapsedSeconds = elapsedSeconds
        self.coordinateSpace = "normalized_0_1000_top_left"
    }

    var text: String { blocks.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n") }
}
