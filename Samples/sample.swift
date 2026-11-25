import Foundation

/// Computes the `dyn.*` identifier macOS assigns to a file extension nobody has declared.
///
/// Quick Look dispatches on the exact type identifier, so an extension that is not declared
/// by any installed app (e.g. `.rs` on a stock system) gets a dynamic UTI such as
/// `dyn.ah62d4rv4ge81e62`. Listing those in `QLSupportedContentTypes` keeps previews working
/// even when the host app's imported declarations are not (yet) registered.
public enum DynamicUTI {
    private static let alphabet = Array("abcdefghkmnpqrstuvwxyz0123456789")

    public static func forFilenameExtension(_ ext: String) -> String {
        // "?0=6:1=<ext>": tag class 6 (public.filename-extension) = ext, 5-bit packed, MSB first.
        "dyn.a" + encode("?0=6:1=\(ext)")
    }

    static func encode(_ s: String) -> String {
        var out = ""
        var acc: UInt32 = 0
        var bits = 0
        for byte in s.utf8 {
            acc = (acc << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((acc >> UInt32(bits)) & 0x1F)])
            }
        }
        if bits > 0 { out.append(alphabet[Int((acc << UInt32(5 - bits)) & 0x1F)]) }
        return out
    }
}
