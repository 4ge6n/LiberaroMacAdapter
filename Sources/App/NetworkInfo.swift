import Foundation

enum NetworkInfo {
    /// LAN 上の IPv4 アドレスを列挙する。`en0` (通常 Wi-Fi) を優先し、
    /// 無ければ最初に見つかったアクティブな非ループバック IPv4 を返す。
    static func primaryLANAddress() -> String? {
        var addresses: [String: String] = [:] // interface name -> ip

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            addresses[name] = String(cString: host)
        }

        if let en0 = addresses["en0"] { return en0 }
        return addresses.first?.value
    }
}
