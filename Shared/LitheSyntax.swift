import Foundation

/// Lithe's syntax engine (its editor's TextMate tokenizer and color scheme), linked in from
/// `Bridge/` as `libLitheSyntax.a`. Language IDs are Lithe's: "rust", "shell", "typescriptreact"...
public enum LitheSyntax {
    /// The language Lithe colors a file name with, nil when it has none.
    public static func language(forPath name: String) -> String? {
        var buf = [CChar](repeating: 0, count: 64)
        let n = ls_language_for_path(name, &buf, Int32(buf.count))
        return n > 0 && n < buf.count ? String(cString: buf) : nil
    }

    /// Whether Lithe has a grammar for `id` (or an alias of it, as "bash").
    public static func has(_ id: String) -> Bool { ls_has_language(id) != 0 }

    /// Every language Lithe colors, with its file extensions (`[".rs", ".rlib"]`).
    public static func bundledLanguages() -> [(id: String, extensions: [String])] {
        let size = ls_bundled_languages(nil, 0) + 1
        var buf = [CChar](repeating: 0, count: Int(size))
        ls_bundled_languages(&buf, size)
        return String(cString: buf).split(separator: "\n").map { line in
            let parts = line.split(separator: " ").map(String.init)
            return (parts[0], Array(parts.dropFirst()))
        }
    }

    /// The scheme's text color, 0xRRGGBB.
    public static func textColor(dark: Bool) -> UInt32 { ls_default_color(dark ? 1 : 0) }
}

/// One file being colored. Lithe tokenizes a line only when it is asked for (from the nearest
/// checkpoint), so opening even a large file costs about a millisecond; a background goroutine
/// fills in checkpoints and `onChange` reports lines whose colors turned out different.
public final class SyntaxDocument {
    public struct Run {
        public var start: Int      // UTF-16 offset within the line
        public var color: UInt32   // 0xRRGGBB
        public var font: UInt32    // bit 0 italic, 1 bold, 2 underline, 3 strikethrough
    }

    public let language: String
    private let handle: UInt
    private let sink = ChangeSink()
    private var scratch = [UInt32](repeating: 0, count: 3 * 256)

    /// Called on the main thread with lines (first, last) to repaint.
    public var onChange: ((Int, Int) -> Void)? {
        get { sink.handler }
        set { sink.handler = newValue }
    }

    /// `text` must have the same lines as the view shows (`\n` separated).
    public init(language: String, text: String) {
        self.language = language
        var text = text
        let context = Unmanaged.passUnretained(sink).toOpaque()
        handle = text.withUTF8 { utf8 in
            utf8.withMemoryRebound(to: CChar.self) {
                ls_open(language, $0.baseAddress, Int64($0.count), { context, first, last in
                    guard let context else { return }
                    Unmanaged<ChangeSink>.fromOpaque(context).takeUnretainedValue().changed(Int(first), Int(last))
                }, context)
            }
        }
    }

    deinit { ls_close(handle) }   // after this returns no callback touches `sink`

    /// Tokenizes lines `first ... last` (0-based) that are not yet: the lines about to be drawn.
    public func prepare(_ first: Int, _ last: Int) { ls_prepare(handle, Int32(first), Int32(last)) }

    /// The styled runs of `line` for the light or dark scheme.
    public func runs(line: Int, dark: Bool) -> [Run] {
        var n = Int(ls_line(handle, Int32(line), dark ? 1 : 0, &scratch, Int32(scratch.count / 3)))
        if n > scratch.count / 3 {
            scratch = [UInt32](repeating: 0, count: 3 * n)
            n = Int(ls_line(handle, Int32(line), dark ? 1 : 0, &scratch, Int32(n)))
        }
        return (0 ..< n).map { Run(start: Int(scratch[3 * $0]), color: scratch[3 * $0 + 1], font: scratch[3 * $0 + 2]) }
    }
}

/// Receives Lithe's change callbacks (any thread) and forwards them, merged, to the main thread.
private final class ChangeSink {
    private let lock = NSLock()
    private var _handler: ((Int, Int) -> Void)?
    private var pending: (Int, Int)?

    var handler: ((Int, Int) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    func changed(_ first: Int, _ last: Int) {
        lock.lock()
        let scheduled = pending != nil
        pending = pending.map { (min($0.0, first), max($0.1, last)) } ?? (first, last)
        lock.unlock()
        guard !scheduled else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let range = pending, handler = _handler
            pending = nil
            lock.unlock()
            if let range, let handler { handler(range.0, range.1) }
        }
    }
}
