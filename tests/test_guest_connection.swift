import Foundation

@main
enum GuestConnectionCheck {
    static func main() async throws {
        let connection = GuestConnection()
        await connection.start()
        let url = URL(string: "http://10.0.2.4/.henge/native-touch-usb")!
        switch CommandLine.arguments[1] {
        case "multiplex":
            var report = URLRequest(url: url.appendingPathComponent("report"))
            report.httpMethod = "PUT"
            report.httpBody = Data((0..<36).map(UInt8.init))
            async let first = connection.data(from: url)
            async let second = connection.data(for: report)
            let (a, b) = try await (first, second)
            precondition(a.0 == Data("metadata".utf8))
            precondition(b.0 == Data("report".utf8))
            precondition((a.1 as? HTTPURLResponse)?.statusCode == 200)
            precondition((b.1 as? HTTPURLResponse)?.statusCode == 204)
        case "cancel":
            let operation = Task { try await connection.data(from: url) }
            try await Task.sleep(for: .milliseconds(200))
            operation.cancel()
            do { _ = try await operation.value; preconditionFailure("cancelled request completed") }
            catch is CancellationError { }
        case "timeout":
            do { _ = try await connection.data(from: url); preconditionFailure("request did not time out") }
            catch let error as URLError { precondition(error.code == .timedOut) }
        case "eof":
            do { _ = try await connection.data(from: url); preconditionFailure("closed connection completed") }
            catch let error as URLError { precondition(error.code == .networkConnectionLost) }
        default: preconditionFailure("unknown test")
        }
        await connection.close()
    }
}
