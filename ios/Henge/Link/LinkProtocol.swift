import Foundation

// Original protocol. Never deserialize an unbounded peer-controlled allocation.
enum LinkError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(s) = self { return s }; return nil }
}
struct LinkMode: Codable, Equatable {
    var width: Int, height: Int, widthMM: Int, heightMM: Int, hz: Int
    var codedWidth: Int { (width + 1) & ~1 }
    var codedHeight: Int { (height + 1) & ~1 }
    func validate() throws {
        guard (320...8192).contains(width), (240...8192).contains(height), width * height <= 33_554_432,
              (1...65535).contains(widthMM), (1...65535).contains(heightMM), (24...120).contains(hz) else {
            throw LinkError.invalid("Unsupported display mode")
        }
    }
}
struct LinkControl: Codable {
    static let currentVersion = 2
    var version = Self.currentVersion
    var type: String
    var mode: LinkMode? = nil
    var x: Int? = nil, y: Int? = nil, code: Int? = nil, down: Bool? = nil
    var sequence: UInt64? = nil
    var visible: Bool? = nil
    var capabilities: [String]? = nil
    var gamepad: GamepadState? = nil
    var supportsViewerVisibility: Bool { ["ready","readyInput","readyMirror"].contains(type) && capabilities?.contains("viewerVisibility") == true }
    func validate() throws {
        guard version == Self.currentVersion else { throw LinkError.invalid("Update Henge on both devices: different Link protocol version") }
        if let capabilities, capabilities.count > 8 || capabilities.contains(where: { $0.utf8.count > 64 }) {
            throw LinkError.invalid("Invalid capability list")
        }
        switch type {
        case "hello", "ready", "readyMirror": guard let mode else { throw LinkError.invalid("Missing display mode") }; try mode.validate()
        case "helloInput", "readyInput": guard mode == nil else { throw LinkError.invalid("Controls-only connections have no video mode") }
        case "gamepad": guard let gamepad, gamepad.valid else { throw LinkError.invalid("Invalid gamepad state") }
        case "padMode": guard down != nil else { throw LinkError.invalid("Missing gamepad mapping") }
        case "mirror": guard down != nil,x==nil || [30,60,120].contains(x!) else { throw LinkError.invalid("Invalid mirror refresh request") }
        case "move", "scroll": guard let x, let y, (-4096...4096).contains(x), (-4096...4096).contains(y) else { throw LinkError.invalid("Invalid pointer delta") }
        case "button": guard let code, (0...2).contains(code), down != nil else { throw LinkError.invalid("Invalid button") }
        case "key": guard let code, (4...231).contains(code), down != nil else { throw LinkError.invalid("Invalid HID key") }
        case "videoAck": guard let sequence, sequence > 0 else { throw LinkError.invalid("Invalid video acknowledgement") }
        case "visibility": guard visible != nil else { throw LinkError.invalid("Missing viewer visibility") }
        case "ping", "pong", "bye", "release": break
        default: throw LinkError.invalid("Unknown control message")
        }
    }
}
struct LinkPacket {
    static let maximum = 16 * 1024 * 1024
    let kind: UInt8
    let payload: Data
    func wire() throws -> Data {
        guard (1...2).contains(kind), payload.count < Self.maximum else { throw LinkError.invalid("Oversize packet") }
        var n = UInt32(payload.count + 1).bigEndian
        var result = Data(bytes: &n, count: 4); result.append(kind); result.append(payload); return result
    }
}
struct LinkParser {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [LinkPacket] {
        guard data.count <= 65536, buffer.count + data.count <= LinkPacket.maximum + 65540 else { throw LinkError.invalid("Receive buffer limit") }
        buffer.append(data)
        var output = [LinkPacket]()
        while buffer.count >= 4 {
            let n = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard n >= 1, n <= LinkPacket.maximum else { throw LinkError.invalid("Invalid packet length") }
            guard buffer.count >= n + 4 else { break }
            let kind = buffer[buffer.startIndex + 4]
            guard kind == 1 || kind == 2 else { throw LinkError.invalid("Invalid packet type") }
            output.append(LinkPacket(kind: kind, payload: Data(buffer.dropFirst(5).prefix(n - 1))))
            buffer = Data(buffer.dropFirst(n + 4))
        }
        return output
    }
}
struct LinkVideoHeader: Codable {
    var codec: String, width: Int, height: Int, sequence: UInt64
    var parameterSets: [Data]
    var codedWidth: Int? = nil, codedHeight: Int? = nil
    var encodedWidth: Int { codedWidth ?? width }
    var encodedHeight: Int { codedHeight ?? height }
    func pack(_ data: Data) throws -> Data {
        let meta = try JSONEncoder().encode(self)
        guard meta.count <= 65536, data.count > 0 else { throw LinkError.invalid("Invalid video payload") }
        var n = UInt32(meta.count).bigEndian
        var out = Data(bytes: &n, count: 4); out.append(meta); out.append(data); return out
    }
    static func unpack(_ payload: Data) throws -> (Self, Data) {
        guard payload.count >= 5 else { throw LinkError.invalid("Short video payload") }
        let n = payload.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard n > 0, n <= 65536, payload.count > n + 4 else { throw LinkError.invalid("Invalid video header") }
        let meta = try JSONDecoder().decode(Self.self, from: payload.subdata(in: 4..<4+n))
        guard meta.codec == "hevc" || meta.codec == "h264", (320...8192).contains(meta.width), (240...8192).contains(meta.height), meta.width * meta.height <= 33_554_432,
              (2...3).contains(meta.parameterSets.count), meta.parameterSets.allSatisfy({ !$0.isEmpty && $0.count <= 16384 }) else { throw LinkError.invalid("Invalid codec configuration") }
        // A native odd-sized viewport is padded by at most one pixel per axis
        // for the hardware chroma format. It is never rescaled or truncated.
        guard meta.encodedWidth >= meta.width, meta.encodedWidth <= ((meta.width + 1) & ~1),
              meta.encodedHeight >= meta.height, meta.encodedHeight <= ((meta.height + 1) & ~1),
              meta.encodedWidth <= 8192, meta.encodedHeight <= 8192,
              meta.encodedWidth * meta.encodedHeight <= 33_554_432 else { throw LinkError.invalid("Invalid codec canvas") }
        return (meta, Data(payload.dropFirst(4+n)))
    }
}
