import Foundation
import CoreText
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Loading

public enum BundledFont {
    /// The font is bundled rather than taken from the system so that a system
    /// font update cannot move glyph metrics under a golden comparison.
    /// See ADR-0011.
    public static let resourceName = "NagiRounded-Regular"
    public static let fileExtension = "ttf"

    public static func url() -> URL? {
        Bundle.module.url(forResource: resourceName, withExtension: fileExtension)
    }

    public static func data() -> Data? {
        url().flatMap { try? Data(contentsOf: $0) }
    }

    /// Registers the bundled font for this process and returns its PostScript
    /// name. The name is needed because `CTFontCreateWithName` matches on the
    /// PostScript name, not the file name.
    public static func registerAndCopyPostScriptName() -> String? {
        guard let url = url() else { return nil }
        var error: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        guard
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let descriptor = descriptors.first,
            let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        else { return nil }
        return name
    }
}

// MARK: - Mandatory breaks

/// The characters that *force* a break rather than merely permitting one
/// (UAX #14 class BK, plus CR/LF).
///
/// A line's consumed range includes these; its content range does not. Only
/// break controls are removed — ordinary whitespace is deliberately left alone,
/// because whether a trailing space belongs to the line is a layout policy
/// question, not something the 禁則 probe should decide on the side.
public enum MandatoryBreak {
    public static let scalars: Set<Unicode.Scalar> = [
        "\u{000A}",  // LF
        "\u{000D}",  // CR (CRLF is trimmed one control at a time)
        "\u{0085}",  // NEL
        "\u{2028}",  // LINE SEPARATOR
        "\u{2029}"   // PARAGRAPH SEPARATOR
    ]

    public static func isMandatoryBreak(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalars.contains(scalar)
    }

    /// The content range of a line: the range it consumed, minus any trailing
    /// mandatory break controls.
    ///
    /// Every input is clamped, so an out-of-range offset yields a degenerate
    /// range rather than a trap — offsets come from the typesetter, and a bad one
    /// is a bug to be reported, not a crash.
    public static func contentRange(
        of text: String,
        consumedStart: Int,
        consumedLength: Int
    ) -> (start: Int, length: Int) {
        let units = Array(text.utf16)
        let start = max(0, min(consumedStart, units.count))
        guard consumedLength > 0 else { return (start, 0) }

        let remaining = units.count - start
        var end = consumedLength >= remaining ? units.count : start + consumedLength
        while end > start, isMandatoryBreak(units[end - 1]) {
            end -= 1
        }
        return (start, end - start)
    }
}

// MARK: - Coverage

public enum FontCoverage {
    /// Which corpus characters this font has no glyph for.
    ///
    /// Worth having as a first-class probe: a subsetted CJK font silently
    /// renders .notdef boxes, and every downstream measurement (line breaking,
    /// pagination) then looks fine while being meaningless.
    public static func measure(font: CTFont, characters: [Character]) -> GlyphCoverage {
        var missing: [UInt32] = []
        for character in characters {
            let units = Array(String(character).utf16)
            guard !units.isEmpty, let scalar = character.unicodeScalars.first else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            let ok = CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
            if !ok || glyphs.contains(0) {
                missing.append(scalar.value)
            }
        }
        return GlyphCoverage(testedCharacters: characters.count, missingScalars: missing)
    }
}

// MARK: - Horizontal layout

public struct LayoutInput {
    public var text: String
    public var font: CTFont
    public var fontSize: CGFloat
    public var measureWidth: CGFloat
    public var pageHeight: CGFloat
    public var lineSpacing: CGFloat
    /// nil means "do not tag the run". This is the variable the kinsoku probe
    /// exists to measure: `kCTLanguageAttributeName` is documented to enable
    /// locale-specific line breaking, but the extent is undocumented.
    public var languageTag: String?
    public var label: String
    public var writingMode: String
    public var vertical: Bool
    /// Optional ruby annotation applied to `rubyRange`.
    public var ruby: (annotation: String, range: NSRange)?
    /// Travels with the layout so the probe can report the factor it actually
    /// asked for. Hardcoded inside `attributedString`, a wrong value would leave
    /// every assertion green while the experiment silently changed.
    public var rubySizeFactor: CGFloat

    public init(
        text: String,
        font: CTFont,
        fontSize: CGFloat,
        measureWidth: CGFloat,
        pageHeight: CGFloat,
        lineSpacing: CGFloat = 0,
        languageTag: String? = nil,
        label: String,
        writingMode: String = "horizontal-tb",
        vertical: Bool = false,
        ruby: (annotation: String, range: NSRange)? = nil,
        rubySizeFactor: CGFloat = 0.5
    ) {
        self.text = text
        self.font = font
        self.fontSize = fontSize
        self.measureWidth = measureWidth
        self.pageHeight = pageHeight
        self.lineSpacing = lineSpacing
        self.languageTag = languageTag
        self.label = label
        self.writingMode = writingMode
        self.vertical = vertical
        self.ruby = ruby
        self.rubySizeFactor = rubySizeFactor
    }
}

public enum TextLayout {
    public static func attributedString(_ input: LayoutInput) -> NSAttributedString {
        // Raw CoreText keys rather than AppKit's `.font`: this target imports
        // Foundation and CoreText, not AppKit, and the value is a CTFont.
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): input.font
        ]
        if let languageTag = input.languageTag {
            attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] = languageTag
        }
        if input.vertical {
            attributes[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = true
        }
        let string = NSMutableAttributedString(string: input.text, attributes: attributes)

        if let ruby = input.ruby, ruby.range.location >= 0,
           ruby.range.location + ruby.range.length <= string.length {
            // CTRubyAnnotationCreateWithAttributes takes no size-factor
            // argument — it travels in the attributes dictionary, keyed by
            // kCTRubyAnnotationSizeFactorAttributeName. (The sizeFactor
            // parameter belongs to CTRubyAnnotationCreate.)
            let annotationAttributes: [CFString: Any] = [
                kCTRubyAnnotationSizeFactorAttributeName: input.rubySizeFactor
            ]
            let annotation = CTRubyAnnotationCreateWithAttributes(
                .center,
                .auto,
                .before,
                ruby.annotation as CFString,
                annotationAttributes as CFDictionary
            )
            string.addAttribute(
                NSAttributedString.Key(kCTRubyAnnotationAttributeName as String),
                value: annotation,
                range: ruby.range
            )
        }
        return string
    }

    /// Typesets the text into lines of at most `measureWidth`, then cuts pages
    /// at `pageHeight`.
    ///
    /// Deliberately does NOT use `CTFramesetterSuggestFrameSizeWithConstraints`:
    /// its `fitRange` out-parameter assumes the horizontal fill model and is not
    /// trustworthy under `CTFrameProgression.rightToLeft`. Lines are measured
    /// one at a time so the geometry stays ours — see ADR-0006.
    ///
    /// Each line records two ranges: what it consumed (which advances the cursor,
    /// and includes any mandatory break) and its content (which 禁則検査 and later
    /// Native Position ranges measure against). See `LineRecord`.
    public static func layout(_ input: LayoutInput) throws -> (report: LayoutReport, frame: CTFrame?) {
        let attributed = attributedString(input)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)

        var lines: [LineRecord] = []
        var pages: [PageRecord] = []
        var pageStartLine = 0
        var pageTop: CGFloat = 0
        var y: CGFloat = 0
        var start = 0
        let total = attributed.length

        while start < total {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(input.measureWidth))
            guard count > 0 else { break }

            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let lineHeight = ascent + descent + leading + input.lineSpacing

            // Start a new page when this line would overflow the page box.
            if y > pageTop, y + lineHeight > pageTop + input.pageHeight {
                pages.append(makePage(index: pages.count, lines: lines, from: pageStartLine))
                pageStartLine = lines.count
                pageTop = y
            }

            let content = MandatoryBreak.contentRange(
                of: input.text,
                consumedStart: start,
                consumedLength: count
            )
            lines.append(try LineRecord(
                index: lines.count,
                utf16Start: start,
                utf16Length: count,
                contentStart: content.start,
                contentLength: content.length,
                originX: 0,
                originY: Double(y + ascent),
                width: width,
                ascent: Double(ascent),
                descent: Double(descent),
                leading: Double(leading)
            ))

            y += lineHeight
            start += count
        }

        pages.append(makePage(index: pages.count, lines: lines, from: pageStartLine))

        let single = CTLineCreateWithAttributedString(attributed)
        let singleWidth = CTLineGetTypographicBounds(single, nil, nil, nil)

        let report = try LayoutReport(
            label: input.label,
            writingMode: input.writingMode,
            languageTag: input.languageTag,
            measureWidth: Double(input.measureWidth),
            pageHeight: Double(input.pageHeight),
            fontSize: Double(input.fontSize),
            lineSpacing: Double(input.lineSpacing),
            lineCount: lines.count,
            pageCount: pages.count,
            lines: lines,
            pages: pages,
            singleLineWidth: singleWidth,
            totalTextHeight: Double(y)
        )
        return (report, makeFrame(attributed: attributed, input: input))
    }

    private static func makePage(index: Int, lines: [LineRecord], from startLine: Int) -> PageRecord {
        let slice = lines[startLine...]
        let beginning = slice.first?.utf16Start ?? 0
        let end = slice.last.map { $0.utf16Start + $0.utf16Length } ?? beginning
        return PageRecord(
            index: index,
            firstLine: startLine,
            lineCount: slice.count,
            utf16Start: beginning,
            utf16Length: end - beginning
        )
    }

    /// A frame for rendering and for the vertical probe. `kCTFrameProgression`
    /// must be passed as its numeric raw value — passing the Swift enum silently
    /// does nothing.
    public static func makeFrame(attributed: NSAttributedString, input: LayoutInput) -> CTFrame? {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let box = input.vertical
            ? CGRect(x: 0, y: 0, width: input.pageHeight, height: input.measureWidth)
            : CGRect(x: 0, y: 0, width: input.measureWidth, height: input.pageHeight)
        let path = CGPath(rect: box, transform: nil)
        let frameAttributes: [CFString: Any] = [
            kCTFrameProgressionAttributeName: NSNumber(
                value: input.vertical
                    ? CTFrameProgression.rightToLeft.rawValue
                    : CTFrameProgression.topToBottom.rawValue
            )
        ]
        return CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            frameAttributes as CFDictionary
        )
    }

    /// The vertical space one line wants. Used to make a frame exactly one
    /// column wide; measured off a single ideograph so the pitch does not depend
    /// on the corpus.
    static func lineExtent(font: CTFont, lineSpacing: CGFloat) -> CGFloat {
        let probe = NSAttributedString(
            string: "永",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(
            CTLineCreateWithAttributedString(probe), &ascent, &descent, &leading
        )
        return ascent + descent + leading + lineSpacing
    }

    /// Column-by-column chaining via `CTFrameGetVisibleStringRange`, which is
    /// the documented frame-chaining primitive. Used only by the vertical probe,
    /// where the horizontal fill model does not apply.
    ///
    /// The box is ONE column wide on purpose. Under `rightToLeft` progression the
    /// columns advance across the box's width, so that width IS the column pitch:
    /// a box as wide as the page makes every frame hold a whole page of vertical
    /// lines, and `columns` silently starts counting pages instead of columns.
    /// That is what the first real run reported — 407 UTF-16 units "in 2 columns",
    /// which is really two pages of roughly seventeen lines each.
    ///
    /// `measureWidth` is the length of a column (the vertical space available),
    /// which is why the box is built as pitch × measureWidth.
    public static func chainColumns(_ input: LayoutInput, maxColumns: Int) -> (columns: Int, consumed: Int, terminated: Bool) {
        let attributed = attributedString(input)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let columnWidth = lineExtent(font: input.font, lineSpacing: input.lineSpacing)
        let columnHeight = input.measureWidth
        let frameAttributes: [CFString: Any] = [
            kCTFrameProgressionAttributeName: NSNumber(
                value: CTFrameProgression.rightToLeft.rawValue
            )
        ]

        var consumed = 0
        var columns = 0
        let total = attributed.length

        while consumed < total && columns < maxColumns {
            let path = CGPath(
                rect: CGRect(x: 0, y: 0, width: columnWidth, height: columnHeight),
                transform: nil
            )
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: consumed, length: 0),
                path,
                frameAttributes as CFDictionary
            )
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            consumed += visible.length
            columns += 1
        }

        return (columns, consumed, consumed >= total)
    }
}

// MARK: - Rendering

public enum Renderer {
    /// Renders a frame to PNG and reports how many bytes landed on disk.
    ///
    /// This is a human-review artifact, never a pixel gate — see ADR-0011. But
    /// "not a gate" is not the same as "unverified": a review image that silently
    /// failed to appear is indistinguishable from a successful run, so this
    /// throws rather than returning a flag a caller can drop on the floor, and it
    /// confirms the file is actually there and non-empty before returning.
    public static func writePNG(frame: CTFrame, size: CGSize, to url: URL) throws -> Int {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())

        // A frame draws its first line at the TOP of its own layout path, so a
        // frame built for a much larger box puts the text far above the bitmap
        // and produces a blank image — which satisfies every "the file exists and
        // is not empty" check, and is how `ruby.png` shipped empty from the first
        // run. Comparing the frame's own path against the bitmap is what turns
        // that into a loud failure. (The context is 1:1, so points == pixels.)
        let framePath: CGPath? = CTFrameGetPath(frame)
        guard let box = framePath?.boundingBoxOfPath else {
            throw SpikeError.renderingFailed("frame carries no layout path")
        }
        guard box.width <= CGFloat(width), box.height <= CGFloat(height) else {
            throw SpikeError.renderingFailed(
                "frame is laid out for \(Int(box.width))x\(Int(box.height))pt but the bitmap is "
                    + "\(width)x\(height)px — the text would land off-canvas"
            )
        }

        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              )
        else { throw SpikeError.renderingFailed("could not create a \(width)x\(height) bitmap context") }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.textMatrix = .identity
        CTFrameDraw(frame, context)

        guard let image = context.makeImage() else {
            throw SpikeError.renderingFailed("could not snapshot the context")
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw SpikeError.renderingFailed("could not create a PNG destination at \(url.lastPathComponent)")
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SpikeError.renderingFailed("could not encode \(url.lastPathComponent)")
        }

        // The encoder said yes; the filesystem gets the final word.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let byteCount = (attributes[.size] as? NSNumber)?.intValue,
              byteCount > 0
        else {
            throw SpikeError.renderingFailed("\(url.lastPathComponent) is missing or empty after encoding")
        }
        return byteCount
    }
}

// MARK: - Kinsoku inspection

public enum Kinsoku {
    /// The fraction of the measurement canvas the content may occupy before the
    /// layout can no longer be attributed to line breaking rather than to running
    /// out of room.
    public static let canvasHeadroom: Double = 0.9

    public struct Violations: Sendable {
        public var lineStartsWithProhibited: Int
        public var lineEndsWithProhibited: Int
        /// Lines whose consumed range outran their content range, i.e. lines that
        /// carried a mandatory break control.
        public var hardBreakLines: Int
        /// Lines with non-empty content, i.e. lines whose end was actually
        /// inspected.
        public var inspectedLineEnds: Int

        public init(
            lineStartsWithProhibited: Int,
            lineEndsWithProhibited: Int,
            hardBreakLines: Int,
            inspectedLineEnds: Int
        ) {
            self.lineStartsWithProhibited = lineStartsWithProhibited
            self.lineEndsWithProhibited = lineEndsWithProhibited
            self.hardBreakLines = hardBreakLines
            self.inspectedLineEnds = inspectedLineEnds
        }

        public var total: Int { lineStartsWithProhibited + lineEndsWithProhibited }

        /// Folds one more layout's inspection into this total, so a sweep can
        /// accumulate per arm without the caller open-coding four additions.
        public mutating func add(_ other: Violations) {
            lineStartsWithProhibited += other.lineStartsWithProhibited
            lineEndsWithProhibited += other.lineEndsWithProhibited
            hardBreakLines += other.hardBreakLines
            inspectedLineEnds += other.inspectedLineEnds
        }

        /// True when the measurement could not have detected a line-end
        /// violation: there were hard-broken lines, yet no line end was ever
        /// looked at. This is the exact fingerprint of the bug the consumed/
        /// content split exists to prevent, so the report can expose it on its
        /// own rather than depending on someone noticing a suspicious zero.
        public var lineEndChecksWereBypassed: Bool {
            hardBreakLines > 0 && inspectedLineEnds == 0
        }
    }

    /// Counts lines that begin or end with a character that 禁則処理 forbids.
    ///
    /// Measured against each line's *content* range: a line's consumed range ends
    /// with the mandatory break that terminated it, and testing that would mean
    /// every paragraph-final line silently skipped its end check.
    public static func inspect(lines: [LineRecord], in text: String) -> Violations {
        let units = Array(text.utf16)
        var startViolations = 0
        var endViolations = 0
        var hardBreakLines = 0
        var inspectedLineEnds = 0

        for line in lines {
            if line.utf16Length > line.contentLength {
                hardBreakLines += 1
            }
            guard line.contentLength > 0 else { continue }
            inspectedLineEnds += 1

            if let character = character(in: units, at: line.contentStart),
               Fixture.prohibitedAtLineStart.contains(character) {
                startViolations += 1
            }
            if let character = character(in: units, at: line.contentStart + line.contentLength - 1),
               Fixture.prohibitedAtLineEnd.contains(character) {
                endViolations += 1
            }
        }
        return Violations(
            lineStartsWithProhibited: startViolations,
            lineEndsWithProhibited: endViolations,
            hardBreakLines: hardBreakLines,
            inspectedLineEnds: inspectedLineEnds
        )
    }

    /// The probe's decision.
    public struct Decision: Sendable {
        public var execution: ProbeOutcome.Execution
        public var finding: ProbeOutcome.Finding?
        public var detail: String
    }

    /// Decides what the kinsoku probe may conclude.
    ///
    /// Kept pure and separate from the probe because this rule was wrong once,
    /// and being wrong here is invisible: the first real run looked only at the
    /// tagged arm and reported "yes" for a sweep in which the untagged control
    /// had also seen zero violations — a measurement with nothing to measure.
    ///
    /// Experiment validity comes first, because neither of those failures says
    /// anything about the language tag.
    public static func decide(
        tagged: Violations,
        untagged: Violations,
        contentHeight: Double,
        canvasHeight: Double
    ) -> Decision {
        let hardBreakLines = tagged.hardBreakLines + untagged.hardBreakLines
        let inspectedLineEnds = tagged.inspectedLineEnds + untagged.inspectedLineEnds

        if hardBreakLines > 0 && inspectedLineEnds == 0 {
            return Decision(
                execution: .inconclusive,
                finding: nil,
                detail: "\(hardBreakLines) hard-broken lines but no line end was inspected — "
                    + "the line-end check was bypassed, so this probe cannot conclude"
            )
        }
        if contentHeight >= canvasHeight * canvasHeadroom {
            return Decision(
                execution: .inconclusive,
                finding: nil,
                detail: "content height \(String(format: "%.1f", contentHeight))pt reached "
                    + "\(Int(canvasHeadroom * 100))% of the \(Int(canvasHeight))pt canvas — "
                    + "the layout may have been clamped, so this probe cannot conclude"
            )
        }

        // The untagged arm is a control, not decoration: the question is whether
        // the tag BUYS 禁則処理, and a control that is equally clean means there
        // was nothing for it to buy.
        if tagged.total == 0 && untagged.total == 0 {
            return Decision(
                execution: .inconclusive,
                finding: nil,
                detail: "both the tagged run and its untagged control were clean across the sweep "
                    + "(\(inspectedLineEnds) line ends inspected) — the tag made no measurable "
                    + "difference, so this probe cannot conclude"
            )
        }
        if tagged.total == 0 {
            return Decision(
                execution: .measured,
                finding: .yes,
                detail: "the tagged run had no violations while the untagged control produced "
                    + "\(untagged.total) — the tag removed violations the control showed"
            )
        }
        return Decision(
            execution: .measured,
            finding: .no,
            detail: "\(tagged.total) violations remain with the run tagged \"ja\" "
                + "(untagged produced \(untagged.total))"
        )
    }

    private static func character(in units: [UInt16], at index: Int) -> Character? {
        guard index >= 0, index < units.count else { return nil }
        // Line boundaries produced by CoreText are already at cluster edges, so a
        // single UTF-16 unit is enough for the BMP test corpus.
        guard let scalar = Unicode.Scalar(units[index]) else { return nil }
        return Character(scalar)
    }
}
