import Foundation

public struct DocumentOptions {
    /// Read at most this many bytes from disk.
    public var maxBytes = 8 * 1024 * 1024
    /// Show at most this many lines.
    public var maxLines = 1_000_000
    /// Columns between tab stops.
    public var tabWidth = 4
    /// Picks the language of a file name before anything else does (the settings' `files`).
    public var languageOverride: ((String) -> ResolvedLanguage?)?

    public init() {}
}

/// A text file prepared for display: UTF-16 code units (what CoreText and selection work in),
/// line starts, per-line display widths in columns, and what language it is.
///
/// Nothing here depends on the view size; wrapping into rows happens in `CodeTextView`.
public final class TextDocument {
    public let fileName: String
    /// The text, newlines normalised to `\n`, without a trailing newline.
    public let units: [UInt16]
    /// `lineStarts[i]` = first unit of line i. One extra entry (`units.count + 1`) closes the
    /// last line, so line i always spans `lineStarts[i] ..< lineStarts[i + 1] - 1`.
    public let lineStarts: [Int32]
    /// Display width of each line in columns (tabs expanded to `tabWidth`, wide CJK = 2).
    public let lineCols: [Int32]
    public let longestCols: Int
    public let tabWidth: Int

    public let languageName: String
    public let reason: String
    /// Lithe language that colors it, nil = plain text.
    public let syntax: String?
    public let encoding: String
    public let fileSize: Int
    public let notes: [String]

    public var length: Int { units.count }
    public var lineCount: Int { lineStarts.count - 1 }

    public func lineRange(_ line: Int) -> Range<Int> {
        Int(lineStarts[line]) ..< Int(lineStarts[line + 1]) - 1
    }

    /// Line containing unit `offset` (the newline belongs to the line it ends).
    public func line(containing offset: Int) -> Int {
        var lo = 0, hi = lineCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Int(lineStarts[mid]) <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func string(_ r: Range<Int>) -> String {
        let lo = max(0, r.lowerBound), hi = min(units.count, r.upperBound)
        guard lo < hi else { return "" }
        return units.withUnsafeBufferPointer { String(utf16CodeUnits: $0.baseAddress! + lo, count: hi - lo) }
    }

    init(fileName: String, units: [UInt16], lineStarts: [Int32], lineCols: [Int32], longestCols: Int, tabWidth: Int,
         languageName: String, reason: String, syntax: String?, encoding: String, fileSize: Int, notes: [String]) {
        self.fileName = fileName
        self.tabWidth = tabWidth
        self.units = units
        self.lineStarts = lineStarts
        self.lineCols = lineCols
        self.longestCols = longestCols
        self.languageName = languageName
        self.reason = reason
        self.syntax = syntax
        self.encoding = encoding
        self.fileSize = fileSize
        self.notes = notes
    }
}

// MARK: - Building

extension TextDocument {
    /// Throws `TextLoaderError.binary` for binary files (Quick Look then shows its own preview).
    public static func load(url: URL, options: DocumentOptions = .init()) throws -> TextDocument {
        let loaded = try TextLoader.load(url: url, maxBytes: options.maxBytes)
        return TextDocument(loaded, fileName: url.lastPathComponent, options: options)
    }

    public convenience init(_ loaded: LoadedText, fileName: String, options: DocumentOptions = .init()) {
        var notes: [String] = []
        if loaded.truncated { notes.append(L10n.truncatedBytes(loaded.fileSize, shown: options.maxBytes)) }
        if let from = loaded.convertedFrom { notes.append(L10n.converted(from)) }

        var source = loaded.text
        // Escape sequences (logs with colors). A byte search: String.contains("\u{1B}") compares
        // Characters and costs ~100 ms on a 5 MB file.
        if source.withUTF8({ b in b.baseAddress.map { memchr($0, 0x1B, b.count) != nil } ?? false }) { source = Self.stripANSI(source) }

        // UTF-16 units with \r\n and \r turned into \n; line starts and widths in the same pass,
        // decoding the UTF-8 directly (iterating String.utf16 is ~30× slower on large files).
        var starts: [Int32] = [0]
        var cols: [Int32] = []
        var col = 0, longest = 0
        var linesTruncated = false
        let tab = max(1, options.tabWidth)
        var units = source.withUTF8 { bytes in
            // A string never has more UTF-16 units than UTF-8 bytes.
            [UInt16](unsafeUninitializedCapacity: bytes.count) { out, count in
                var n = 0, i = 0
                while i < bytes.count {
                    let b = bytes[i]
                    if b < 0x80 {
                        i += 1
                        if b == 10 || b == 13 {
                            if b == 13, i < bytes.count, bytes[i] == 10 { i += 1 }
                            cols.append(Int32(col)); longest = max(longest, col); col = 0
                            if starts.count == options.maxLines { linesTruncated = true; break }
                            out[n] = 10; n += 1
                            starts.append(Int32(n))
                        } else {
                            out[n] = UInt16(b); n += 1
                            col = b == 9 ? (col / tab + 1) * tab : col + 1
                        }
                        continue
                    }
                    var scalar = UInt32(b)
                    if b < 0xE0 {
                        scalar = (scalar & 0x1F) << 6 | UInt32(bytes[i + 1] & 0x3F); i += 2
                    } else if b < 0xF0 {
                        scalar = (scalar & 0x0F) << 12 | UInt32(bytes[i + 1] & 0x3F) << 6 | UInt32(bytes[i + 2] & 0x3F); i += 3
                    } else {
                        scalar = (scalar & 0x07) << 18 | UInt32(bytes[i + 1] & 0x3F) << 12
                            | UInt32(bytes[i + 2] & 0x3F) << 6 | UInt32(bytes[i + 3] & 0x3F); i += 4
                    }
                    if scalar < 0x10000 {
                        out[n] = UInt16(scalar); n += 1
                        col += Self.width(UInt16(scalar))
                    } else {
                        out[n] = UInt16(0xD800 + ((scalar - 0x10000) >> 10))
                        out[n + 1] = UInt16(0xDC00 + (scalar & 0x3FF)); n += 2
                        col += 2
                    }
                }
                count = n
            }
        }
        if linesTruncated {
            // The newline that ended the last kept line was not appended.
        } else if units.last == 10 && starts.count > 1 {
            // Trailing newline: not an extra empty line.
            units.removeLast()
            starts.removeLast()
        } else {
            cols.append(Int32(col)); longest = max(longest, col)
        }
        starts.append(Int32(units.count + 1))
        if linesTruncated { notes.append(L10n.truncatedLines(shown: options.maxLines)) }

        // Which language? Lithe's own file types first, so a file is colored as Lithe's editor
        // colors it; then our table (names Lithe has no type for), then the content.
        var resolved = LanguageResolver.resolve(fileName: fileName)
        if let configured = options.languageOverride?(fileName) {
            resolved = configured
        } else if loaded.convertedFrom != nil {
            resolved = ResolvedLanguage(name: "Property List", syntax: "xml", reason: "binary plist")
        } else if let id = LitheSyntax.language(forPath: fileName), resolved?.syntax != id {
            resolved = ResolvedLanguage(name: LanguageTable.displayName(syntax: id), syntax: id, reason: "Lithe file type")
        }
        if resolved == nil {
            let sample: String = units.isEmpty ? "" : units.withUnsafeBufferPointer {
                String(utf16CodeUnits: $0.baseAddress!, count: min($0.count, 16 * 1024))
            }
            resolved = LanguageResolver.resolve(content: Substring(sample))
        }
        let language = resolved ?? .plain
        var syntax = language.syntax.flatMap { LitheSyntax.has($0) ? $0 : nil }
        // rc and lock files are YAML or JSON (.prettierrc, .eslintrc, composer.lock)
        if syntax == "yaml", units.first(where: { $0 != 32 && $0 != 9 && $0 != 10 }) == 0x7B { syntax = "jsonc" }

        self.init(fileName: fileName, units: units, lineStarts: starts, lineCols: cols, longestCols: longest, tabWidth: tab,
                  languageName: language.name, reason: language.reason, syntax: syntax, encoding: loaded.encoding,
                  fileSize: loaded.fileSize, notes: notes)
    }

    /// Column after drawing unit `u` at column `col` (tab stops every `tab` columns).
    @inline(__always)
    public static func advance(_ col: Int, _ u: UInt16, tab: Int) -> Int {
        if u == 9 { return (col / tab + 1) * tab }
        return col + width(u)
    }

    /// Display columns of one UTF-16 unit: surrogate pairs count once (2 on the high unit),
    /// combining marks / joiners 0, East Asian wide 2, everything else 1.
    @inline(__always)
    public static func width(_ u: UInt16) -> Int {
        if u < 0x300 { return 1 }
        switch u {
        case 0x0300...0x036F, 0x200B...0x200F, 0xFE00...0xFE0F, 0xDC00...0xDFFF: return 0
        case 0xD800...0xDBFF: return 2
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6:
            return 2
        default: return 1
        }
    }

    static func stripANSI(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\u{1B}(?:\\[[0-9;?]*[ -/]*[@-~]|\\][^\u{07}]*\u{07}|[@-Z\\\\-_])") else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }
}

// MARK: - Strings

enum L10n {
    static let zh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    static func number(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    static func lines(_ n: Int) -> String {
        zh ? "\(number(n)) 行" : (n == 1 ? "1 line" : "\(number(n)) lines")
    }
    static func truncatedBytes(_ total: Int, shown: Int) -> String {
        zh ? "文件 \(size(total))，仅显示前 \(size(shown))" : "File is \(size(total)); showing the first \(size(shown))"
    }
    static func truncatedLines(shown: Int) -> String {
        zh ? "仅显示前 \(number(shown)) 行" : "Showing the first \(number(shown)) lines"
    }
    static func converted(_ from: String) -> String { zh ? "已从 \(from) 转换" : "Converted from \(from)" }
    static let copy = zh ? "拷贝" : "Copy"
    static let selectAll = zh ? "全选" : "Select All"
}
