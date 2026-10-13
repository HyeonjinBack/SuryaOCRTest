import XCTest
@testable import SuryaStudy

final class SuryaHTMLParserTests: XCTestCase {
    private func parse(_ html: String) throws -> OCRPageResult {
        try SuryaHTMLParser.parse(html, pageIndex: 2, imageWidth: 1200, imageHeight: 1800, elapsedSeconds: 1.5)
    }

    func testNestedHTMLPreservesBlockOrderAndMarkup() throws {
        let source = """
        ```html
        <html><body>
        <div data-label='Section-Header' data-bbox='100 50 900 150'><h2>A <i>study</i></h2></div>
        <div data-bbox="100, 200, 900, 800" data-label="Table">
          <table><tr><th>Name</th><th>Value</th></tr><tr><td><div title="a > b">Sample</div></td><td><math>x²</math></td></tr></table>
        </div>
        </body></html>
        ```
        """
        let result = try parse(source)
        XCTAssertEqual(result.rawHTML, source)
        XCTAssertEqual(result.blocks.map(\.label), ["Section-Header", "Table"])
        XCTAssertEqual(result.blocks.map(\.id), ["page-2-block-0", "page-2-block-1"])
        XCTAssertEqual(result.blocks[0].text, "A study")
        XCTAssertTrue(result.blocks[1].html.contains("<math>x²</math>"))
        XCTAssertTrue(result.blocks[1].text.contains("Sample"))
        XCTAssertTrue(result.blocks[1].text.contains("x²"))
        XCTAssertEqual(result.blocks[0].pixelBBox(imageWidth: 1200, imageHeight: 1800), [120, 90, 1080, 270])
        XCTAssertEqual(result.coordinateSpace, "normalized_0_1000_top_left")
    }

    func testEntityDecodingHandlesUnicodeAndDoesNotDecodeTwice() throws {
        let result = try parse("""
        <div data-label="Text" data-bbox="0 0 1000 1000"><p>A&amp;B&nbsp;&#54620;&#xAE00; &#x1F4C4; &alpha; &lt;x&gt; &amp;lt; &unknown;</p></div>
        """)
        XCTAssertEqual(result.blocks[0].text, "A&B 한글 📄 α <x> &lt; &unknown;")
    }

    func testNestedModelAttributesDoNotCreateDuplicateBlocks() throws {
        let result = try parse("""
        <div data-label="Complex-Block" data-bbox="0 0 1000 1000"><div data-label="Text" data-bbox="10 10 30 30">Nested</div><p>End</p></div>
        """)
        XCTAssertEqual(result.blocks.count, 1)
        XCTAssertEqual(result.blocks[0].text, "Nested\nEnd")
        XCTAssertTrue(result.blocks[0].html.contains("data-label=\"Text\""))
    }

    func testClosedFirstBlockDoesNotHideTruncatedSecondBlock() throws {
        XCTAssertThrowsError(try parse("""
        <div data-label="Text" data-bbox="0 0 500 500">Valid</div>
        <div data-label="Text" data-bbox="0 500 500 1000"><p>Truncated
        """)) { error in
            XCTAssertEqual(error as? SuryaHTMLParser.ParseError, .malformedHTML)
        }
    }

    func testTruncatedAttributeAndCommentAreRejected() {
        for source in [
            "<div data-label=\"Text\" data-bbox=\"0 0 1000",
            "<!-- unfinished <div data-label='Text' data-bbox='0 0 1 1'>x</div>"
        ] {
            XCTAssertThrowsError(try parse(source)) { error in
                XCTAssertEqual(error as? SuryaHTMLParser.ParseError, .malformedHTML)
            }
        }
    }

    func testMissingBlockMetadataAndInvalidCoordinatesAreRejected() {
        XCTAssertThrowsError(try parse("<div data-label='Text'>Missing bbox</div>")) { error in
            XCTAssertEqual(error as? SuryaHTMLParser.ParseError, .invalidBlockAttributes)
        }
        for bbox in ["0 0 10", "0 0 1001 1000", "500 0 100 500", "nan 0 100 100", "0 0 inf 100"] {
            XCTAssertThrowsError(try parse("<div data-label='Text' data-bbox='\(bbox)'>Text</div>")) { error in
                XCTAssertEqual(error as? SuryaHTMLParser.ParseError, .invalidBoundingBox)
            }
        }
    }

    func testProseAndEmptyOutputAreNotPretendedToBeOCRResults() {
        for source in ["", "I cannot process this image.", "<p>Hello</p>", "<div>No metadata</div>"] {
            XCTAssertThrowsError(try parse(source)) { error in
                XCTAssertEqual(error as? SuryaHTMLParser.ParseError, .noBlocks)
            }
        }
    }

    func testRawMarkupIsRetainedButScriptTextIsNotDisplayed() throws {
        let result = try parse("""
        <div data-label="Text" data-bbox="0 0 1000 1000"><p>Visible</p><script>not displayed</script><!-- hidden --><p>End</p></div>
        """)
        XCTAssertEqual(result.blocks[0].text, "Visible\nEnd")
        XCTAssertTrue(result.rawHTML.contains("<script>"))
    }

    func testJSONRoundTripRetainsSourceAndCoordinates() throws {
        let result = try parse("<div data-label='Text' data-bbox='0 10 500 1000'>논문</div>")
        let decoded = try JSONDecoder().decode(OCRPageResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.rawHTML, result.rawHTML)
        XCTAssertEqual(decoded.blocks[0].bbox, [0, 10, 500, 1000])
        XCTAssertEqual(decoded.pageIndex, 2)
    }
}
