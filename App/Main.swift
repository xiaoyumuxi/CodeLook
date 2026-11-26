import Foundation

/// The app is also install.sh's tool for fitting a downloaded build to this Mac:
///
///   CodeLook.app/Contents/MacOS/CodeLook --update-claims
///
/// claims the types this Mac's apps give our extensions and the extensions config.yaml maps, by
/// rewriting this bundle's Info.plists (see `ClaimSet`). That breaks the bundle's signature; the
/// caller signs it again and re-registers it. Anything else opens the window.
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments.dropFirst()
        guard args.contains("--update-claims") else {
            CodeLookApp.main()
            return
        }
        let claims = ClaimSet.compute(local: true, config: CodeLookConfig.current())
        claims.report.forEach { print($0) }
        do {
            let changed = try claims.apply(toApp: Bundle.main.bundleURL)
            print("\(claims.previewTypes.count) preview types, \(claims.imports.count) imported UTIs, "
                  + (changed.isEmpty ? "Info.plists unchanged" : "\(changed.count) Info.plist(s) updated"))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("CodeLook --update-claims: \(error)\n".utf8))
            exit(1)
        }
    }
}
