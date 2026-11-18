#if MCPServer
import Foundation
import Logging
import MCP
import Wax
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum HTTPAuthPolicy {
    private static let loopbackNames: Set<String> = ["localhost", "127.0.0.1", "::1"]

    static func requiresAuthentication(host rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch host {
        case "localhost", "127.0.0.1", "::1", "[::1]":
            return false
        default:
            return true
        }
    }

    /// A configured token is required on every bind, loopback included:
    /// other local users and processes can reach a loopback port. Without
    /// a token only loopback binds start (see `start()`), and they stay open
    /// to local clients that pass the Host/Origin check.
    static func requiresBearerToken(host: String, configuredToken: String?) -> Bool {
        normalizedToken(configuredToken) != nil || requiresAuthentication(host: host)
    }

    static func normalizedToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isAuthorized(requestToken: String?, configuredToken: String?) -> Bool {
        guard let configuredToken = normalizedToken(configuredToken),
              let requestToken else {
            return false
        }
        let trimmed = requestToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Bearer "
        guard trimmed.hasPrefix(prefix) else { return false }
        return constantTimeEquals(String(trimmed.dropFirst(prefix.count)), configuredToken)
    }

    /// Compares every byte of the longer input so timing does not reveal
    /// the length of the matching prefix.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt(left.count ^ right.count)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= UInt(a ^ b)
        }
        return difference == 0
    }

    static func isSafeLoopbackRequest(hostHeader: String?, originHeader: String?) -> Bool {
        if let hostHeader, !hostHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let host = hostFromHTTPHostHeader(hostHeader), isLoopbackHost(host) else {
                return false
            }
        }

        if let originHeader, !originHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let origin = URL(string: originHeader.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = origin.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  origin.user == nil,
                  origin.password == nil,
                  let host = origin.host,
                  isLoopbackHost(host)
            else {
                return false
            }
        }
        return true
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        loopbackNames.contains(
            host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        )
    }

    private static func hostFromHTTPHostHeader(_ raw: String) -> String? {
        let authority = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authority.isEmpty, !authority.contains("@") else { return nil }
        if authority.hasPrefix("[") {
            guard let end = authority.firstIndex(of: "]") else { return nil }
            let host = String(authority[authority.index(after: authority.startIndex)..<end])
            return host.isEmpty ? nil : host
        }
        let host = authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        return host.isEmpty ? nil : host
    }
}

enum HTTPRequestBodyLimit {
    static func exceedsLimit(
        currentBytes: Int,
        incomingBytes: Int,
        contentLength: Int?,
        maxBytes: Int
    ) -> Bool {
        if let contentLength, contentLength > maxBytes {
            return true
        }
        guard incomingBytes <= maxBytes else { return true }
        return currentBytes > maxBytes - incomingBytes
    }
}
#endif
