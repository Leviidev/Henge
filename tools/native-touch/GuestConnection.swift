import Foundation

/// Multiplexes requests through the sharing helper's standard-I/O pipes.
/// The touch app has no network connection or listener of its own.
actor GuestConnection {
    private struct Request: Encodable {
        let version = 1
        let id: UInt64
        let method: String
        let path: String
        let body: Data?
    }
    private struct Reply: Decodable {
        let version: Int
        let id: UInt64
        let status: Int
        let body: Data
    }
    private struct Pending {
        let url: URL
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [UInt64: Pending] = [:]
    private var nextID: UInt64 = 0
    private var reader: Task<Void, Never>?
    private var closed = false

    func start() {
        guard reader == nil else { return }
        reader = Task.detached { [weak self] in
            do {
                for try await line in FileHandle.standardInput.bytes.lines {
                    guard line.utf8.count <= 8192 else { throw URLError(.cannotParseResponse) }
                    let reply = try JSONDecoder().decode(Reply.self, from: Data(line.utf8))
                    guard reply.version == 1, reply.body.count <= 2048 else { throw URLError(.cannotParseResponse) }
                    await self?.receive(reply)
                }
            } catch { }
            await self?.close()
        }
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await data(for: URLRequest(url: url))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        guard !closed, pending.count < 8, let url = request.url,
              url.scheme == "http", url.host == "10.0.2.4", url.port == nil || url.port == 80,
              url.query == nil else { throw URLError(.cannotConnectToHost) }
        nextID &+= 1
        let identifier = nextID
        let message = Request(id: identifier, method: request.httpMethod ?? "GET", path: url.path, body: request.httpBody)
        var encoded = try JSONEncoder().encode(message)
        encoded.append(10)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let timeout = Task.detached { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(2))
                        await self?.fail(identifier, error: URLError(.timedOut))
                    } catch { }
                }
                pending[identifier] = Pending(url: url, continuation: continuation, timeout: timeout)
                do { try FileHandle.standardOutput.write(contentsOf: encoded) }
                catch { fail(identifier, error: error) }
            }
        } onCancel: {
            Task { await self.fail(identifier, error: CancellationError()) }
        }
    }

    private func receive(_ reply: Reply) {
        guard let item = pending.removeValue(forKey: reply.id) else { return }
        item.timeout.cancel()
        guard reply.status != 0,
              let response = HTTPURLResponse(url: item.url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            item.continuation.resume(throwing: URLError(.cannotConnectToHost))
            return
        }
        item.continuation.resume(returning: (reply.body, response))
    }

    private func fail(_ identifier: UInt64, error: Error) {
        guard let item = pending.removeValue(forKey: identifier) else { return }
        item.timeout.cancel()
        item.continuation.resume(throwing: error)
    }

    func close() {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        for identifier in Array(pending.keys) { fail(identifier, error: URLError(.networkConnectionLost)) }
    }
}
