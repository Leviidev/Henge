import Foundation
import Darwin

@main struct NativeLogTailTests {
    static func main() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let writer = open(url.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        let reader = open(url.path, O_RDONLY)
        precondition(writer >= 0 && reader >= 0)
        defer { close(writer); close(reader); try? FileManager.default.removeItem(at: url) }
        func append(_ s: String) {
            let data = Data(s.utf8)
            let n = data.withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
            precondition(n == data.count)
        }
        append("before\n")
        let first = DispatchSemaphore(value: 0), burst = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var lines = [String]()
        let tail = NativeLogTail(fd: reader) { line in
            lock.lock(); lines.append(line); lock.unlock()
            if line == "before" { first.signal() }
            if line == "line-999" { burst.signal() }
        }
        precondition(first.wait(timeout: .now() + 3) == .success)
        append("partial")
        append("-日本語\n")
        append((0..<1000).map { "line-\($0)\n" }.joined())
        precondition(burst.wait(timeout: .now() + 3) == .success)
        lock.lock()
        precondition(lines == ["before", "partial-日本語"] + (0..<1000).map { "line-\($0)" })
        lock.unlock()
        // Allow already-queued coalesced file notifications to settle, then
        // prove a quiet file has no recurring drain calls (old loop: 25/sec).
        Thread.sleep(forTimeInterval: 0.15)
        let baseline = tail.drainCount
        Thread.sleep(forTimeInterval: 0.25)
        precondition(tail.drainCount == baseline)
        let stopped = DispatchSemaphore(value: 0)
        tail.stop { stopped.signal() }
        precondition(stopped.wait(timeout: .now() + 3) == .success)
        print("event-driven native log: initial bytes, partial UTF-8 line, 1000-line burst, no idle polling and cancellation passed")
    }
}
