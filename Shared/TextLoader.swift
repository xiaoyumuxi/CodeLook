import Foundation

public struct LoadedText {
    public var text: String
    public var encoding: String
    public var fileSize: Int
    /// Only the first `maxBytes` were read.
    public var truncated: Bool
    /// Set when the content was converted (e.g. binary plist -> XML).
    public var convertedFrom: String?
}

public enum TextLoaderError: Error, LocalizedError {
    case binary
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .binary: return "File looks binary"
        case .unreadable(let why): return "Cannot read file: \(why)"
        }
    }
}

public enum TextLoader {
    public static func load(url: URL, maxBytes: Int) throws -> LoadedText {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var data: Data
        do {
            let fh = try FileHandle(forReadingFrom: url)
            defer { try? fh.close() }
            // Sniff the head first so binaries (the fallback extension sees many) are refused
            // without reading megabytes.
            data = try fh.read(upToCount: min(maxBytes, 8192)) ?? Data()
            if looksBinary(head: data) { throw TextLoaderError.binary }
            if data.count == 8192, maxBytes > 8192 { data += try fh.read(upToCount: maxBytes - 8192) ?? Data() }
        } catch let e as TextLoaderError {
            throw e
        } catch {
            throw TextLoaderError.unreadable(error.localizedDescription)
        }
        let truncated = size > data.count
        return try decode(data, fileSize: max(size, data.count), truncated: truncated)
    }

    public static func decode(_ input: Data, fileSize: Int, truncated: Bool) throws -> LoadedText {
        var data = input

        // Binary property lists -> XML text.
        if data.starts(with: Array("bplist0".utf8)) {
            guard !truncated,
                  let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0),
                  let s = String(data: xml, encoding: .utf8) else { throw TextLoaderError.binary }
            return LoadedText(text: s, encoding: "UTF-8", fileSize: fileSize, truncated: false,
                              convertedFrom: "binary plist")
        }

        // BOMs
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data = data.dropFirst(3)
            return LoadedText(text: decodeUTF8(data, truncated: truncated), encoding: "UTF-8 BOM",
                              fileSize: fileSize, truncated: truncated)
        }
        for (bom, enc, name) in [([UInt8]([0xFF, 0xFE, 0, 0]), String.Encoding.utf32LittleEndian, "UTF-32LE"),
                                 ([0, 0, 0xFE, 0xFF], .utf32BigEndian, "UTF-32BE"),
                                 ([0xFF, 0xFE], .utf16LittleEndian, "UTF-16LE"),
                                 ([0xFE, 0xFF], .utf16BigEndian, "UTF-16BE")] where data.starts(with: bom) {
            let body = data.dropFirst(bom.count)
            let unit = name.hasPrefix("UTF-32") ? 4 : 2
            let usable = body.prefix(body.count - body.count % unit)
            if let s = String(data: usable, encoding: enc) {
                return LoadedText(text: s, encoding: name, fileSize: fileSize, truncated: truncated)
            }
        }

        // NUL bytes: either BOM-less UTF-16 or binary.
        let sample = data.prefix(8192)
        let nulCount = sample.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
        if nulCount > 0 {
            if let (s, name) = guessUTF16(data) {
                return LoadedText(text: s, encoding: name, fileSize: fileSize, truncated: truncated)
            }
            throw TextLoaderError.binary
        }

        // MPEG transport stream (.ts videos) without NULs in the first block.
        if sample.count >= 377, sample[sample.startIndex] == 0x47,
           sample[sample.startIndex + 188] == 0x47, sample[sample.startIndex + 376] == 0x47 {
            throw TextLoaderError.binary
        }

        if let s = strictUTF8(data, truncated: truncated) {
            try rejectControlHeavy(s)
            return LoadedText(text: s, encoding: "UTF-8", fileSize: fileSize, truncated: truncated)
        }

        // Legacy encodings (GB18030 first: most likely non-UTF-8 source here).
        var converted: NSString?
        var lossy: ObjCBool = false
        let suggestions: [String.Encoding] = [
            cf(.GB_18030_2000), cf(.big5), .shiftJIS, cf(.EUC_KR), .windowsCP1252, .isoLatin1,
        ]
        let detected = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: suggestions.map { $0.rawValue },
            .allowLossyKey: false,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        if detected != 0, let s = converted as String? {
            try rejectControlHeavy(s)
            let name = CFStringGetNameOfEncoding(CFStringConvertNSStringEncodingToEncoding(detected)) as String?
            return LoadedText(text: s, encoding: name ?? "Unknown", fileSize: fileSize, truncated: truncated)
        }

        let s = decodeUTF8(data, truncated: truncated)
        try rejectControlHeavy(s)
        return LoadedText(text: s, encoding: "UTF-8 (lossy)", fileSize: fileSize, truncated: truncated)
    }

    // MARK: - Helpers

    /// Quick verdict on the first block: NUL bytes that are not UTF-16/32 text.
    static func looksBinary(head: Data) -> Bool {
        guard head.contains(0) else { return false }
        if head.starts(with: Array("bplist0".utf8)) { return false }
        for bom in [[0xFF, 0xFE], [0xFE, 0xFF], [0, 0, 0xFE, 0xFF]] as [[UInt8]] where head.starts(with: bom) { return false }
        return utf16Order(head) == nil
    }

    private static func cf(_ e: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
    }

    /// Strict UTF-8; if the data was cut mid-character, drop the incomplete tail.
    private static func strictUTF8(_ data: Data, truncated: Bool) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        guard truncated else { return nil }
        for drop in 1...3 where data.count > drop {
            if let s = String(data: data.dropLast(drop), encoding: .utf8) { return s }
        }
        return nil
    }

    private static func decodeUTF8(_ data: Data, truncated: Bool) -> String {
        strictUTF8(data, truncated: truncated) ?? String(decoding: data, as: UTF8.self)
    }

    /// Byte order of BOM-less UTF-16, judged from where the NUL bytes sit.
    private static func utf16Order(_ data: Data) -> (String.Encoding, String)? {
        let sample = Array(data.prefix(4096))
        guard sample.count >= 4 else { return nil }
        var evenNul = 0, oddNul = 0
        for (i, b) in sample.enumerated() where b == 0 { if i % 2 == 0 { evenNul += 1 } else { oddNul += 1 } }
        let half = sample.count / 2
        if oddNul > half * 7 / 10 && evenNul < half / 20 { return (.utf16LittleEndian, "UTF-16LE") }
        if evenNul > half * 7 / 10 && oddNul < half / 20 { return (.utf16BigEndian, "UTF-16BE") }
        return nil
    }

    private static func guessUTF16(_ data: Data) -> (String, String)? {
        guard let (enc, name) = utf16Order(data) else { return nil }
        var body = data.prefix(data.count - data.count % 2)
        // A cut surrogate pair at the end makes the whole decode fail; drop it.
        for _ in 0..<2 {
            if let s = String(data: body, encoding: enc) { return (s, name) }
            body = body.dropLast(2)
        }
        return nil
    }

    /// Text with lots of C0 control characters is almost certainly a binary format.
    private static func rejectControlHeavy(_ s: String) throws {
        var control = 0, total = 0
        for u in s.unicodeScalars.prefix(8192) {
            total += 1
            let v = u.value
            if v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D && v != 0x0C && v != 0x1B { control += 1 }
            else if v == 0xFFFD { control += 1 }
        }
        if total > 0 && control * 100 / total > 5 { throw TextLoaderError.binary }
    }
}
