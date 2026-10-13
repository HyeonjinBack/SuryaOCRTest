import Foundation

/// Parser for the high_accuracy_bbox prompt, pinned to Surya a2363d3.
/// https://github.com/datalab-to/surya/blob/a2363d3311773a2b6145a40458043211c50c52f4/surya/inference/prompts.py
/// This small scanner handles the model's block envelope, not arbitrary HTML DOMs.
/// HTML is retained as data and is never executed or loaded into a web view.
enum SuryaHTMLParser {
    enum ParseError: Error, LocalizedError, Equatable {
        case invalidPageMetadata
        case noBlocks
        case malformedHTML
        case invalidBlockAttributes
        case invalidBoundingBox

        var errorDescription: String? {
            switch self {
            case .invalidPageMetadata: return "페이지 크기 또는 인덱스가 올바르지 않습니다."
            case .noBlocks: return "모델 출력에서 OCR 블록을 찾지 못했습니다. 원본 출력을 확인하세요."
            case .malformedHTML: return "모델의 HTML 출력이 잘렸거나 블록 구조가 올바르지 않습니다."
            case .invalidBlockAttributes: return "OCR 블록에 영역 좌표 또는 종류가 없습니다."
            case .invalidBoundingBox: return "모델이 올바르지 않은 영역 좌표를 반환했습니다."
            }
        }
    }

    static func parse(
        _ html: String, pageIndex: Int, imageWidth: Int, imageHeight: Int,
        elapsedSeconds: Double
    ) throws -> OCRPageResult {
        guard pageIndex >= 0, imageWidth > 0, imageHeight > 0,
              elapsedSeconds.isFinite, elapsedSeconds >= 0 else {
            throw ParseError.invalidPageMetadata
        }

        let tokens = try scan(html)
        var divDepth = 0
        var active: (depth: Int, start: String.Index, label: String, bbox: [Double])?
        var blocks: [OCRBlock] = []
        for token in tokens where token.name == "div" {
            if token.isClosing {
                guard divDepth > 0 else { throw ParseError.malformedHTML }
                if let block = active, block.depth == divDepth {
                    let inner = String(html[block.start..<token.range.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    blocks.append(OCRBlock(
                        id: "page-\(pageIndex)-block-\(blocks.count)", label: block.label,
                        html: inner, text: try plainText(inner), bbox: block.bbox
                    ))
                    active = nil
                }
                divDepth -= 1
            } else {
                let hasEnvelope = token.attributes["data-label"] != nil || token.attributes["data-bbox"] != nil
                if active == nil, hasEnvelope {
                    guard !token.isSelfClosing,
                          let label = token.attributes["data-label"],
                          !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let bboxString = token.attributes["data-bbox"] else {
                        throw ParseError.invalidBlockAttributes
                    }
                    active = (
                        depth: divDepth + 1, start: token.range.upperBound,
                        label: decodeEntities(label), bbox: try parseBoundingBox(bboxString)
                    )
                }
                if !token.isSelfClosing { divDepth += 1 }
            }
        }
        guard divDepth == 0, active == nil else { throw ParseError.malformedHTML }
        guard !blocks.isEmpty else { throw ParseError.noBlocks }
        return OCRPageResult(
            pageIndex: pageIndex, imageWidth: imageWidth, imageHeight: imageHeight,
            rawHTML: html, blocks: blocks, elapsedSeconds: elapsedSeconds
        )
    }

    private static func parseBoundingBox(_ text: String) throws -> [Double] {
        let parts = text.split { $0.isWhitespace || $0 == "," }
        let numbers = parts.compactMap { Double($0) }
        guard parts.count == 4, numbers.count == 4,
              numbers.allSatisfy({ $0.isFinite && (0...1000).contains($0) }),
              numbers[2] >= numbers[0], numbers[3] >= numbers[1] else {
            throw ParseError.invalidBoundingBox
        }
        return numbers
    }

    private struct Token {
        let range: Range<String.Index>
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
        let attributes: [String: String]
    }

    /// Respect quotes so `title="a > b"` cannot terminate a tag prematurely.
    private static func scan(_ html: String) throws -> [Token] {
        var cursor = html.startIndex
        var tokens: [Token] = []
        while cursor < html.endIndex, let start = html[cursor...].firstIndex(of: "<") {
            let contentStart = html.index(after: start)
            guard contentStart < html.endIndex else { break }
            if html[start...].hasPrefix("<!--") {
                guard let end = html.range(of: "-->", range: contentStart..<html.endIndex) else {
                    throw ParseError.malformedHTML
                }
                tokens.append(Token(range: start..<end.upperBound, name: "!", isClosing: false,
                                    isSelfClosing: true, attributes: [:]))
                cursor = end.upperBound
                continue
            }
            let first = html[contentStart]
            guard first.isLetter || first == "/" || first == "!" || first == "?" else {
                cursor = contentStart
                continue
            }
            var end = contentStart
            var quote: Character?
            while end < html.endIndex {
                let character = html[end]
                if let openingQuote = quote {
                    if character == openingQuote { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    break
                }
                end = html.index(after: end)
            }
            guard end < html.endIndex, quote == nil else { throw ParseError.malformedHTML }
            let afterEnd = html.index(after: end)
            let body = html[contentStart..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            let isClosing = body.hasPrefix("/")
            let nameStart = isClosing ? body.index(after: body.startIndex) : body.startIndex
            let name = String(body[nameStart...].prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" }).lowercased()
            let attributes = try parseAttributes(body)
            tokens.append(Token(
                range: start..<afterEnd, name: name.isEmpty ? "!" : name,
                isClosing: isClosing, isSelfClosing: body.hasSuffix("/"), attributes: attributes
            ))
            cursor = afterEnd
        }
        return tokens
    }

    private static func parseAttributes(_ body: String) throws -> [String: String] {
        let expression = try NSRegularExpression(
            pattern: #"([a-zA-Z_:][a-zA-Z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        )
        let source = body as NSString
        var attributes: [String: String] = [:]
        for match in expression.matches(in: body, range: NSRange(location: 0, length: source.length)) {
            let key = source.substring(with: match.range(at: 1)).lowercased()
            guard let valueRange = (2...4).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) else {
                continue
            }
            if attributes[key] != nil, key == "data-label" || key == "data-bbox" {
                throw ParseError.invalidBlockAttributes
            }
            attributes[key] = source.substring(with: valueRange)
        }
        return attributes
    }

    private static func plainText(_ html: String) throws -> String {
        let tokens = try scan(html)
        let lineTags: Set<String> = ["div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "br", "hr", "pre", "table", "caption"]
        var result = ""
        var cursor = html.startIndex
        var hiddenDepth = 0
        for token in tokens {
            if hiddenDepth == 0 { result += html[cursor..<token.range.lowerBound] }
            if token.name == "script" || token.name == "style" {
                hiddenDepth = max(0, hiddenDepth + (token.isClosing ? -1 : 1))
            } else if hiddenDepth == 0 {
                if lineTags.contains(token.name) { result += "\n" }
                if (token.name == "td" || token.name == "th") && token.isClosing { result += "\t" }
                if token.name == "img", let alt = token.attributes["alt"] { result += alt }
            }
            cursor = token.range.upperBound
        }
        if hiddenDepth == 0 { result += html[cursor...] }
        let decoded = decodeEntities(result)
        return decoded.components(separatedBy: .newlines).map {
            $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func decodeEntities(_ text: String) -> String {
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "ndash": "–", "mdash": "—", "minus": "−", "times": "×", "divide": "÷",
            "le": "≤", "ge": "≥", "ne": "≠", "plusmn": "±", "infin": "∞", "sum": "∑",
            "prod": "∏", "radic": "√", "int": "∫", "part": "∂", "nabla": "∇", "asymp": "≈",
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "theta": "θ",
            "lambda": "λ", "mu": "μ", "nu": "ν", "pi": "π", "rho": "ρ", "sigma": "σ",
            "tau": "τ", "phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
            "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Pi": "Π",
            "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω", "hellip": "…",
            "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "middot": "·",
            "bull": "•", "copy": "©", "reg": "®", "trade": "™", "deg": "°",
            "larr": "←", "rarr": "→", "harr": "↔", "uarr": "↑", "darr": "↓"
        ]
        guard let expression = try? NSRegularExpression(pattern: #"&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[A-Za-z][A-Za-z0-9]+);"#) else { return text }
        let source = text as NSString
        var result = text
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let name = source.substring(with: match.range(at: 1))
            let replacement: String?
            if name.hasPrefix("#") {
                let hex = name.hasPrefix("#x") || name.hasPrefix("#X")
                let digits = String(name.dropFirst(hex ? 2 : 1))
                if let value = UInt32(digits, radix: hex ? 16 : 10), value != 0,
                   let scalar = UnicodeScalar(value) {
                    replacement = String(scalar)
                } else { replacement = nil }
            } else { replacement = named[name] }
            if let replacement, let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }
}
