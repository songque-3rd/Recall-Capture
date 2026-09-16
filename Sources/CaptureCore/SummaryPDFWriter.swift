import CoreGraphics
import CoreText
import Foundation

public enum SummaryPDFError: Error, LocalizedError {
    case destinationAlreadyExists
    case couldNotCreateDocument
    case couldNotRenderPage
    case invalidDocument

    public var errorDescription: String? {
        switch self {
        case .destinationAlreadyExists:
            "summary.pdf はすでに存在します。"
        case .couldNotCreateDocument:
            "要約PDFを作成できませんでした。"
        case .couldNotRenderPage:
            "要約PDFのページを描画できませんでした。"
        case .invalidDocument:
            "生成した要約PDFを読み戻して検証できませんでした。"
        }
    }
}

public struct SummaryPDFWriter: Sendable {
    public init() {}

    @discardableResult
    public func write(
        summary: SessionSummary,
        metadata: SessionMetadata,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw SummaryPDFError.destinationAlreadyExists
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw SummaryPDFError.couldNotCreateDocument
        }

        let content = document(summary: summary, metadata: metadata)
        let framesetter = CTFramesetterCreateWithAttributedString(content)
        var location = 0
        var pageNumber = 1
        while location < content.length {
            context.beginPDFPage(nil)
            drawPageHeader(pageNumber: pageNumber, in: context, mediaBox: mediaBox)

            let path = CGMutablePath()
            path.addRect(CGRect(x: 52, y: 58, width: mediaBox.width - 104, height: mediaBox.height - 110))
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            drawFrameAsPaths(frame, in: context)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
                context.endPDFPage()
                context.closePDF()
                try? fileManager.removeItem(at: destination)
                throw SummaryPDFError.couldNotRenderPage
            }
            location += visible.length
            pageNumber += 1
            context.endPDFPage()
        }
        context.closePDF()
        try validate(destination, fileManager: fileManager)
        return destination
    }

    public func validate(_ url: URL, fileManager: FileManager = .default) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = attributes[.size] as? NSNumber
        guard (size?.intValue ?? 0) > 512,
              let document = CGPDFDocument(url as CFURL),
              document.numberOfPages > 0 else {
            throw SummaryPDFError.invalidDocument
        }
    }

    private func document(summary: SessionSummary, metadata: SessionMetadata) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(styled("\(summary.title)\n", size: 22, weight: .bold, spacing: 10))
        result.append(styled("\(metadata.captureMode == .meet ? "オンライン会議" : "対面授業")  |  \(formatted(metadata.startedAt, timeZoneID: metadata.timezone))\n", size: 10, color: CGColor(gray: 0.35, alpha: 1), spacing: 16))
        result.append(styled("概要\n", size: 16, weight: .bold, spacing: 6))
        result.append(styled("\(summary.overview)\n", size: 11, spacing: 14))

        for section in summary.sections {
            result.append(styled("\(section.title)\n", size: 15, weight: .bold, spacing: 5))
            for item in section.items {
                result.append(styled("• \(item)\n", size: 10.5, spacing: 5, firstLineHeadIndent: 0, headIndent: 14))
            }
            result.append(styled("\n", size: 6, spacing: 2))
        }

        result.append(styled("注意\n", size: 13, weight: .bold, spacing: 5))
        for warning in summary.warnings {
            result.append(styled("• \(warning)\n", size: 9.5, color: CGColor(gray: 0.28, alpha: 1), spacing: 4, headIndent: 14))
        }
        return result
    }

    private enum FontWeight {
        case regular
        case bold
    }

    private func styled(
        _ string: String,
        size: CGFloat,
        weight: FontWeight = .regular,
        color: CGColor = CGColor(gray: 0.08, alpha: 1),
        spacing: CGFloat,
        firstLineHeadIndent: CGFloat = 0,
        headIndent: CGFloat = 0
    ) -> NSAttributedString {
        let fontName = weight == .bold ? "HiraginoSans-W6" : "HiraginoSans-W3"
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        var lineSpacing = spacing
        var firstIndent = firstLineHeadIndent
        var followingIndent = headIndent
        let paragraph = withUnsafePointer(to: &lineSpacing) { lineSpacingPointer in
            withUnsafePointer(to: &firstIndent) { firstIndentPointer in
                withUnsafePointer(to: &followingIndent) { followingIndentPointer in
                    let settings = [
                        CTParagraphStyleSetting(
                            spec: .paragraphSpacing,
                            valueSize: MemoryLayout<CGFloat>.size,
                            value: lineSpacingPointer
                        ),
                        CTParagraphStyleSetting(
                            spec: .firstLineHeadIndent,
                            valueSize: MemoryLayout<CGFloat>.size,
                            value: firstIndentPointer
                        ),
                        CTParagraphStyleSetting(
                            spec: .headIndent,
                            valueSize: MemoryLayout<CGFloat>.size,
                            value: followingIndentPointer
                        )
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
        return NSAttributedString(
            string: string,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
            ]
        )
    }

    private func drawPageHeader(pageNumber: Int, in context: CGContext, mediaBox: CGRect) {
        let text = styled("Recall Capture  •  \(pageNumber)", size: 8, color: CGColor(gray: 0.5, alpha: 1), spacing: 0)
        let line = CTLineCreateWithAttributedString(text)
        drawLineAsPaths(line, origin: CGPoint(x: 52, y: 30), in: context)
    }

    private func drawFrameAsPaths(_ frame: CTFrame, in context: CGContext) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let frameOrigin = CTFrameGetPath(frame).boundingBox.origin
        for (line, origin) in zip(lines, origins) {
            drawLineAsPaths(
                line,
                origin: CGPoint(x: origin.x + frameOrigin.x, y: origin.y + frameOrigin.y),
                in: context
            )
        }
    }

    private func drawLineAsPaths(_ line: CTLine, origin: CGPoint, in context: CGContext) {
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            let color = attributes[kCTForegroundColorAttributeName] as! CGColor
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }

            var glyphs = Array(repeating: CGGlyph(), count: count)
            var positions = Array(repeating: CGPoint.zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)

            context.setFillColor(color)
            let textMatrix = CTRunGetTextMatrix(run)
            for index in 0..<count {
                guard let path = CTFontCreatePathForGlyph(font, glyphs[index], nil) else { continue }
                context.saveGState()
                context.translateBy(
                    x: origin.x + positions[index].x,
                    y: origin.y + positions[index].y
                )
                context.concatenate(textMatrix)
                context.addPath(path)
                context.fillPath()
                context.restoreGState()
            }
        }
    }

    private func formatted(_ timestamp: String, timeZoneID: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: timestamp) else {
            return timestamp
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timeZoneID)
        formatter.dateFormat = "yyyy年M月d日 H:mm"
        return formatter.string(from: date)
    }
}
