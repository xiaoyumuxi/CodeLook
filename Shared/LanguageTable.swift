import Foundation

/// One language / file family.
///
/// This table is the single source of truth:
///   * at runtime it names a file's language and, when Lithe has no language for the file name
///     (`Cargo.lock`, `.gitignore`, `.vue`...), says which Lithe grammar colors it;
///   * `Tools/gen` turns it into the Info.plist files (supported content types of the
///     Quick Look extension + UTIs imported by the host app).
///
/// Edit this file, then run `make gen` (or `make`).
public struct Language {
    /// Stable id. Also the suffix of the UTI the host app imports for `importedExtensions`.
    public let id: String
    /// Human readable name (shown in the preview header and in the app).
    public let name: String
    /// Lithe language that colors it, nil = plain text. Languages Lithe has no grammar for use a
    /// close sibling's (CUDA → cpp, Scala → java, Vue → html) or none.
    public let syntax: String?
    /// File extensions, lower-case, no dot.
    public let exts: [String]
    /// Exact file names (matched case-insensitively), e.g. `Makefile`, `.zshrc`.
    public let names: [String]
    /// UTIs that macOS (or common apps) already declare for some of `exts`: UTI -> extensions it owns.
    /// Every UTI listed here is claimed by the Quick Look extension; the extensions listed here
    /// are NOT re-declared by the host app (re-declaring Apple-owned types could change how
    /// other apps open those files).
    public let systemUTIs: [String: [String]]
    /// `true` -> imported UTI conforms to public.source-code, otherwise public.plain-text.
    public let isCode: Bool
    /// `false` -> only used for name/extension -> language resolution. Nothing is claimed or
    /// declared (e.g. HTML is rendered by Safari's Quick Look extension, CSV by the table view).
    public let claim: Bool

    public var importedUTI: String { "\(LanguageTable.utiPrefix).\(id)" }

    /// Extensions that nobody on a stock macOS declares, so the host app declares them.
    public var importedExtensions: [String] {
        guard claim else { return [] }
        let owned = Set(systemUTIs.values.joined())
        return exts.filter { !owned.contains($0) }
    }
}

private func L(_ id: String, _ name: String, _ syntax: String,
               exts: String = "", names: String = "",
               sys: [String: String] = [:], code: Bool = true, claim: Bool = true) -> Language {
    func split(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }
    return Language(id: id, name: name, syntax: syntax.isEmpty ? nil : syntax, exts: split(exts.lowercased()),
                    names: split(names), systemUTIs: sys.mapValues(split), isCode: code, claim: claim)
}

public enum LanguageTable {
    public static let utiPrefix = "dev.openres.codelook"

    // MARK: - Languages

    public static let all: [Language] = [
        // --- Systems / compiled -------------------------------------------------------------
        L("rust", "Rust", "rust", exts: "rs"),
        L("go", "Go", "go", exts: "go"),
        L("gomod", "Go Module", "", names: "go.mod go.work", code: false),
        L("gosum", "Go Checksums", "", names: "go.sum go.work.sum", code: false),
        L("zig", "Zig", "zig", exts: "zig zon"),
        L("c", "C", "c", exts: "c i", sys: ["public.c-source": "c", "public.c-source.preprocessed": "i"]),
        L("c-header", "C/C++ Header", "c", exts: "h pch",
          sys: ["public.c-header": "h", "public.precompiled-c-header": "pch"]),
        L("cpp", "C++", "cpp",
          exts: "cc cpp cxx c++ cp hh hpp hxx h++ ipp tpp tcc inl ii ixx cppm",
          sys: ["public.c-plus-plus-source": "cc cpp cxx c++ cp",
                "public.c-plus-plus-header": "hh hpp hxx h++ ipp",
                "public.c-plus-plus-source.preprocessed": "ii"]),
        L("objc", "Objective-C", "objective-c", exts: "m", sys: ["public.objective-c-source": "m"]),
        L("objcpp", "Objective-C++", "objective-cpp", exts: "mm", sys: ["public.objective-c-plus-plus-source": "mm"]),
        L("cuda", "CUDA", "cpp", exts: "cu cuh"),
        L("metal", "Metal", "cpp", exts: "metal", sys: ["com.apple.metal": "metal"]),
        L("hlsl", "HLSL", "cpp", exts: "hlsl hlsli fx fxh", sys: ["com.microsoft.hlsl": "hlsl"]),
        L("glsl", "GLSL", "c", exts: "glsl vert frag geom tesc tese comp vsh fsh",
          sys: ["org.khronos.glsl-source": "glsl"]),
        L("wgsl", "WGSL", "rust", exts: "wgsl"),
        L("opencl", "OpenCL", "c", exts: "cl", sys: ["public.opencl-source": "cl"]),
        L("modulemap", "Module Map", "c", exts: "modulemap", sys: ["public.module-map": "modulemap"]),
        L("swift", "Swift", "swift", exts: "swift swiftinterface", sys: ["public.swift-source": "swift"]),
        L("java", "Java", "java", exts: "java jav jsh", sys: ["com.sun.java-source": "java jav"]),
        L("kotlin", "Kotlin", "kotlin", exts: "kt kts ktm"),
        L("scala", "Scala", "java", exts: "scala sc sbt mill"),
        L("groovy", "Groovy", "groovy", exts: "groovy gvy gy gsh", names: "Jenkinsfile"),
        L("gradle", "Gradle", "groovy", exts: "gradle"),
        L("csharp", "C#", "csharp", exts: "cs csx cake"),
        L("fsharp", "F#", "", exts: "fs fsi fsx fsscript", sys: ["org.khronos.glsl.fragment-shader": "fs"]),
        L("vbnet", "Visual Basic", "", exts: "vb vba"),
        L("vbscript", "VBScript", "", exts: "vbs"),
        L("dart", "Dart", "javascript", exts: "dart"),
        L("d", "D", "cpp", exts: "d di"),
        L("nim", "Nim", "python", exts: "nim nims nimble"),
        L("crystal", "Crystal", "ruby", exts: "cr"),
        L("vala", "Vala", "csharp", exts: "vala vapi"),
        L("fortran", "Fortran", "", exts: "f f77 f90 f95 f03 f08 for ftn",
          sys: ["public.fortran-source": "f for"]),
        L("ada", "Ada", "", exts: "ada ads adb", sys: ["public.ada-source": "ada ads adb"]),
        L("pascal", "Pascal", "", exts: "pas dpr lpr dfm lfm", sys: ["public.pascal-source": "pas"]),
        L("asm", "Assembly", "", exts: "asm s nasm", sys: [
            "public.assembly-source": "s", "public.nasm-assembly-source": "nasm"]),
        L("llvm", "LLVM IR", "", exts: "ll", sys: ["public.lex-source": "ll"]),
        L("lex", "Lex", "c", exts: "l lm lpp lxx", sys: ["public.lex-source": "l lm lpp lxx"]),
        L("yacc", "Yacc", "c", exts: "y yy ym ypp yxx", sys: ["public.yacc-source": "y yy ym ypp yxx"]),
        L("verilog", "Verilog", "", exts: "v sv svh vh"),
        L("vhdl", "VHDL", "", exts: "vhd vhdl"),
        L("wasm", "WebAssembly Text", "", exts: "wat wast"),
        L("solidity", "Solidity", "javascript", exts: "sol"),
        L("smali", "Smali", "", exts: "smali"),
        L("arduino", "Arduino", "cpp", exts: "ino"),
        L("processing", "Processing", "java", exts: "pde"),
        L("haxe", "Haxe", "javascript", exts: "hx hxml"),
        L("devicetree", "Device Tree", "c", exts: "dts dtsi"),

        // --- Scripting ------------------------------------------------------------------------
        L("python", "Python", "python",
          exts: "py pyw pyi pyx pxd pxi gyp gypi bzl star mojo gd rpy cpy",
          names: "SConstruct SConscript BUILD BUILD.bazel WORKSPACE WORKSPACE.bazel MODULE.bazel Snakefile Tiltfile meson.build meson_options.txt .pythonrc",
          sys: ["public.python-script": "py"]),
        L("ruby", "Ruby", "ruby", exts: "rb rbw rake gemspec podspec ru jbuilder rabl thor rbx rjs",
          names: "Gemfile Rakefile Podfile Fastfile Appfile Matchfile Pluginfile Brewfile Vagrantfile Guardfile Dangerfile Berksfile Capfile Thorfile Steepfile .irbrc .pryrc",
          sys: ["public.ruby-script": "rb rbw"]),
        L("php", "PHP", "php", exts: "php php3 php4 php5 php7 phtml phps ctp",
          sys: ["public.php-script": "php php3 php4 phtml"]),
        L("perl", "Perl", "", exts: "pl pm t pod psgi", names: "cpanfile",
          sys: ["public.perl-script": "pl pm"]),
        L("lua", "Lua", "lua", exts: "lua luau rockspec", names: ".luacheckrc", sys: ["org.tug.lua": "lua"]),
        L("r", "R", "", exts: "r rprofile", names: ".Rprofile", sys: ["com.apple.rez-source": "r"]),
        L("julia", "Julia", "", exts: "jl"),
        L("tcl", "Tcl", "", exts: "tcl tk"),
        L("awk", "AWK", "", exts: "awk gawk"),
        L("applescript", "AppleScript", "", exts: "applescript",
          sys: ["com.apple.applescript.text": "applescript"]),
        L("powershell", "PowerShell", "powershell", exts: "ps1 psm1 psd1"),
        L("batch", "Batch", "", exts: "bat cmd btm"),
        L("shell", "Shell", "shell", exts: "sh bash zsh ksh csh tcsh fish command tool ebuild eclass",
          names: ".bashrc .bash_profile .bash_login .bash_logout .bash_aliases .profile .zshrc .zprofile .zshenv .zlogin .zlogout .kshrc .cshrc .tcshrc .envrc .xinitrc .xprofile .xsession .inputrc .curlrc .bazelrc PKGBUILD APKBUILD",
          sys: ["public.shell-script": "sh", "public.bash-script": "bash", "public.zsh-script": "zsh",
                "public.csh-script": "csh", "public.tcsh-script": "tcsh", "public.ksh-script": "ksh",
                "com.apple.terminal.shell-script": "command tool"]),
        L("vim", "Vim Script", "", exts: "vim vimrc", names: ".vimrc .gvimrc _vimrc .ideavimrc .exrc"),
        L("elisp", "Emacs Lisp", "", exts: "el", names: ".emacs .spacemacs"),
        L("coffeescript", "CoffeeScript", "", exts: "coffee cson iced"),
        L("moonscript", "MoonScript", "", exts: "moon"),
        L("livescript", "LiveScript", "", exts: "ls"),

        // --- Web ------------------------------------------------------------------------------
        L("javascript", "JavaScript", "javascript", exts: "js mjs cjs jsx es6 jsm",
          sys: ["com.netscape.javascript-source": "js mjs"]),
        L("typescript", "TypeScript", "typescript", exts: "ts tsx mts cts",
          // .ts is owned by the MPEG-2 transport stream type. Real videos are detected as binary and
          // handed back to the system (generic preview).
          sys: ["com.microsoft.typescript": "ts tsx", "public.mpeg-2-transport-stream": "ts"]),
        L("vue", "Vue", "html", exts: "vue"),
        L("svelte", "Svelte", "html", exts: "svelte"),
        L("astro", "Astro", "html", exts: "astro"),
        L("html", "HTML", "html", exts: "html htm xhtml xht shtml", claim: false),
        L("serverpage", "Server Page", "html", exts: "jsp jspf asp aspx jshtm"),
        L("markdoc", "Markdoc", "html", exts: "mdoc", code: false),
        L("css", "CSS", "css", exts: "css", sys: ["public.css": "css"]),
        L("scss", "SCSS", "css", exts: "scss sass"),
        L("less", "Less", "css", exts: "less"),
        L("stylus", "Stylus", "", exts: "styl stylus"),
        L("handlebars", "Handlebars", "html", exts: "hbs handlebars mustache"),
        L("erb", "ERB", "html", exts: "erb rhtml"),
        L("twig", "Twig", "html", exts: "twig"),
        L("jinja", "Jinja", "html", exts: "j2 jinja jinja2 djhtml"),
        L("haml", "Haml", "", exts: "haml"),
        L("graphql", "GraphQL", "graphql", exts: "graphql gql graphqls"),
        L("prisma", "Prisma", "graphql", exts: "prisma"),
        L("http", "HTTP", "", exts: "http rest"),

        // --- Functional -----------------------------------------------------------------------
        L("haskell", "Haskell", "", exts: "hs lhs hsc hs-boot purs idr"),
        L("ocaml", "OCaml", "", exts: "ml mli mll mly"),
        L("reasonml", "ReasonML", "", exts: "re rei res resi"),
        L("sml", "Standard ML", "", exts: "sml sig"),
        L("elm", "Elm", "", exts: "elm"),
        L("clojure", "Clojure", "", exts: "clj cljs cljc edn bb"),
        L("elixir", "Elixir", "ruby", exts: "ex exs heex leex", names: "mix.lock"),
        L("erlang", "Erlang", "", exts: "erl hrl escript", names: "rebar.config rebar.lock sys.config"),
        L("lisp", "Lisp", "", exts: "lisp lsp fnl asd"),
        L("scheme", "Scheme", "", exts: "scm ss rkt sld sls"),
        L("gleam", "Gleam", "rust", exts: "gleam"),
        L("prolog", "Prolog", "", exts: "pro prolog"),
        L("mathematica", "Mathematica", "", exts: "wl wls nb"),
        L("sas", "SAS", "", exts: "sas"),
        L("stata", "Stata", "", exts: "do ado"),
        L("scilab", "Scilab", "", exts: "sci sce"),
        L("openscad", "OpenSCAD", "c", exts: "scad"),
        L("qml", "QML", "javascript", exts: "qml qmldir"),
        L("gcode", "G-code", "", exts: "gcode"),

        // --- Data / config --------------------------------------------------------------------
        L("json", "JSON", "json",
          exts: "json jsonc json5 jsonl ndjson geojson topojson webmanifest har jsonld ipynb avsc code-workspace code-snippets",
          names: ".babelrc .jshintrc .jscsrc .swcrc .bowerrc .watchmanconfig .arcconfig composer.lock flake.lock Pipfile.lock Package.resolved .tern-project",
          sys: ["public.json": "json", "public.ndjson": "ndjson", "public.geojson": "geojson"], code: false),
        L("rcfile", "Config", "yaml",
          names: ".eslintrc .prettierrc .stylelintrc .lintstagedrc .markdownlintrc .mocharc .nycrc .huskyrc .releaserc .commitlintrc .htmlhintrc .postcssrc .remarkrc .yarnrc",
          code: false),
        L("yaml", "YAML", "yaml", exts: "yaml yml cff",
          names: ".clang-format .clang-tidy .gemrc .yamllint .condarc Procfile pubspec.lock yarn.lock Podfile.lock .gitlab-ci.yml",
          sys: ["public.yaml": "yaml yml"], code: false),
        L("toml", "TOML", "toml", exts: "toml",
          names: "Cargo.lock poetry.lock uv.lock Pipfile rust-toolchain Gopkg.lock",
          sys: ["public.toml": "toml"], code: false),
        L("ini", "INI", "ini",
          exts: "ini cfg conf config cnf inf reg desktop service socket timer mount xcconfig tscn tres godot",
          names: ".editorconfig .gitconfig .gitmodules .npmrc .pypirc .flake8 .pylintrc .coveragerc .hgrc .my.cnf .wgetrc .tmux.conf",
          sys: ["com.microsoft.ini": "ini", "public.toml": "cfg config"], code: false),
        L("properties", "Properties", "ini", exts: "properties prefs", code: false),
        L("env", "Environment", "dotenv", exts: "env", names: ".env", code: false),
        L("ignore", "Ignore List", "",
          exts: "gitignore dockerignore npmignore",
          names: ".gitignore .gitattributes .dockerignore .npmignore .eslintignore .prettierignore .stylelintignore .hgignore .vscodeignore .gcloudignore .slugignore .helmignore .bzrignore .cvsignore .rgignore .ignore .fdignore CODEOWNERS",
          code: false),
        L("lockfile", "Lock File", "yaml", exts: "lock", code: false),
        L("xml", "XML", "xml",
          exts: "xml xsd xsl xslt wsdl rss atom xaml csproj vbproj vcxproj fsproj props targets nuspec resx storyboard xib iml fxml mxml kml gpx plist entitlements xcscheme xcworkspacedata xliff xlf dtd ascx wxi wxl wxs opf",
          sys: ["public.xml": "xml", "com.apple.property-list": "plist", "com.apple.xml-property-list": "plist",
                "public.rss": "rss", "com.apple.interfacebuilder.document.cocoa": "xib",
                "org.oasis-open.xliff": "xliff xlf", "com.apple.dt.document.scheme": "xcscheme"], code: false),
        L("pbxproj", "Xcode Project", "", exts: "pbxproj", code: false),
        L("sql", "SQL", "sql", exts: "sql ddl dml hql cql prql", sys: ["org.iso.sql": "sql"]),
        L("pgsql", "PostgreSQL", "sql", exts: "pgsql psql plpgsql"),
        L("protobuf", "Protocol Buffers", "proto", exts: "proto textproto pbtxt fbs",
          sys: ["public.protobuf-source": "proto"]),
        L("thrift", "Thrift", "", exts: "thrift"),
        L("capnp", "Cap'n Proto", "", exts: "capnp"),
        L("nix", "Nix", "", exts: "nix"),
        L("hcl", "HCL / Terraform", "ini", exts: "tf tfvars hcl nomad", code: false),
        L("puppet", "Puppet", "ruby", exts: "pp"),
        L("dns", "DNS Zone", "", exts: "zone", code: false),
        L("ldif", "LDIF", "", exts: "ldif", code: false),
        L("csv", "CSV", "", exts: "csv tsv", claim: false),
        // Shown by their own system previews; listed only so the CLI / app resolve them sensibly.
        L("svg", "SVG", "xml", exts: "svg", claim: false),
        L("postscript", "PostScript", "", exts: "ps eps ai", claim: false),

        // --- Build / infra --------------------------------------------------------------------
        L("makefile", "Makefile", "makefile", exts: "mk mak make gmk",
          names: "Makefile makefile GNUmakefile BSDmakefile Kbuild justfile Justfile .justfile",
          sys: ["public.make-source": "mk mak make gmk"]),
        L("cmake", "CMake", "cmake", exts: "cmake", names: "CMakeLists.txt"),
        L("dockerfile", "Dockerfile", "dockerfile", exts: "dockerfile containerfile", names: "Dockerfile Containerfile"),
        L("nginx", "Nginx", "", exts: "nginx", names: "nginx.conf", code: false),
        L("apache", "Apache", "", exts: "htaccess", names: ".htaccess .htpasswd httpd.conf apache2.conf", code: false),
        L("nsis", "NSIS", "", exts: "nsi nsh"),
        L("autohotkey", "AutoHotkey", "", exts: "ahk"),

        // --- Docs / text ----------------------------------------------------------------------
        L("markdown", "Markdown", "markdown", exts: "md markdown mdown mkd mkdn mdx qmd rmd livemd mdwn mdtxt mdtext",
          sys: ["net.daringfireball.markdown": "md markdown mdown mkd mkdn",
                "io.typora.markdown": "mdx qmd", "com.kingsoft.wpsoffice.markdown": "mkd mdown"], code: false),
        L("asciidoc", "AsciiDoc", "", exts: "adoc asciidoc", code: false),
        L("latex", "LaTeX", "", exts: "tex ltx latex sty cls dtx ins bib bbx cbx",
          sys: ["org.tug.tex": "tex", "edu.uo.texshop.ltx": "ltx latex", "org.tug.tex.bibtex": "bib"],
          code: false),
        L("diff", "Diff", "", exts: "diff patch rej", sys: ["public.patch-file": "diff patch"], code: false),
        L("gherkin", "Gherkin", "", exts: "feature", code: false),
        L("rst", "reStructuredText", "", exts: "rst rest", code: false),
        L("log", "Log", "", exts: "log", sys: ["com.apple.log": "log"], code: false),
        L("include", "Include File", "", exts: "inc", code: false),   // C, PHP, assembly... alike
        L("text", "Plain Text", "", exts: "txt text",
          names: "LICENSE LICENCE COPYING NOTICE AUTHORS CONTRIBUTORS CHANGELOG CHANGES HISTORY README TODO .nvmrc .node-version .ruby-version .python-version .tool-versions .mailmap requirements.txt",
          sys: ["public.plain-text": "txt text"], code: false),
    ]

    /// File-name prefixes (lower-case) -> language id. `Dockerfile.dev`, `.env.local`, ...
    public static let namePrefixes: [(prefix: String, language: String)] = [
        ("dockerfile.", "dockerfile"), ("containerfile.", "dockerfile"),
        ("makefile.", "makefile"), ("jenkinsfile.", "groovy"),
        (".env.", "env"), ("requirements", "text"), ("vagrantfile.", "ruby"),
        ("license", "text"), ("licence", "text"),
        ("readme", "text"), ("changelog", "text"),
    ]

    /// Wrapper extensions that are stripped before resolving: `config.yaml.example`, `Makefile.in`.
    public static let wrapperExtensions: Set<String> = [
        "in", "template", "tmpl", "tpl", "example", "sample", "dist", "default",
        "bak", "orig", "old", "new", "save", "local",
    ]

    // MARK: - Quick Look content types

    /// Generic types the main extension claims in addition to every per-language UTI.
    /// Third-party extensions are preferred over the legacy system generators for these.
    public static let genericContentTypes: [String] = [
        "public.source-code", "public.script", "public.shell-script",
        "public.plain-text", "public.utf8-plain-text", "public.text",
        "public.xml", "public.json", "public.yaml", "public.toml",
        "com.apple.ascii-property-list",
    ]

    /// Types the main extension must never claim, even if they end up in the list.
    public static let neverClaim: Set<String> = [
        "public.html", "public.rtf", "public.comma-separated-values-text",
        "public.tab-separated-values-text", "com.apple.rtfd", "public.data", "public.item",
        "public.content",
    ]

    /// The fallback extension catches files whose type is just "data" (dotfiles, unknown
    /// extensions). It sniffs the content and refuses binaries, so the system preview is used.
    public static let fallbackContentTypes: [String] = ["public.data"]

    // MARK: - Lookups

    public static let byID: [String: Language] = {
        var m: [String: Language] = [:]
        for l in all { precondition(m[l.id] == nil, "duplicate language id \(l.id)"); m[l.id] = l }
        return m
    }()

    /// lower-cased file name -> language
    public static let byName: [String: Language] = {
        var m: [String: Language] = [:]
        for l in all { for n in l.names { m[n.lowercased()] = m[n.lowercased()] ?? l } }
        return m
    }()

    /// Name of a Lithe language: ours when we list it, as "Objective-C" for "objective-c".
    public static func displayName(syntax id: String) -> String {
        let lithe = ["javascriptreact": "JavaScript (JSX)", "typescriptreact": "TypeScript (TSX)",
                     "jsonc": "JSON with Comments"]
        return lithe[id] ?? byID[id]?.name ?? all.first { $0.syntax == id }?.name ?? id
    }

    /// extension -> language (first declaration wins)
    public static let byExtension: [String: Language] = {
        var m: [String: Language] = [:]
        for l in all { for e in l.exts where m[e] == nil { m[e] = l } }
        return m
    }()
}
