import AppKit

// codelook-render: runs the preview pipeline outside Quick Look.
//   codelook-render <file> [--png out.png] [--line N] [--dark] [--size WxH]
//       timings (load + open in Lithe's engine, drawing) and an optional snapshot of the preview
//       view scrolled to line N
//   codelook-render --batch <files...>    one summary line per file (smoke test)
// Settings come from ~/.config/codelook/config.yaml, or $CODELOOK_CONFIG.
var args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    FileHandle.standardError.write("usage: codelook-render <file> [--png out.png] [--line N] [--dark] [--size WxH] | --batch <files...>\n".data(using: .utf8)!)
    exit(2)
}

func ms(since t: DispatchTime) -> Double { PreviewPipeline.elapsed(since: t) }

func pad(_ s: String, _ width: Int) -> String { s.padding(toLength: max(width, s.count + 1), withPad: " ", startingAt: 0) }

func summary(_ url: URL) -> String {
    do {
        let p = try PreviewPipeline.prepare(url: url)
        let d = p.document
        return pad(url.lastPathComponent, 34) + pad(d.languageName, 20) + pad(d.syntax ?? "-", 16)
            + String(format: "%7d lines %7.1f ms  ", d.lineCount, p.milliseconds) + d.reason
    } catch {
        return pad(url.lastPathComponent, 34) + "REFUSED: " + error.localizedDescription
    }
}

guard let first = args.first else { usage() }

func describe(_ c: CodeLookConfig) -> String {
    var s = "config: \(c.path)" + (c.exists ? "" : " (none, defaults)")
    let m = c.style.metrics
    s += "\n  font: \(CTFontCopyFullName(m.font)) \(CTFontGetSize(m.font))pt, line \(m.lineHeight)pt, tab \(c.options.tabWidth)"
    for p in c.problems { s += "\n  problem: \(p)" }
    return s
}

if first == "--batch" {
    print(describe(CodeLookConfig.current()))
    for p in args.dropFirst() { print(summary(URL(fileURLWithPath: p))) }
    exit(0)
}

// Options
var png: String?
var line = 0
var dark = false
var size = CGSize(width: 900, height: 700)
var file: String?
func value() -> String {
    if args.isEmpty { usage() }
    return args.removeFirst()
}
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--png": png = value()
    case "--line": line = max(0, (Int(value()) ?? 1) - 1)
    case "--dark": dark = true
    case "--size":
        let parts = value().split(separator: "x").compactMap { Double($0) }
        if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
    default: file = a
    }
}
guard let file else { usage() }
let url = URL(fileURLWithPath: file)

var t = DispatchTime.now()
_ = LitheSyntax.has("plaintext")
print(String(format: "Lithe registry       %7.1f ms (once per process)", ms(since: t)))
t = DispatchTime.now()
let config = CodeLookConfig.current()
print(String(format: "settings             %7.1f ms (again only when the file changes)", ms(since: t)))
print(describe(config))

let prepared: PreparedPreview
do { prepared = try PreviewPipeline.prepare(url: url) } catch {
    print("REFUSED: \(error.localizedDescription)")
    exit(1)
}
let doc = prepared.document
print(String(format: "prepare              %7.1f ms   %@ · %@ · %d lines · %d units · widest %d cols",
             prepared.milliseconds, doc.languageName as NSString, (doc.syntax ?? "plain") as NSString,
             doc.lineCount, doc.length, doc.longestCols))
print("  reason: \(doc.reason)" + (doc.notes.isEmpty ? "" : "  notes: \(doc.notes.joined(separator: "; "))"))
let s = prepared.suggestedSize
print("suggested size       \(Int(s.width))×\(Int(s.height))")

guard let png else { exit(0) }

_ = NSApplication.shared
let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
let view = CodePreviewView(frame: NSRect(origin: .zero, size: size))
window.contentView = view
t = DispatchTime.now()
view.show(prepared)
view.scroll(toLine: line)
view.layoutSubtreeIfNeeded()
let setup = ms(since: t)
t = DispatchTime.now()
guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
view.cacheDisplay(in: view.bounds, to: rep)
print(String(format: "show + layout        %7.1f ms\ndraw one screen      %7.1f ms", setup, ms(since: t)))
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: png))
print("→ \(png)")
