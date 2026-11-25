import AppKit
import CoreText

// MARK: - Pipeline

/// Everything needed to show a file: the document and, when it has a language, Lithe's
/// highlighter for it. Nothing is tokenized yet; the view asks for the lines it draws.
public struct PreparedPreview {
    public let document: TextDocument
    public let syntax: SyntaxDocument?
    /// The settings it was prepared with (config.yaml).
    public let config: CodeLookConfig
    public let milliseconds: Double

    public var style: PreviewStyle { config.style }
    public var suggestedSize: CGSize { style.metrics.suggestedSize(for: document) }
}

public enum PreviewPipeline {
    /// Throws `TextLoaderError.binary` for binary files. `options` default to the settings'.
    public static func prepare(url: URL, options: DocumentOptions? = nil) throws -> PreparedPreview {
        let start = DispatchTime.now()
        let config = CodeLookConfig.current()
        let doc = try TextDocument.load(url: url, options: options ?? config.options)
        let syntax = doc.syntax.map { SyntaxDocument(language: $0, text: doc.string(0 ..< doc.length)) }
        return PreparedPreview(document: doc, syntax: syntax, config: config, milliseconds: elapsed(since: start))
    }

    static func elapsed(since t: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6
    }
}

// MARK: - Container

/// Header bar (language, size, notes) above a scrolling `CodeTextView`.
public final class CodePreviewView: NSView {
    public static let headerHeight: CGFloat = 26

    private let header = HeaderBar()
    private let scrollView = NSScrollView()
    public let codeView = CodeTextView()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        header.frame = NSRect(x: 0, y: 0, width: frame.width, height: Self.headerHeight)
        header.autoresizingMask = [.width, .maxYMargin]
        scrollView.frame = NSRect(x: 0, y: Self.headerHeight, width: frame.width,
                                  height: max(0, frame.height - Self.headerHeight))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = codeView.style.backgroundColor
        scrollView.documentView = codeView
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged),
                                               name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        addSubview(scrollView)
        addSubview(header)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }

    @objc private func clipFrameChanged() { codeView.fitToClipView() }

    public func show(_ p: PreparedPreview) {
        codeView.setDocument(p.document, syntax: p.syntax, style: p.style)
        scrollView.backgroundColor = p.style.backgroundColor
        header.configure(p.document, problems: p.config.problems)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Scrolls so that `line` (0-based) is at the top.
    public func scroll(toLine line: Int) {
        let y = codeView.yOffset(ofLine: line)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, codeView.frame.height - scrollView.contentView.bounds.height))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// Language · lines · encoding · size · notes.
final class HeaderBar: NSView {
    static let barColor = NSColor(name: nil) { $0.isDark ? NSColor(hex: 0x28292C) : NSColor(hex: 0xF7F8FA) }
    static let borderColor = NSColor(name: nil) { $0.isDark ? NSColor(hex: 0x2E3036) : NSColor(hex: 0xEBECF0) }
    static let noteColor = NSColor(name: nil) { $0.isDark ? NSColor(hex: 0xE0A33B) : NSColor(hex: 0xC27D04) }

    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    static func label(_ s: String, color: NSColor = .secondaryLabelColor, bold: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = bold ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 11)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    /// `problems`: what config.yaml got wrong, shown as one note (all of them in its tooltip).
    func configure(_ doc: TextDocument, problems: [String] = []) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let lang = Self.label(doc.languageName, color: .labelColor, bold: true)
        lang.toolTip = doc.reason
        lang.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(lang)
        stack.addArrangedSubview(Self.label(L10n.lines(doc.lineCount)))
        stack.addArrangedSubview(Self.label(doc.encoding))
        stack.addArrangedSubview(Self.label(L10n.size(doc.fileSize)))
        for n in doc.notes { stack.addArrangedSubview(Self.label(n, color: Self.noteColor)) }
        if let first = problems.first {
            let more = problems.count > 1 ? " (+\(problems.count - 1))" : ""
            let l = Self.label("⚠︎ config.yaml: " + first + more, color: Self.noteColor)
            l.toolTip = problems.joined(separator: "\n")
            stack.addArrangedSubview(l)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.barColor.setFill()
        bounds.fill()
        Self.borderColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Text view

/// Read-only code view that only ever lays out and draws the rows on screen.
///
/// Every row has the same height, so the document height, row positions and the scroll bar are
/// exact without laying out anything. Long lines are word-wrapped by columns (monospaced font),
/// which only needs the per-line widths `TextDocument` computed; wrap points are only searched in
/// lines wider than the view. Rows are typeset (CTLine) when they first become visible, colored
/// by Lithe's highlighter, which only tokenizes the lines asked for.
public final class CodeTextView: NSView {
    /// Lithe's editor colors (its workbench theme) unless the
    /// settings give others; the text color is the syntax theme's.
    struct Palette {
        let dark: Bool
        let background: CGColor
        let text: CGColor
        let lineNumber: CGColor
        let selection: CGColor
        let selectionIdle: CGColor

        init(dark: Bool, colors: CodeLookConfig.Raw.Colors) {
            self.dark = dark
            func c(_ set: UInt32?, _ lightHex: UInt32, _ darkHex: UInt32) -> CGColor {
                NSColor(hex: set ?? (dark ? darkHex : lightHex)).cgColor
            }
            background = c(colors.background, 0xFFFFFF, 0x191A1C)
            text = NSColor(hex: colors.text).cgColor
            lineNumber = c(colors.lineNumber, 0x6C707E, 0x868A91)
            selection = c(colors.selection, 0xD5E1FF, 0x2E436E)
            selectionIdle = colors.selection.map { NSColor(hex: $0).withAlphaComponent(0.6).cgColor }
                ?? c(nil, 0xE9EAEE, 0x33353B)
        }
    }

    public struct Metrics {
        let font: CTFont
        let boldFont: CTFont
        let italicFont: CTFont
        let boldItalicFont: CTFont
        let lineHeight: CGFloat
        let charWidth: CGFloat
        let baseline: CGFloat
        let lineNumbers: Bool
        let insetTop: CGFloat = 6
        let insetBottom: CGFloat = 16
        let padRight: CGFloat = 16
        let paragraphStyle: CTParagraphStyle

        /// `lineHeight` in points; at least the font's own.
        init(fonts: FontSet, lineHeight: CGFloat, tabWidth: Int, lineNumbers: Bool) {
            font = fonts.regular
            boldFont = fonts.bold
            italicFont = fonts.italic
            boldItalicFont = fonts.boldItalic
            self.lineNumbers = lineNumbers
            let probe = CTLineCreateWithAttributedString(NSAttributedString(string: String(repeating: "0", count: 10),
                                                                            attributes: [.font: font]))
            charWidth = CGFloat(CTLineGetTypographicBounds(probe, nil, nil, nil)) / 10
            let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
            // Whole points, so rows do not land between pixels.
            self.lineHeight = max(lineHeight, ascent + descent).rounded(.up)
            baseline = ((self.lineHeight - (ascent + descent)) / 2 + ascent).rounded()
            var interval = charWidth * CGFloat(max(1, tabWidth))
            var stops = [CTTextTab]() as CFArray
            paragraphStyle = withUnsafeBytes(of: &interval) { ip in
                withUnsafeBytes(of: &stops) { sp in
                    let settings = [
                        CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: ip.baseAddress!),
                        CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: sp.baseAddress!),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }

        func gutterWidth(lines: Int) -> CGFloat {
            lineNumbers ? CGFloat(max(String(lines).count, 2)) * charWidth + 22 : 0
        }
        func textX(lines: Int) -> CGFloat { lineNumbers ? gutterWidth(lines: lines) + 6 : 12 }

        func suggestedSize(for doc: TextDocument) -> CGSize {
            let w = textX(lines: doc.lineCount) + CGFloat(min(doc.longestCols, 140)) * charWidth + padRight + 20
            let h = CGFloat(doc.lineCount) * lineHeight + insetTop + insetBottom + CodePreviewView.headerHeight
            return CGSize(width: min(1100, max(600, w)).rounded(), height: min(860, max(240, h)).rounded())
        }
    }

    /// Font, colors and layout; replaced with each document (the settings may have changed).
    public private(set) var style: PreviewStyle
    private var m: Metrics
    public private(set) var document: TextDocument?
    private var syntax: SyntaxDocument?

    // Rows: line i starts at row rowStart[i]; lines wider than the view have extra break points.
    private var wrapCols = 0
    private var rowStart: [Int32] = []          // empty = one row per line
    private var breaks: [Int: [Int32]] = [:]    // line -> start offsets of its 2nd, 3rd … rows
    private var totalRows = 0
    private var textX: CGFloat = 0
    private var gutterWidth: CGFloat = 0

    private var palette: Palette
    private var colors: [UInt32: CGColor] = [:]
    private var rowCache: [Int: CTLine] = [:]
    private var numberCache: [Int: CTLine] = [:]

    // Selection (UTF-16 offsets)
    private var anchor = 0
    private var head = 0
    private var dragOrigin: Range<Int> = 0 ..< 0
    private var dragUnit = 1   // 1 char, 2 word, 3 line
    public var selectedRange: Range<Int> { min(anchor, head) ..< max(anchor, head) }

    public override init(frame: NSRect) {
        style = CodeLookConfig.current().style
        m = style.metrics
        palette = style.palette(dark: false)
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { document != nil }

    // MARK: Content

    func setDocument(_ doc: TextDocument, syntax: SyntaxDocument?, style: PreviewStyle) {
        document = doc
        self.style = style
        m = style.metrics
        palette = style.palette(dark: palette.dark)
        self.syntax?.onChange = nil
        self.syntax = syntax
        // Lines Lithe colored from a guessed start state and later found different.
        syntax?.onChange = { [weak self, weak syntax] _, _ in
            guard let self, self.syntax === syntax else { return }
            self.rowCache.removeAll(keepingCapacity: true)
            self.needsDisplay = true
        }
        anchor = 0; head = 0
        gutterWidth = m.gutterWidth(lines: doc.lineCount)
        textX = m.textX(lines: doc.lineCount)
        wrapCols = 0
        invalidateCaches()
        fitToClipView()
        needsDisplay = true
    }

    private func invalidateCaches() {
        rowCache.removeAll(keepingCapacity: true)
        numberCache.removeAll(keepingCapacity: true)
    }

    /// Matches the clip view's width and re-wraps when the number of columns changed.
    func fitToClipView() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let width = clip.bounds.width
        let cols = max(16, Int((width - textX - m.padRight) / m.charWidth))
        if cols != wrapCols {
            wrapCols = cols
            computeRows()
            rowCache.removeAll(keepingCapacity: true)
        }
        let height = max(clip.bounds.height, m.insetTop + CGFloat(totalRows) * m.lineHeight + m.insetBottom)
        if frame.size != NSSize(width: width, height: height) { setFrameSize(NSSize(width: width, height: height)) }
        needsDisplay = true
    }

    private func computeRows() {
        breaks.removeAll()
        rowStart = []
        guard let doc = document else { totalRows = 0; return }
        guard doc.longestCols > wrapCols else { totalRows = doc.lineCount; return }
        var starts = [Int32]()
        starts.reserveCapacity(doc.lineCount + 1)
        var row = 0
        doc.units.withUnsafeBufferPointer { buf in
            for line in 0 ..< doc.lineCount {
                starts.append(Int32(row))
                row += 1
                if Int(doc.lineCols[line]) > wrapCols {
                    let b = Self.wrap(buf, doc.lineRange(line), cols: wrapCols, tab: doc.tabWidth)
                    if !b.isEmpty { breaks[line] = b; row += b.count }
                }
            }
        }
        starts.append(Int32(row))
        rowStart = starts
        totalRows = row
    }

    /// Start offsets of the continuation rows of one line: break after spaces / wide characters
    /// when possible, otherwise exactly at the column limit.
    static func wrap(_ buf: UnsafeBufferPointer<UInt16>, _ range: Range<Int>, cols: Int, tab: Int) -> [Int32] {
        var out: [Int32] = []
        var col = 0
        var rowBegin = range.lowerBound
        var lastBreak = -1
        var i = range.lowerBound
        while i < range.upperBound {
            let u = buf[i]
            let step = (0xD800 ... 0xDBFF).contains(u) && i + 1 < range.upperBound ? 2 : 1
            var next = TextDocument.advance(col, u, tab: tab)
            if next > cols && col > 0 {
                let brk = lastBreak > rowBegin ? lastBreak : i
                out.append(Int32(brk))
                rowBegin = brk
                lastBreak = -1
                col = 0
                var j = brk
                while j < i { col = TextDocument.advance(col, buf[j], tab: tab); j += 1 }
                next = TextDocument.advance(col, u, tab: tab)
            }
            col = next
            if u == 32 || u == 9 || TextDocument.width(u) == 2 { lastBreak = i + step }
            i += step
        }
        return out
    }

    private func line(ofRow row: Int) -> (line: Int, segment: Int) {
        if rowStart.isEmpty { return (row, 0) }
        var lo = 0, hi = rowStart.count - 2
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Int(rowStart[mid]) <= row { lo = mid } else { hi = mid - 1 }
        }
        return (lo, row - Int(rowStart[lo]))
    }

    private func range(line: Int, segment: Int) -> Range<Int> {
        let full = document!.lineRange(line)
        guard let b = breaks[line], !b.isEmpty else { return full }
        let s = segment == 0 ? full.lowerBound : Int(b[segment - 1])
        let e = segment < b.count ? Int(b[segment]) : full.upperBound
        return s ..< e
    }

    func yOffset(ofLine line: Int) -> CGFloat {
        let row = rowStart.isEmpty ? line : Int(rowStart[max(0, min(line, rowStart.count - 1))])
        return m.insetTop + CGFloat(row) * m.lineHeight
    }

    // MARK: Typesetting

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [.font: m.font,
         NSAttributedString.Key(kCTForegroundColorAttributeName as String): palette.text,
         NSAttributedString.Key(kCTParagraphStyleAttributeName as String): m.paragraphStyle]
    }

    private func color(_ rgb: UInt32) -> CGColor {
        if let c = colors[rgb] { return c }
        let c = NSColor(hex: rgb).cgColor
        colors[rgb] = c
        return c
    }

    private func ctLine(row: Int, line: Int, range r: Range<Int>) -> CTLine {
        if let cached = rowCache[row] { return cached }
        if rowCache.count > 3000 { rowCache.removeAll(keepingCapacity: true) }
        let doc = document!
        let attr = NSMutableAttributedString(string: doc.string(r), attributes: baseAttributes())
        if let syntax {
            // Runs are per line; a wrapped row is a slice of it.
            let lineStart = Int(doc.lineStarts[line])
            let lo = r.lowerBound - lineStart, hi = r.upperBound - lineStart
            let runs = syntax.runs(line: line, dark: palette.dark)
            let fgKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
            let underlineKey = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)
            for (i, run) in runs.enumerated() {
                let s = max(run.start, lo), e = min(i + 1 < runs.count ? runs[i + 1].start : hi, hi)
                guard s < e else { continue }
                let nr = NSRange(location: s - lo, length: e - s)
                attr.addAttribute(fgKey, value: color(run.color), range: nr)
                switch run.font & 3 {
                case 1: attr.addAttribute(.font, value: m.italicFont, range: nr)
                case 2: attr.addAttribute(.font, value: m.boldFont, range: nr)
                case 3: attr.addAttribute(.font, value: m.boldItalicFont, range: nr)
                default: break
                }
                if run.font & 4 != 0 { attr.addAttribute(underlineKey, value: CTUnderlineStyle.single.rawValue, range: nr) }
            }
        }
        let line = CTLineCreateWithAttributedString(attr)
        rowCache[row] = line
        return line
    }

    private func numberLine(_ line: Int) -> CTLine {
        if let cached = numberCache[line] { return cached }
        if numberCache.count > 3000 { numberCache.removeAll(keepingCapacity: true) }
        let attr = NSAttributedString(string: String(line + 1), attributes: [
            .font: m.font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): palette.lineNumber])
        let l = CTLineCreateWithAttributedString(attr)
        numberCache[line] = l
        return l
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = effectiveAppearance.isDark
        if dark != palette.dark {
            palette = style.palette(dark: dark)
            invalidateCaches()
            needsDisplay = true
        }
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        palette = style.palette(dark: (newWindow?.effectiveAppearance ?? effectiveAppearance).isDark)
        invalidateCaches()
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(palette.background)
        ctx.fill(dirtyRect)
        guard document != nil, totalRows > 0 else { return }

        let lh = m.lineHeight
        let first = max(0, Int(floor((dirtyRect.minY - m.insetTop) / lh)))
        let last = min(totalRows - 1, Int(ceil((dirtyRect.maxY - m.insetTop) / lh)))
        guard first <= last else { return }

        // Tokenize what is about to be drawn, a screen of margin included, in one go.
        if let syntax {
            let span = last - first
            syntax.prepare(line(ofRow: max(0, first - span)).line, line(ofRow: min(totalRows - 1, last + span)).line)
        }

        let sel = selectedRange
        let active = window?.isKeyWindow == true && window?.firstResponder === self
        let selColor = active ? palette.selection : palette.selectionIdle
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setShouldSmoothFonts(false)

        for row in first ... last {
            let (line, seg) = line(ofRow: row)
            let r = range(line: line, segment: seg)
            let y = m.insetTop + CGFloat(row) * lh
            let ct = ctLine(row: row, line: line, range: r)

            // selection
            if !sel.isEmpty && sel.lowerBound <= r.upperBound && sel.upperBound > r.lowerBound
                || (sel.lowerBound < r.lowerBound && sel.upperBound > r.lowerBound) {
                let a = max(sel.lowerBound, r.lowerBound), b = min(sel.upperBound, r.upperBound)
                let past = sel.upperBound > r.upperBound
                if a < b || past {
                    let x1 = textX + CTLineGetOffsetForStringIndex(ct, a - r.lowerBound, nil)
                    let x2 = past ? bounds.maxX : textX + CTLineGetOffsetForStringIndex(ct, b - r.lowerBound, nil)
                    ctx.setFillColor(selColor)
                    ctx.fill(CGRect(x: x1, y: y, width: max(0, x2 - x1), height: lh))
                }
            }

            ctx.textPosition = CGPoint(x: textX, y: y + m.baseline)
            CTLineDraw(ct, ctx)

            if seg == 0 && m.lineNumbers {
                let n = numberLine(line)
                let w = CGFloat(CTLineGetTypographicBounds(n, nil, nil, nil))
                ctx.textPosition = CGPoint(x: gutterWidth - 10 - w, y: y + m.baseline)
                CTLineDraw(n, ctx)
            }
        }
    }

    // MARK: Selection

    private func offset(at p: NSPoint) -> Int {
        guard let doc = document, totalRows > 0 else { return 0 }
        let rowF = (p.y - m.insetTop) / m.lineHeight
        if rowF < 0 { return 0 }
        let row = Int(rowF)
        if row >= totalRows { return doc.length }
        let (line, seg) = line(ofRow: row)
        let r = range(line: line, segment: seg)
        if p.x <= textX { return r.lowerBound }
        let idx = CTLineGetStringIndexForPosition(ctLine(row: row, line: line, range: r), CGPoint(x: p.x - textX, y: 0))
        return idx == kCFNotFound ? r.lowerBound : min(r.lowerBound + idx, r.upperBound)
    }

    private func unitRange(at offset: Int, unit: Int) -> Range<Int> {
        guard let doc = document else { return 0 ..< 0 }
        switch unit {
        case 3:
            let l = doc.lineRange(doc.line(containing: offset))
            return l.lowerBound ..< min(l.upperBound + 1, doc.length)
        case 2:
            let l = doc.lineRange(doc.line(containing: offset))
            func isWord(_ u: UInt16) -> Bool {
                (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 || u >= 0x80
            }
            var s = min(offset, l.upperBound), e = s
            if s < l.upperBound, !isWord(doc.units[s]) { return s ..< s + 1 }
            while s > l.lowerBound, isWord(doc.units[s - 1]) { s -= 1 }
            while e < l.upperBound, isWord(doc.units[e]) { e += 1 }
            return s ..< e
        default:
            return offset ..< offset
        }
    }

    public override func mouseDown(with event: NSEvent) {
        guard document != nil else { return }
        window?.makeFirstResponder(self)
        let o = offset(at: convert(event.locationInWindow, from: nil))
        dragUnit = min(event.clickCount, 3)
        if dragUnit == 1 && event.modifierFlags.contains(.shift) {
            head = o
        } else {
            dragOrigin = unitRange(at: o, unit: max(dragUnit, 1))
            anchor = dragOrigin.lowerBound
            head = dragOrigin.upperBound
        }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard document != nil else { return }
        autoscroll(with: event)
        let o = offset(at: convert(event.locationInWindow, from: nil))
        if dragUnit == 1 {
            head = o
        } else {
            let u = unitRange(at: o, unit: dragUnit)
            if u.lowerBound < dragOrigin.lowerBound {
                anchor = dragOrigin.upperBound; head = u.lowerBound
            } else {
                anchor = dragOrigin.lowerBound; head = max(u.upperBound, dragOrigin.upperBound)
            }
        }
        needsDisplay = true
    }

    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    @objc public func copy(_ sender: Any?) {
        guard let doc = document, !selectedRange.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(doc.string(selectedRange), forType: .string)
    }

    @objc public override func selectAll(_ sender: Any?) {
        guard let doc = document else { return }
        anchor = 0; head = doc.length
        needsDisplay = true
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, window?.firstResponder === self, let c = event.charactersIgnoringModifiers {
            if c == "c", !selectedRange.isEmpty { copy(nil); return true }
            if c == "a" { selectAll(nil); return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: L10n.copy, action: #selector(copy(_:)), keyEquivalent: "c")
        copyItem.target = self
        copyItem.isEnabled = !selectedRange.isEmpty
        menu.autoenablesItems = false
        menu.addItem(copyItem)
        let all = NSMenuItem(title: L10n.selectAll, action: #selector(selectAll(_:)), keyEquivalent: "a")
        all.target = self
        menu.addItem(all)
        return menu
    }

    public override func resetCursorRects() {
        addCursorRect(NSRect(x: textX, y: bounds.minY, width: max(0, bounds.width - textX), height: bounds.height), cursor: .iBeam)
    }
}
