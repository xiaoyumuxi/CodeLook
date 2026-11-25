import AppKit
import CoreText

/// The settings file, `~/.config/codelook/config.yaml` (`$CODELOOK_CONFIG` for the command line
/// tools). There is no settings window: font, colors, grammars, file mappings and limits all
/// live in this file. Lithe's engine parses it (`ls_configure`) and applies the syntax side;
/// this is the rest. It is read again whenever it, or a grammar it names, changes, so an edit
/// shows on the next preview.
public final class CodeLookConfig {
    public let path: String
    public let exists: Bool
    /// What was wrong in the file; whatever could be read still applies.
    public let problems: [String]
    public let style: PreviewStyle
    public let options: DocumentOptions
    /// ".ext" or a lowercased file name -> language (ours, as "cuda", or Lithe's, as "rust").
    public let files: [String: String]
    /// Display names of the languages the file adds grammars for.
    public let languageNames: [String: String]
    /// File extensions (no dot) and names the file maps, which the Info.plists must claim.
    public let extensions: [String]
    public let fileNames: [String]
    private let watched: [String]
    private let stamps: [Stamp?]

    public static var path: String {
        if let env = ProcessInfo.processInfo.environment["CODELOOK_CONFIG"], !env.isEmpty { return env }
        return realHome + "/.config/codelook/config.yaml"
    }

    /// The user's home folder, also inside the sandbox (where NSHomeDirectory() is the container).
    public static let realHome: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }()

    private static let lock = NSLock()
    private static var cached: CodeLookConfig?

    /// The settings as the file is now.
    public static func current() -> CodeLookConfig {
        lock.lock()
        defer { lock.unlock() }
        let path = Self.path
        if let c = cached, c.path == path, c.watched.map(Stamp.init(path:)) == c.stamps { return c }
        let c = CodeLookConfig(path: path)
        cached = c
        return c
    }

    private init(path: String) {
        let raw = Self.configure(path)
        // Stamped before anything else reads them, so an edit made while loading reloads next time.
        watched = [path] + (raw.watch ?? []).filter { $0 != path }
        stamps = watched.map(Stamp.init(path:))
        self.path = path
        exists = raw.exists
        files = raw.files ?? [:]
        languageNames = raw.languages ?? [:]
        extensions = raw.extensions ?? []
        fileNames = raw.fileNames ?? []

        var problems = raw.problems ?? []
        for (name, id) in files.sorted(by: { $0.key < $1.key }) where !Self.isLanguage(id) {
            problems.append("files: \(name): unknown language \"\(id)\"")
        }
        let fonts = FontSet.resolve(raw.font.family, size: CGFloat(raw.font.size), ligatures: raw.font.ligatures)
        problems += fonts.problems
        self.problems = problems

        let lineHeight = raw.font.lineHeight <= 4 ? CGFloat(raw.font.size * raw.font.lineHeight) : CGFloat(raw.font.lineHeight)
        style = PreviewStyle(fonts: fonts, lineHeight: lineHeight, tabWidth: raw.tabWidth, lineNumbers: raw.lineNumbers,
                             light: raw.light, dark: raw.dark)

        var options = DocumentOptions()
        options.maxBytes = raw.maxBytes
        options.maxLines = raw.maxLines
        options.tabWidth = raw.tabWidth
        if !files.isEmpty || !languageNames.isEmpty {
            let files = files, names = languageNames
            options.languageOverride = { Self.resolve(fileName: $0, files: files, names: names) }
        }
        self.options = options
    }

    /// The display name of a Lithe language, those the settings add included.
    public func displayName(syntax id: String) -> String {
        languageNames[id] ?? LanguageTable.displayName(syntax: id)
    }

    // MARK: Files

    static func resolve(fileName: String, files: [String: String], names: [String: String]) -> ResolvedLanguage? {
        let lower = fileName.lowercased()
        var key: String? = files[lower] != nil ? lower : nil
        if key == nil {
            // The longest extension that matches: ".d.ts" before ".ts". ".bazelrc" also matches
            // the file named ".bazelrc".
            key = files.keys.filter { $0.hasPrefix(".") && lower.hasSuffix($0) }.max { $0.count < $1.count }
        }
        guard let key, let id = files[key] else {
            // A grammar the settings add, for its extensions and file names.
            if !names.isEmpty, let id = LitheSyntax.language(forPath: fileName), let name = names[id] {
                return ResolvedLanguage(name: name, syntax: id, reason: "config.yaml grammars")
            }
            return nil
        }
        let reason = "config.yaml \(key)"
        if ["plaintext", "plain", "text", "none"].contains(id.lowercased()) {
            return ResolvedLanguage(name: "Plain Text", syntax: nil, reason: reason)
        }
        if let l = LanguageTable.byID[id] { return ResolvedLanguage(name: l.name, syntax: l.syntax, reason: reason) }
        return ResolvedLanguage(name: names[id] ?? LanguageTable.displayName(syntax: id), syntax: id, reason: reason)
    }

    private static func isLanguage(_ id: String) -> Bool {
        ["plaintext", "plain", "text", "none"].contains(id.lowercased()) || LanguageTable.byID[id] != nil || LitheSyntax.has(id)
    }

    // MARK: Reading

    struct Raw: Decodable {
        struct Font: Decodable { var family: String; var size: Double; var lineHeight: Double; var ligatures: Bool }
        struct Colors: Decodable { var background: UInt32?; var text: UInt32; var lineNumber: UInt32?; var selection: UInt32? }
        var exists: Bool
        var problems: [String]?
        var font: Font
        var tabWidth: Int
        var lineNumbers: Bool
        var maxBytes: Int
        var maxLines: Int
        var light: Colors
        var dark: Colors
        var files: [String: String]?
        var languages: [String: String]?
        var extensions: [String]?
        var fileNames: [String]?
        var watch: [String]?
    }

    private static func configure(_ path: String) -> Raw {
        guard let cs = ls_configure(path) else { fatalError("ls_configure returned nothing") }
        defer { free(cs) }
        let json = Data(bytes: cs, count: strlen(cs))
        do {
            return try JSONDecoder().decode(Raw.self, from: json)
        } catch {
            // Only if the bridge and this struct disagree, a build defect.
            fatalError("ls_configure: \(error) in \(String(decoding: json, as: UTF8.self))")
        }
    }

    /// Identity and modification time of a file, nil when it does not exist.
    struct Stamp: Equatable {
        var inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int
        init?(path: String) {
            var st = stat()
            guard stat(path, &st) == 0 else { return nil }
            inode = UInt64(st.st_ino); size = Int64(st.st_size)
            seconds = st.st_mtimespec.tv_sec; nanoseconds = st.st_mtimespec.tv_nsec
        }
    }
}

// MARK: - Fonts

/// Regular, bold, italic and bold italic of the configured family. JetBrains Mono, the default,
/// ships in the bundle (Resources/Fonts) and is used from there when it is not installed.
struct FontSet {
    var regular, bold, italic, boldItalic: CTFont
    var problems: [String] = []

    static let bundledFamily = "JetBrains Mono"

    /// `families` is a comma-separated list; the first one available wins.
    static func resolve(_ families: String, size: CGFloat, ligatures: Bool) -> FontSet {
        var set: FontSet?
        var missing: [String] = []
        for name in families.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            // The bundled copy first: the same everywhere, and asking CoreText for a family
            // that is not installed costs ~5 ms.
            let isBundled = name.caseInsensitiveCompare(bundledFamily) == .orderedSame
            if let s = (isBundled ? bundled(size: size) : nil) ?? installed(name, size: size) {
                set = s
                break
            }
            missing.append(name)
        }
        var problems: [String] = []
        if set == nil {
            set = bundled(size: size) ?? system(size: size)
            problems.append("font.family: \(missing.joined(separator: ", ")) not installed; using \(CTFontCopyFamilyName(set!.regular))")
        } else if !missing.isEmpty {
            problems.append("font.family: \(missing.joined(separator: ", ")) not installed")
        }
        var result = set!
        if !CTFontGetSymbolicTraits(result.regular).contains(.traitMonoSpace) {
            problems.append("font.family: \(CTFontCopyFamilyName(result.regular)) is not monospaced; wrapping may be off")
        }
        if !ligatures { result = result.withoutLigatures() }
        result.problems = problems
        return result
    }

    /// A family (or PostScript / full name) installed on this Mac.
    private static func installed(_ name: String, size: CGFloat) -> FontSet? {
        let family = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
        if let matches = CTFontDescriptorCreateMatchingFontDescriptors(family, Set([kCTFontFamilyNameAttribute as String]) as CFSet) as? [CTFontDescriptor],
           !matches.isEmpty {
            return styled(CTFontCreateWithFontDescriptor(family, size, nil))
        }
        let byName = CTFontCreateWithName(name as CFString, size, nil)
        let names = [CTFontCopyPostScriptName(byName), CTFontCopyFullName(byName)].map { ($0 as String).lowercased() }
        return names.contains(name.lowercased()) ? styled(byName) : nil
    }

    private static func styled(_ regular: CTFont) -> FontSet {
        func trait(_ font: CTFont, _ t: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(font, 0, nil, t, t) ?? font
        }
        let bold = trait(regular, .traitBold)
        return FontSet(regular: regular, bold: bold, italic: trait(regular, .traitItalic),
                       boldItalic: trait(bold, .traitItalic))
    }

    /// JetBrains Mono from the bundle's font files, without registering them.
    private static func bundled(size: CGFloat) -> FontSet? {
        guard let dir = bundledFontsDirectory else { return nil }
        func load(_ style: String) -> CTFont? {
            let url = dir.appendingPathComponent("JetBrainsMono-\(style).ttf") as CFURL
            guard let d = (CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor])?.first else { return nil }
            return CTFontCreateWithFontDescriptor(d, size, nil)
        }
        guard let regular = load("Regular") else { return nil }
        let bold = load("Bold") ?? regular
        return FontSet(regular: regular, bold: bold, italic: load("Italic") ?? regular, boldItalic: load("BoldItalic") ?? bold)
    }

    private static func system(size: CGFloat) -> FontSet {
        styled(NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont)
    }

    /// Resources/Fonts in the app or extension bundle; for the command line tools, next to the
    /// build folder they run from (`$CODELOOK_FONTS` overrides).
    static let bundledFontsDirectory: URL? = {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CODELOOK_FONTS"] { candidates.append(URL(fileURLWithPath: env)) }
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("Fonts")) }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Fonts"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("JetBrainsMono-Regular.ttf").path) }
    }()

    /// Turns off contextual alternates and ligatures (`->` stays two characters).
    func withoutLigatures() -> FontSet {
        let off: [[CFString: Any]] = ["calt", "liga", "dlig"].map {
            [kCTFontOpenTypeFeatureTag: $0, kCTFontOpenTypeFeatureValue: 0]
        }
        let attrs = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: off] as CFDictionary)
        func plain(_ f: CTFont) -> CTFont { CTFontCreateCopyWithAttributes(f, 0, nil, attrs) }
        return FontSet(regular: plain(regular), bold: plain(bold), italic: plain(italic), boldItalic: plain(boldItalic),
                       problems: problems)
    }
}

// MARK: - Style

/// How the code view looks: metrics from the font and the light and dark colors.
public final class PreviewStyle {
    public let metrics: CodeTextView.Metrics
    let light: CodeTextView.Palette
    let dark: CodeTextView.Palette
    public let lineNumbers: Bool

    init(fonts: FontSet, lineHeight: CGFloat, tabWidth: Int, lineNumbers: Bool,
         light: CodeLookConfig.Raw.Colors, dark: CodeLookConfig.Raw.Colors) {
        metrics = CodeTextView.Metrics(fonts: fonts, lineHeight: lineHeight, tabWidth: tabWidth, lineNumbers: lineNumbers)
        self.light = CodeTextView.Palette(dark: false, colors: light)
        self.dark = CodeTextView.Palette(dark: true, colors: dark)
        self.lineNumbers = lineNumbers
    }

    func palette(dark isDark: Bool) -> CodeTextView.Palette { isDark ? dark : light }

    /// The background as a color that follows the appearance (for the scroll view).
    public lazy var backgroundColor: NSColor = { [light, dark] in
        NSColor(name: nil) { NSColor(cgColor: $0.isDark ? dark.background : light.background) ?? .textBackgroundColor }
    }()
}
