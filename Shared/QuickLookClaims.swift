import Foundation
import UniformTypeIdentifiers

/// What the Quick Look extensions claim, and how well that covers the types this Mac actually
/// assigns to code files. Used by `Tools/gen` (to write the Info.plists) and by the app's doctor.
public enum QuickLookClaims {
    /// Types (and everything conforming to them) that already have a better system preview.
    /// Machine-probed types under these are never added to the claims.
    public static let protectedParents: [String] = [
        "public.html", "public.rtf", "com.apple.rtfd", "public.comma-separated-values-text",
        "public.tab-separated-values-text", "public.vcard", "com.apple.ical.ics", "public.calendar-event",
        "public.image", "public.audiovisual-content", "public.audio", "public.archive", "public.font",
        "com.apple.package", "public.executable", "public.composite-content", "public.3d-content",
        "public.spreadsheet", "public.presentation", "com.adobe.pdf", "public.disk-image",
    ]

    // MARK: Claims

    /// `QLSupportedContentTypes` of the main (code) extension.
    /// - Parameter local: UTIs this Mac assigns to our extensions/file names (from `TypeProbe`);
    ///   the eligible ones are claimed too, which catches types declared by third-party apps.
    /// - Parameter user: what the settings add (`userClaims`).
    public static func previewTypes(local: [String] = [], user: UserClaims = .init()) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ t: String) { if !LanguageTable.neverClaim.contains(t), seen.insert(t).inserted { out.append(t) } }

        LanguageTable.genericContentTypes.forEach(add)
        for l in LanguageTable.all where l.claim {
            l.systemUTIs.keys.sorted().forEach(add)
            if !l.importedExtensions.isEmpty { add(l.importedUTI) }
        }
        // Dynamic types: what an extension resolves to when no installed app declares it
        // (e.g. before the host app's declarations are registered, or Xcode not installed).
        for l in LanguageTable.all where l.claim { l.exts.map(DynamicUTI.forFilenameExtension).forEach(add) }
        for t in local where isEligibleLocalType(t) { add(t) }
        user.types.forEach(add)
        if !user.imported.isEmpty { add(userUTI) }
        return out
    }

    /// Type of the extensions the settings add that no app declares.
    public static let userUTI = LanguageTable.utiPrefix + ".user"

    /// What extensions from config.yaml (`files`, `grammars`) need claimed.
    public struct UserClaims {
        /// Types to list: each extension's dynamic type and the type this Mac gives it.
        public var types: [String] = []
        /// Extensions no app declares, which get `userUTI`.
        public var imported: [String] = []
        /// Extensions left alone: another app's non-text type with a preview of its own.
        public var skipped: [(ext: String, type: String)] = []
        public init() {}
    }

    /// The extensions of `extensions` that the language table does not already cover.
    public static func userClaims(extensions: [String]) -> UserClaims {
        let known = Set(LanguageTable.all.filter(\.claim).flatMap(\.exts).map { $0.lowercased() })
        var c = UserClaims()
        for ext in Set(extensions.map { $0.lowercased() }).subtracting(known).sorted() {
            c.types.append(DynamicUTI.forFilenameExtension(ext))
            let id = UTType(filenameExtension: ext)?.identifier ?? ""
            // Ours (declared by an earlier install of this app) or nobody's: declare it.
            if id.isEmpty || id.hasPrefix("dyn.") || id.hasPrefix(LanguageTable.utiPrefix + ".") {
                c.imported.append(ext)
            } else if isEligibleLocalType(id) {
                c.types.append(id)
            } else {
                c.skipped.append((ext, id))
            }
        }
        return c
    }

    public static func fallbackTypes() -> [String] { LanguageTable.fallbackContentTypes }

    /// A machine-probed type may be claimed when it is dynamic or text, and not something with a
    /// better preview of its own. Non-text types declared by apps (e.g. `.pxd` -> a Pixelmator
    /// document) are left alone: that app's own preview should win.
    public static func isEligibleLocalType(_ id: String) -> Bool {
        if id.hasPrefix("dyn.") { return true }
        if LanguageTable.neverClaim.contains(id) { return false }
        guard let t = UTType(id) else { return false }
        for p in protectedParents { if let pt = UTType(p), t.conforms(to: pt) { return false } }
        return t.conforms(to: .text)
    }

    /// `UTImportedTypeDeclarations` for the host app.
    public static func importedTypeDeclarations(user: UserClaims = .init()) -> [[String: Any]] {
        let userDeclaration: [[String: Any]] = user.imported.isEmpty ? [] : [[
            "UTTypeIdentifier": userUTI,
            "UTTypeDescription": "Text (CodeLook config.yaml)",
            "UTTypeConformsTo": ["public.plain-text"],
            "UTTypeTagSpecification": ["public.filename-extension": user.imported],
        ]]
        return userDeclaration + LanguageTable.all.compactMap { l in
            let exts = l.importedExtensions
            guard !exts.isEmpty else { return nil }
            return [
                "UTTypeIdentifier": l.importedUTI,
                "UTTypeDescription": l.isCode ? "\(l.name) source" : "\(l.name) file",
                "UTTypeConformsTo": [l.isCode ? "public.source-code" : "public.plain-text"],
                "UTTypeTagSpecification": ["public.filename-extension": exts],
            ]
        }
    }
}

// MARK: - Probing what this Mac does

/// One sample file name (`x.rs`, `Makefile`, `.gitignore`) and the type LaunchServices gives it.
public struct ProbeResult {
    public let sample: String
    public let languageID: String
    public let languageName: String
    public let type: String
}

public enum TypeProbe {
    /// Every extension and exact file name in the language table (claimed languages only).
    public static func samples() -> [(sample: String, language: Language)] {
        var out: [(String, Language)] = []
        for l in LanguageTable.all where l.claim {
            for e in l.exts { out.append(("sample.\(e)", l)) }
            for n in l.names { out.append((n, l)) }
        }
        return out
    }

    /// Creates tiny text files with those names in a temp folder and asks LaunchServices for
    /// their content type (exact names like `Makefile` can only be probed through real files).
    public static func run(_ list: [(sample: String, language: Language)] = samples()) -> [ProbeResult] {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("codelook-probe-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        var results: [ProbeResult] = []
        for (i, item) in list.enumerated() {
            // One folder per file: `Makefile` and `makefile` collide on case-insensitive volumes.
            let dir = root.appendingPathComponent(String(i))
            let url = dir.appendingPathComponent(item.sample)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data("x\n".utf8).write(to: url)
            } catch { continue }
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.identifier ?? "?"
            results.append(ProbeResult(sample: item.sample, languageID: item.language.id,
                                       languageName: item.language.name, type: type))
        }
        return results
    }
}

// MARK: - Coverage

public enum CoverageVerdict: Equatable {
    /// The type is listed by the code extension.
    case exact
    /// Only a parent type (e.g. public.text) is listed: works if Quick Look follows conformance.
    case inherited(String)
    /// Caught by the fallback extension (public.data).
    case fallback
    case uncovered

    public var isProblem: Bool { if case .exact = self { return false }; return true }
}

public enum Coverage {
    public static func verdict(for typeID: String, preview: Set<String>, fallback: Set<String>) -> CoverageVerdict {
        if preview.contains(typeID) { return .exact }
        guard let t = UTType(typeID) else { return fallback.isEmpty ? .uncovered : .fallback }
        for p in preview.sorted() { if let pt = UTType(p), t.conforms(to: pt) { return .inherited(p) } }
        for f in fallback { if let ft = UTType(f), t.conforms(to: ft) { return .fallback } }
        return .uncovered
    }

    /// Reads `QLSupportedContentTypes` from an extension's Info.plist (built bundle or source plist).
    public static func supportedTypes(infoPlist url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let ext = plist["NSExtension"] as? [String: Any],
              let attrs = ext["NSExtensionAttributes"] as? [String: Any],
              let types = attrs["QLSupportedContentTypes"] as? [String] else { return [] }
        return types
    }
}
