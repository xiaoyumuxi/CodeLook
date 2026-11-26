import Foundation
import UniformTypeIdentifiers

// codelook-gen — writes the Info.plists from Shared/LanguageTable.swift.
//
//   codelook-gen [--local] <project-root>     write App/Info.plist, Extension/*-Info.plist
//   codelook-gen --release <project-root>     the same, for a build that is installed elsewhere
//   codelook-gen --check   <project-root>     report how this Mac's types are covered
//
// --local also claims the UTIs this Mac assigns to our extensions / file names (types declared
// by third-party apps such as editors), so the build covers this machine exactly.
//
// Extensions that ~/.config/codelook/config.yaml maps (files, grammars) are claimed too; file
// names need nothing, the fallback extension already takes files without a type.
//
// --release does neither: a downloaded build gets both on the user's Mac instead, when
// install.sh runs `CodeLook --update-claims` (ClaimSet in Shared/QuickLookClaims.swift).

let args = Array(CommandLine.arguments.dropFirst())
let release = args.contains("--release")
let local = args.contains("--local") && !release
let check = args.contains("--check")
guard let rootPath = args.last(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write(Data("usage: codelook-gen [--local|--release|--check] <project-root>\n".utf8))
    exit(2)
}
let root = URL(fileURLWithPath: rootPath)

func write(_ plist: [String: Any], to rel: String) throws {
    let url = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    if (try? Data(contentsOf: url)) == data { print("  unchanged \(rel)"); return }
    try data.write(to: url)
    print("  wrote     \(rel)")
}

func bundleKeys(packageType: String, displayName: String) -> [String: Any] {
    [
        "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
        "CFBundleDisplayName": displayName,
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundlePackageType": packageType,
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
    ]
}

func extensionPlist(displayName: String, types: [String]) -> [String: Any] {
    var p = bundleKeys(packageType: "$(PRODUCT_BUNDLE_PACKAGE_TYPE)", displayName: displayName)
    p["NSExtension"] = [
        "NSExtensionAttributes": [
            "QLIsDataBasedPreview": false,
            "QLSupportsSearchableItems": false,
            "QLSupportedContentTypes": types,
        ],
        "NSExtensionPointIdentifier": "com.apple.quicklook.preview",
        "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).PreviewViewController",
    ]
    return p
}

// MARK: - check

if check {
    let preview = Set(Coverage.supportedTypes(infoPlist: root.appendingPathComponent("Extension/Preview-Info.plist")))
    let fallback = Set(Coverage.supportedTypes(infoPlist: root.appendingPathComponent("Extension/Fallback-Info.plist")))
    guard !preview.isEmpty else { print("Extension/Preview-Info.plist missing — run without --check first"); exit(1) }
    let results = TypeProbe.run()
    var counts: [String: Int] = [:]
    var dynMismatch = 0
    for r in results {
        let v = Coverage.verdict(for: r.type, preview: preview, fallback: fallback)
        let tag: String
        switch v {
        case .exact: tag = "exact"
        case .inherited(let p): tag = "inherited \(p)"
        case .fallback: tag = "fallback"
        case .uncovered: tag = "UNCOVERED"
        }
        counts[tag.split(separator: " ").first.map(String.init) ?? tag, default: 0] += 1
        if r.type.hasPrefix("dyn."), let ext = r.sample.split(separator: ".").last.map(String.init),
           r.sample.hasPrefix("sample."), DynamicUTI.forFilenameExtension(ext) != r.type {
            dynMismatch += 1
            print("  dyn mismatch: \(r.sample) → \(r.type), computed \(DynamicUTI.forFilenameExtension(ext))")
        }
        if v.isProblem { print(String(format: "  %-34@ %-18@ %-48@ %@", r.sample as NSString, r.languageName as NSString, r.type as NSString, tag as NSString)) }
    }
    print("\n\(results.count) samples: " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    if dynMismatch > 0 { print("dynamic UTI mismatches: \(dynMismatch)") }
    exit(counts["UNCOVERED", default: 0] > 0 ? 1 : 0)
}

// MARK: - write

let claims = ClaimSet.compute(local: local, config: release ? nil : CodeLookConfig.current())
claims.report.forEach { print($0) }
let previewTypes = claims.previewTypes
let imports = claims.imports

var app = bundleKeys(packageType: "$(PRODUCT_BUNDLE_PACKAGE_TYPE)", displayName: "CodeLook")
app["LSApplicationCategoryType"] = "public.app-category.developer-tools"
app["NSPrincipalClass"] = "NSApplication"
app["NSHumanReadableCopyright"] = "CodeLook · syntax engine from Lithe · JetBrains Mono (SIL OFL 1.1)"
app["UTImportedTypeDeclarations"] = imports

do {
    print("codelook-gen: \(LanguageTable.all.count) languages, \(previewTypes.count) preview types, \(imports.count) imported UTIs")
    try write(app, to: "App/Info.plist")
    try write(extensionPlist(displayName: "CodeLook", types: previewTypes), to: "Extension/Preview-Info.plist")
    try write(extensionPlist(displayName: "CodeLook Fallback", types: QuickLookClaims.fallbackTypes()),
              to: "Extension/Fallback-Info.plist")
} catch {
    FileHandle.standardError.write(Data("codelook-gen: \(error)\n".utf8))
    exit(1)
}
