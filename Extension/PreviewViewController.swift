import Cocoa
import Quartz
import os

private let log = Logger(subsystem: "dev.openres.CodeLook", category: "preview")

/// View-based Quick Look preview: a native code view that only lays out and draws the visible rows,
/// so opening a 4 MB file costs about as much as opening a 4 KB one.
///
/// Both extensions (CodeLook and CodeLook Fallback) use this class. Anything that turns out to be
/// binary is refused by passing an error, which makes Quick Look show its standard generic preview.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private static let extensionID = Bundle.main.bundleIdentifier ?? "?"
    private var preview: CodePreviewView { view as! CodePreviewView }

    override func loadView() {
        view = CodePreviewView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.identifier ?? "?"
        let name = url.lastPathComponent
        _ = view
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let p = try PreviewPipeline.prepare(url: url)
                let doc = p.document
                for problem in p.config.problems {
                    log.notice("config \(p.config.path, privacy: .public): \(problem, privacy: .public)")
                }
                log.info("\(Self.extensionID, privacy: .public) \(name, privacy: .public) type=\(type, privacy: .public) lang=\(doc.languageName, privacy: .public) syntax=\(doc.syntax ?? "-", privacy: .public) lines=\(doc.lineCount) font=\(CTFontCopyFullName(p.style.metrics.font) as String, privacy: .public) \(p.milliseconds, format: .fixed(precision: 1))ms (\(doc.reason, privacy: .public))")
                DispatchQueue.main.async {
                    self.preview.show(p)
                    self.preferredContentSize = p.suggestedSize
                    handler(nil)
                }
            } catch {
                log.notice("\(Self.extensionID, privacy: .public) refused \(name, privacy: .public) type=\(type, privacy: .public): \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { handler(error) }
            }
        }
    }
}
