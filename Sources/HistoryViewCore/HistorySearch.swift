import CUnicode
import Foundation

/// The same normalization is used for indexing and query terms.
public enum HistorySearch {
    public static func normalize(_ text: String) -> String {
        // NFKC is compatibility decomposition followed by canonical composition.
        // Foundation's direct compatibility-precomposed property leaves some
        // half-width kana decomposed on macOS, so perform both steps explicitly.
        let folded = casefold(text.decomposedStringWithCompatibilityMapping.precomposedStringWithCanonicalMapping)
        var result = ""
        for scalar in folded.unicodeScalars {
            let n = scalar.value
            if (0x30a1...0x30f6).contains(n) || n == 0x30fd || n == 0x30fe {
                result.unicodeScalars.append(UnicodeScalar(n - 0x60)!)
            } else if (0x30f7...0x30fa).contains(n) {
                let chars = ["わ", "ゐ", "ゑ", "を"]
                result += chars[Int(n - 0x30f7)] + "\u{3099}"
            } else { result.unicodeScalars.append(scalar) }
        }
        return result
    }
    private static func casefold(_ input: String) -> String {
        let source = Array(input.utf16)
        guard source.count < Int(Int32.max) else { return input }
        var status: Int32 = 0
        let required = source.withUnsafeBufferPointer { history_casefold(nil, 0, $0.baseAddress, Int32($0.count), &status) }
        guard required >= 0, status == 15 || status <= 0 else { return input }
        var output = [UInt16](repeating: 0, count: Int(required) + 1)
        status = 0
        let written = source.withUnsafeBufferPointer { sourceBuffer in
            output.withUnsafeMutableBufferPointer { destination in
                history_casefold(destination.baseAddress, Int32(destination.count), sourceBuffer.baseAddress, Int32(sourceBuffer.count), &status)
            }
        }
        guard status <= 0, written >= 0 else { return input }
        return String(decoding: output.prefix(Int(written)), as: UTF16.self)
    }
}
