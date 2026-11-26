import AppKit
import Foundation

/// Thin wrappers around pluginkit / qlmanage. Registering is install.sh's job (`AppModel.reclaim`).
enum SystemTools {
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
