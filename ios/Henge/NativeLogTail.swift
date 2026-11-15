import Foundation
import Darwin

/// Mirrors an append-only log when the filesystem reports a write. The raw
/// writer stays synchronous, so a crash does not depend on this queue running.
/// The caller owns fd and must keep it open until cancellation completes.
final class NativeLogTail {
    private let fd: Int32
    private let queue = DispatchQueue(label: "com.henge.log.reader", qos: .utility)
    private let source: DispatchSourceFileSystemObject
    private let emit: (String) -> Void
    private var pending = Data()
    private var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    private var drains = 0

    init(fd: Int32, emit: @escaping (String) -> Void) {
        self.fd = fd
        self.emit = emit
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        // Catch bytes written before registration. This and notifications run
        // on one queue, so overlapping writes cannot duplicate a line.
        queue.async { [weak self] in self?.drain() }
    }

    var drainCount: Int { queue.sync { drains } }

    func stop(completion: @escaping () -> Void) {
        source.setCancelHandler(handler: completion)
        source.cancel()
    }

    private func drain() {
        drains += 1
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }
            pending.append(contentsOf: buffer[0..<n])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                if let text = String(data: line, encoding: .utf8) { emit(text) }
            }
        }
    }
}
