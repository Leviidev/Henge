// The loopback VPN Henge's JIT helper reaches this device's developer services through.
//
// Based on LocalDevVPN (https://github.com/jkcoxson/LocalDevVPN), formerly StosVPN, by the SideStore Team
// and Jackson Coxson. Its license asks that derived work say so and credit them; see third_party/LocalDevVPN/LICENSE.
//
// Only 10.7.0.1 is routed into the tunnel. Each IPv4 packet that comes in has its source and destination
// swapped and goes straight back out, so a connection Henge's helper opens to 10.7.0.1 arrives at this device
// as if from another computer on the network, which is what lets its developer services accept it.
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    /// The tunnel's own address, and the address it stands in for: StikJIT's default device address.
    static let interfaceAddress = "10.7.1.1"
    static let peerAddress = "10.7.0.1"

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let ipv4 = NEIPv4Settings(addresses: [Self.interfaceAddress], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: Self.peerAddress, subnetMask: "255.255.255.255")]
        ipv4.excludedRoutes = [.default()]
        // tunnelRemoteAddress is only what Settings shows; it plays no part in routing.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Self.peerAddress)
        settings.ipv4Settings = ipv4
        setTunnelNetworkSettings(settings) { [weak self] error in
            if error == nil { self?.reflect() }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    /// Reads packets and writes each IPv4 one back with its source and destination addresses swapped (bytes 12-19
    /// of the header). Swapping two 32-bit words leaves the header checksum valid.
    private func reflect() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            var out = packets
            for i in out.indices where protocols[i].int32Value == AF_INET && out[i].count >= 20 {
                out[i].withUnsafeMutableBytes { bytes in
                    guard let words = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
                    (words[3], words[4]) = (words[4], words[3])
                }
            }
            packetFlow.writePackets(out, withProtocols: protocols)
            reflect()
        }
    }
}
