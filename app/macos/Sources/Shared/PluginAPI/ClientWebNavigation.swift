import Darwin
import Foundation

/// Identifies loopback addresses when choosing a local page's default URL scheme.
public enum ClientWebNavigation {
    public static func isLoopback(_ url: URL) -> Bool {
        guard let raw = url.host else { return false }
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host == "localhost" || host.hasSuffix(".localhost") { return true }

        var address = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 {
            return withUnsafeBytes(of: address) { bytes in
                let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
                let mapped = bytes.prefix(10).allSatisfy { $0 == 0 }
                    && bytes[10] == 255 && bytes[11] == 255 && bytes[12] == 127
                return loopback || mapped
            }
        }

        // WebKit follows the URL standard's shortened/hex/octal IPv4 forms.
        // Parse numeric components instead of matching a `127.` prefix, which
        // would incorrectly reject ordinary host names such as 127.example.org.
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return false }
        var values: [UInt64] = []
        for piece in pieces {
            guard !piece.isEmpty else { return false }
            var digits = String(piece), radix = 10
            if digits.hasPrefix("0x") { radix = 16; digits.removeFirst(2) }
            else if digits.count > 1 && digits.first == "0" { radix = 8; digits.removeFirst() }
            guard let value = digits.isEmpty ? 0 : UInt64(digits, radix: radix) else { return false }
            values.append(value)
        }
        guard values.dropLast().allSatisfy({ $0 <= 255 }), let last = values.last,
              last < UInt64(1) << (8 * (5 - values.count)) else { return false }
        var ipv4 = last
        for (index, value) in values.dropLast().enumerated() { ipv4 += value << (8 * (3 - index)) }
        return ipv4 >> 24 == 127
    }
}
