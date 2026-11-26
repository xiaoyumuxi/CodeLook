import AppKit
import Foundation
import UniformTypeIdentifiers

struct EmbeddedExtension: Identifiable {
    let id: String          // bundle id
    let title: String
    let detail: String
    let url: URL
    let supportedTypes: [String]
}

struct CoverageRow: Identifiable {
    let id = UUID()
    let sample: String
    let language: String
    let type: String
    let verdict: CoverageVerdict

    var verdictText: String {
        switch verdict {
        case .exact: return "✓ 直接支持"
        case .inherited(let p): return "≈ 经由 \(p)"
        case .fallback: return "↳ 兜底扩展"
        case .uncovered: return "✗ 未覆盖"
        }
    }
}

struct Inspection {
    let url: URL
    let type: String
    let supertypes: [String]
    let previewVerdict: String
    let prepared: PreparedPreview?
    let error: String?
}

/// config.yaml as the previews see it (the app only shows it; it is edited in a text editor).
struct ConfigStatus {
    let path: String
    let exists: Bool
    let font: String
    let problems: [String]
    /// Extensions the file adds that the installed Info.plists do not claim yet.
    let unclaimed: [String]

    init(_ c: CodeLookConfig, previewTypes: Set<String>) {
        path = c.path
        exists = c.exists
        let m = c.style.metrics
        font = "\(CTFontCopyFamilyName(m.font)) \(Int(CTFontGetSize(m.font))) pt"
        problems = c.problems
        unclaimed = QuickLookClaims.unclaimed(extensions: c.extensions, previewTypes: previewTypes)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var registrations: [String: [SystemTools.Registration]] = [:]
    @Published var repairLog = ""
    @Published var busy = false
    @Published var coverage: [CoverageRow] = []
    @Published var inspection: Inspection?
    @Published var config: ConfigStatus?

    /// Preview first, Fallback last. Their types are read again on refresh: the Info.plists
    /// change when install.sh --refresh claims new extensions.
    @Published private(set) var extensions: [EmbeddedExtension]

    init() {
        extensions = Self.embeddedExtensions()
        // Started again by `reclaim()`: show what install.sh printed.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--refresh-log"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            repairLog = (try? String(contentsOf: url, encoding: .utf8)) ?? "（没有找到 \(url.path)）"
            try? FileManager.default.removeItem(at: url)
        }
        refreshStatus()
    }

    nonisolated private static func embeddedExtensions() -> [EmbeddedExtension] {
        let plugins = Bundle.main.builtInPlugInsURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns")
        func ext(_ name: String, _ id: String, _ title: String, _ detail: String) -> EmbeddedExtension {
            let url = plugins.appendingPathComponent("\(name).appex")
            return EmbeddedExtension(id: id, title: title, detail: detail, url: url,
                                     supportedTypes: Coverage.supportedTypes(infoPlist: url.appendingPathComponent("Contents/Info.plist")))
        }
        return [
            ext("CodeLookPreview", "dev.openres.CodeLook.Preview", "CodeLook 代码预览",
                "按类型声明的代码 / 配置文件（.rs .toml .yaml .ts …）"),
            ext("CodeLookFallback", "dev.openres.CodeLook.Fallback", "CodeLook 兜底预览",
                "系统只认作 “数据” 的文件：.gitignore、Dockerfile、无扩展名脚本 …（二进制会自动退回系统预览）"),
        ]
    }

    func refreshStatus() {
        let ids = extensions.map(\.id)
        Task.detached {
            let exts = Self.embeddedExtensions()
            let status = ConfigStatus(CodeLookConfig.current(), previewTypes: Set(exts.first?.supportedTypes ?? []))
            await MainActor.run { self.extensions = exts; self.config = status }
        }
        Task.detached {
            var regs: [String: [SystemTools.Registration]] = [:]
            for id in ids { regs[id] = SystemTools.registrations(of: id) }
            let snapshot = regs
            await MainActor.run { self.registrations = snapshot }
        }
    }

    /// Opens config.yaml in the default editor, first creating it (and the example grammars)
    /// from the copy in the app when there is none.
    func openConfig() {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: CodeLookConfig.path)
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: url.path), let examples = Bundle.main.url(forResource: "Examples", withExtension: nil) {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.copyItem(at: examples.appendingPathComponent("config.example.yaml"), to: url)
                let grammars = dir.appendingPathComponent("grammars")
                if !fm.fileExists(atPath: grammars.path) {
                    try fm.copyItem(at: examples.appendingPathComponent("grammars"), to: grammars)
                }
            } catch {
                repairLog = "无法创建 \(url.path)：\(error.localizedDescription)"
                return
            }
        }
        NSWorkspace.shared.open([url], withApplicationAt: textEditor(for: url), configuration: NSWorkspace.OpenConfiguration())
        refreshStatus()
    }

    /// The app that opens .yaml files, or TextEdit when none does.
    private func textEditor(for url: URL) -> URL {
        NSWorkspace.shared.urlForApplication(toOpen: url)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    }

    /// Does what `install.sh --refresh` does, by running the copy in the app: claims this Mac's
    /// types and config.yaml's extensions, signs the bundle again, registers it and resets Quick
    /// Look. The bundle is rewritten, so the app quits first; a shell waits for it to exit, runs
    /// the script and starts the app again with the log.
    func reclaim() {
        guard let script = Bundle.main.url(forResource: "install", withExtension: "sh") else {
            repairLog = "这个 App 里没有 install.sh，无法重新认领。"
            return
        }
        let app = Bundle.main.bundleURL
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("codelook-refresh-\(UUID().uuidString).log")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // $0 script, $1 dir, $2 log, $3 app, $4 the pid to wait for.
        p.arguments = ["-c", """
            while kill -0 "$4" 2>/dev/null; do sleep 0.2; done
            /bin/bash "$0" --refresh --dir "$1" >"$2" 2>&1
            echo "→ exit $?" >>"$2"
            open "$3" --args --refresh-log "$2"
            """, script.path, app.deletingLastPathComponent().path, log.path, app.path,
            String(ProcessInfo.processInfo.processIdentifier)]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            repairLog = "无法运行 install.sh：\(error.localizedDescription)"
            return
        }
        busy = true
        NSApp.terminate(nil)
    }

    func runCoverage() {
        busy = true
        let preview = Set(extensions.first?.supportedTypes ?? [])
        let fallback = Set(extensions.last?.supportedTypes ?? [])
        Task.detached {
            let rows = TypeProbe.run().map {
                CoverageRow(sample: $0.sample, language: $0.languageName, type: $0.type,
                            verdict: Coverage.verdict(for: $0.type, preview: preview, fallback: fallback))
            }
            await MainActor.run { self.coverage = rows; self.busy = false }
        }
    }

    func inspect(_ url: URL) {
        let preview = Set(extensions.first?.supportedTypes ?? [])
        let fallback = Set(extensions.last?.supportedTypes ?? [])
        Task.detached {
            let t = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            let typeID = t?.identifier ?? "?"
            var supers: [String] = []
            if let t { supers = t.supertypes.map(\.identifier).sorted() }
            let v = Coverage.verdict(for: typeID, preview: preview, fallback: fallback)
            let verdict = CoverageRow(sample: "", language: "", type: typeID, verdict: v).verdictText
            var prepared: PreparedPreview?
            var failure: String?
            do { prepared = try PreviewPipeline.prepare(url: url) } catch { failure = error.localizedDescription }
            let result = Inspection(url: url, type: typeID, supertypes: supers, previewVerdict: verdict,
                                    prepared: prepared, error: failure)
            await MainActor.run { self.inspection = result }
        }
    }
}
