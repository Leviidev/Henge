// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// This device's own IP addresses, to tell its `_remotepairing._tcp` service from those of other Apple devices on
/// the same network: every iPhone, iPad, Mac and Vision Pro advertises one, and the first to answer a browse is
/// often not this device. Using another device's port, the helper times out at 10.7.0.1. Built into Henge and
/// its JIT helper.
enum OwnAddresses {
    /// The raw bytes (4 for IPv4, 16 for IPv6) of every address on this device's interfaces.
    static func current() -> Set<Data> {
        var result = Set<Data>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            if let address = entry.pointee.ifa_addr, let bytes = raw(UnsafePointer(address)) { result.insert(bytes) }
        }
        return result
    }

    /// Whether `bytes` (4 or 16) is one of this device's addresses.
    static func isOwn(_ bytes: Data) -> Bool { current().contains(normalized(bytes)) }

    /// Whether `host` (an mDNS name such as `Apple-Vision-Pro.local.`) resolves to one of this device's addresses.
    /// Blocks while it resolves.
    static func isThisDevice(host: String) -> Bool {
        let own = current()
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &found) == 0, let first = found else { return false }
        defer { freeaddrinfo(found) }
        return sequence(first: first, next: { $0.pointee.ai_next }).contains { entry in
            guard let address = entry.pointee.ai_addr, let bytes = raw(UnsafePointer(address)) else { return false }
            return own.contains(bytes)
        }
    }

    private static func raw(_ address: UnsafePointer<sockaddr>) -> Data? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Data($0) }
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                normalized(withUnsafeBytes(of: $0.pointee.sin6_addr) { Data($0) })
            }
        default:
            return nil
        }
    }

    /// Darwin keeps a link-local IPv6 address's scope in its bytes 2 and 3 in some places and not others; clear it
    /// so the same address compares equal.
    private static func normalized(_ bytes: Data) -> Data {
        guard bytes.count == 16, bytes[bytes.startIndex] == 0xfe, bytes[bytes.startIndex + 1] & 0xc0 == 0x80 else {
            return bytes
        }
        var copy = bytes
        copy[copy.startIndex + 2] = 0
        copy[copy.startIndex + 3] = 0
        return copy
    }
}
