import AppKit
import Foundation

/// Thin wrappers around pluginkit / lsregister / qlmanage.
enum SystemTools {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    struct Registration: Hashable {
        var election: Character   // "+" use, "-" ignore, " " default, "=" superseded, "!" debug
        var version: String
        var path: String
    }

    /// Every registered copy of an extension (pluginkit -A -D also lists duplicates).
    static func registrations(of bundleID: String) -> [Registration] {
        let out = run("/usr/bin/pluginkit", ["-m", "-A", "-D", "-v", "-i", bundleID]).output
        return out.split(separator: "\n").compactMap { line in
            guard let idRange = line.range(of: bundleID) else { return nil }
            let prefix = line[..<idRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let election = prefix.first ?? " "
            let rest = line[idRange.upperBound...]
            let version = rest.hasPrefix("(") ? String(rest.dropFirst().prefix(while: { $0 != ")" })) : "?"
            let path = rest.split(separator: "\t").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return Registration(election: election, version: version, path: path)
        }
    }

    /// Re-register the app and its extensions, enable them and reset Quick Look's caches.
    static func repair(app: URL, extensions: [(id: String, url: URL)]) -> String {
        var log = ""
        func step(_ path: String, _ args: [String]) {
            let r = run(path, args)
            log += "$ \((path as NSString).lastPathComponent) \(args.joined(separator: " "))\n"
            if !r.output.isEmpty { log += r.output.hasSuffix("\n") ? r.output : r.output + "\n" }
            if r.status != 0 { log += "→ exit \(r.status)\n" }
        }
        step(lsregister, ["-f", "-R", "-trusted", app.path])
        for e in extensions { step("/usr/bin/pluginkit", ["-a", e.url.path]) }
        for e in extensions { step("/usr/bin/pluginkit", ["-e", "use", "-i", e.id]) }
        step("/usr/bin/qlmanage", ["-r"])
        step("/usr/bin/qlmanage", ["-r", "cache"])
        return log
    }

    static func openExtensionSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences",
        ]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }

    /// Show the file in a real Quick Look panel (goes through the system's extension routing).
    static func quickLook(_ url: URL) {
        DispatchQueue.global().async { run("/usr/bin/qlmanage", ["-p", url.path]) }
    }
}
