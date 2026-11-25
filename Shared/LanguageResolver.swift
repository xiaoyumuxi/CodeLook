import Foundation

/// The result of figuring out how to show a file.
public struct ResolvedLanguage: Equatable {
    /// Display name ("Rust", "Plain Text", ...).
    public var name: String
    /// Lithe language that colors it, nil = plain text.
    public var syntax: String?
    /// How it was found (for the header tooltip / app).
    public var reason: String

    init(name: String, syntax: String?, reason: String) {
        self.name = name
        self.syntax = syntax
        self.reason = reason
    }

    init(_ l: Language, reason: String) { self.init(name: l.name, syntax: l.syntax, reason: reason) }

    public static let plain = ResolvedLanguage(name: "Plain Text", syntax: nil, reason: "fallback")
}

public enum LanguageResolver {
    /// Resolve from the file name only.
    public static func resolve(fileName: String) -> ResolvedLanguage? {
        resolve(fileName: fileName, depth: 0)
    }

    private static func resolve(fileName: String, depth: Int) -> ResolvedLanguage? {
        let lower = fileName.lowercased()

        if let l = LanguageTable.byName[lower] { return ResolvedLanguage(l, reason: "name") }

        let ext = fileExtension(of: lower)
        if let ext, let l = LanguageTable.byExtension[ext] { return ResolvedLanguage(l, reason: "ext .\(ext)") }

        for (prefix, id) in LanguageTable.namePrefixes where lower.hasPrefix(prefix) {
            if let l = LanguageTable.byID[id] { return ResolvedLanguage(l, reason: "prefix \(prefix)") }
        }

        // d3-LICENSE, tree-sitter.LICENSE, COPYING.LIB
        for word in ["license", "licence", "copying", "copyright"] where lower.contains(word) {
            if ext == nil || ext == word || !(LanguageTable.byExtension[ext!]?.claim ?? false) {
                return ResolvedLanguage(name: "Plain Text", syntax: nil, reason: "name contains \(word)")
            }
        }

        // config.yaml.example -> config.yaml, Makefile.in -> Makefile
        if let ext, depth < 2, LanguageTable.wrapperExtensions.contains(ext) {
            let stripped = String(fileName.dropLast(ext.count + 1))
            if !stripped.isEmpty, var r = resolve(fileName: stripped, depth: depth + 1) {
                r.reason += " (via .\(ext))"
                return r
            }
        }
        return nil
    }

    /// Resolve from the first bytes of content (shebang, modelines, obvious markers).
    public static func resolve(content: Substring) -> ResolvedLanguage? {
        let firstLine = content.prefix(while: { $0 != "\n" })
        if firstLine.hasPrefix("#!") {
            if let r = fromShebang(String(firstLine)) { return r }
        }
        if let r = fromModeline(content) { return r }

        let head = content.prefix(512).drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        if head.hasPrefix("<?xml") || head.hasPrefix("<!DOCTYPE plist") || head.hasPrefix("<plist") {
            return lang("xml", reason: "content <?xml")
        }
        if head.lowercased().hasPrefix("<!doctype html") || head.lowercased().hasPrefix("<html") {
            return lang("html", reason: "content <html")
        }
        if head.hasPrefix("<?php") { return lang("php", reason: "content <?php") }
        if head.hasPrefix("diff --git") || head.hasPrefix("--- ") && content.contains("\n+++ ") {
            return lang("diff", reason: "content diff")
        }
        if head.hasPrefix("{") || head.hasPrefix("[") {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmed.hasSuffix("}") || trimmed.hasSuffix("]")) && trimmed.count < 4_000_000,
               let data = trimmed.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
                return lang("json", reason: "content JSON")
            }
        }
        return nil
    }

    // MARK: - Helpers

    static func fileExtension(of lowerName: String) -> String? {
        guard let dot = lowerName.lastIndex(of: "."), dot != lowerName.startIndex else { return nil }
        let ext = lowerName[lowerName.index(after: dot)...]
        return ext.isEmpty ? nil : String(ext)
    }

    private static func lang(_ id: String, reason: String) -> ResolvedLanguage? {
        LanguageTable.byID[id].map { ResolvedLanguage($0, reason: reason) }
    }

    private static let interpreters: [String: String] = [
        "sh": "shell", "bash": "shell", "zsh": "shell", "ksh": "shell", "dash": "shell", "ash": "shell",
        "fish": "shell", "csh": "shell", "tcsh": "shell",
        "python": "python", "pypy": "python", "uv": "python",
        "node": "javascript", "nodejs": "javascript", "bun": "typescript", "deno": "typescript",
        "ts-node": "typescript", "tsx": "typescript",
        "ruby": "ruby", "jruby": "ruby", "perl": "perl", "php": "php", "lua": "lua", "luajit": "lua",
        "rscript": "r", "julia": "julia", "tclsh": "tcl", "wish": "tcl", "awk": "awk", "gawk": "awk",
        "osascript": "applescript", "pwsh": "powershell", "groovy": "groovy", "kotlin": "kotlin",
        "scala": "scala", "swift": "swift", "elixir": "elixir", "escript": "erlang", "make": "makefile",
        "runhaskell": "haskell", "stack": "haskell", "nix-shell": "nix", "dart": "dart",
        "cargo": "rust", "rust-script": "rust", "go": "go", "java": "java", "jshell": "java",
    ]

    static func fromShebang(_ line: String) -> ResolvedLanguage? {
        var parts = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !parts.isEmpty else { return nil }
        var prog = (parts.removeFirst() as NSString).lastPathComponent
        if prog == "env" {
            // skip env flags like -S, -i, VAR=x
            while let p = parts.first, p.hasPrefix("-") || p.contains("=") { parts.removeFirst() }
            guard let p = parts.first else { return nil }
            prog = (p as NSString).lastPathComponent
        }
        prog = prog.lowercased()
        // python3.12 -> python, ruby2.7 -> ruby
        let base = String(prog.prefix(while: { $0.isLetter || $0 == "-" }))
        guard let id = interpreters[prog] ?? interpreters[base], let l = LanguageTable.byID[id] else { return nil }
        return ResolvedLanguage(l, reason: "shebang \(prog)")
    }

    /// `# vim: set ft=python:` / `-*- mode: ruby -*-`
    static func fromModeline(_ content: Substring) -> ResolvedLanguage? {
        let head = content.prefix(1024)
        let patterns = [#"vim?:.*?\b(?:ft|filetype|syntax)=([A-Za-z0-9_+-]+)"#, #"-\*-.*?mode:\s*([A-Za-z0-9_+-]+)"#,
                        #"-\*-\s*([A-Za-z0-9_+-]+)\s*-\*-"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let s = String(head)
            if let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let r = Range(m.range(at: 1), in: s) {
                let name = s[r].lowercased()
                let alias: [String: String] = ["sh": "shell", "zsh": "shell", "bash": "shell", "js": "javascript",
                                               "ts": "typescript", "py": "python", "rb": "ruby", "c++": "cpp",
                                               "emacs-lisp": "elisp", "conf": "ini", "dosini": "ini",
                                               "make": "makefile", "yml": "yaml", "md": "markdown"]
                let id = alias[name] ?? name
                if let l = LanguageTable.byID[id] {
                    return ResolvedLanguage(l, reason: "modeline \(name)")
                }
            }
        }
        return nil
    }
}
