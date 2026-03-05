import Foundation

package extension Data {
    /// Lowercased hex string encoding.
    var hexString: String {
        var out = String()
        out.reserveCapacity(count * 2)
        for byte in self {
            let hi = Int(byte >> 4)
            let lo = Int(byte & 0x0F)
            out.append(Self.hexTable[hi])
            out.append(Self.hexTable[lo])
        }
        return out
    }

    private static let hexTable: [Character] = Array("0123456789abcdef")
}

