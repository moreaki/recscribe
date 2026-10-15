import Foundation
import Network
import os
import Testing
@testable import RecScribe

struct DownloadProgressTests {
    /// A real, slow loopback response exercises URLSession's delegate wiring.
    /// Unit tests of the progress calculation alone miss the async API bug.
    private final class Server: @unchecked Sendable {
        static let chunk = Data(repeating: 0x5A, count: 32_768)
        static let chunks = 32
        static let bytes = chunk.count * chunks
        let listener: NWListener
        let queue = DispatchQueue(label: "download-progress-test")
        let connections = OSAllocatedUnfairLock(initialState: [NWConnection]())

        init(knownLength: Bool) throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            let connections = connections, queue = queue
            listener.newConnectionHandler = { connection in
                connections.withLock { $0.append(connection) }
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, error in
                    guard error == nil else { connection.cancel(); return }
                    let length = knownLength ? "Content-Length: \(Self.bytes)\r\n" : ""
                    let headers = Data("HTTP/1.1 200 OK\r\n\(length)Connection: close\r\n\r\n".utf8)
                    connection.send(content: headers, completion: .contentProcessed { error in
                        guard error == nil else { connection.cancel(); return }
                        Self.sendChunk(0, to: connection, on: queue)
                    })
                }
            }
        }

        func start() async throws -> URL {
            let listener = listener
            let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        listener.stateUpdateHandler = nil
                        continuation.resume(returning: listener.port!.rawValue)
                    case .failed(let error):
                        listener.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            return URL(string: "http://127.0.0.1:\(port)/model")!
        }

        private static func sendChunk(_ index: Int, to connection: NWConnection, on queue: DispatchQueue) {
            connection.send(content: chunk, completion: .contentProcessed { error in
                guard error == nil else { connection.cancel(); return }
                if index + 1 == chunks {
                    connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                } else {
                    queue.asyncAfter(deadline: .now() + .milliseconds(30)) {
                        sendChunk(index + 1, to: connection, on: queue)
                    }
                }
            })
        }

        func stop() {
            listener.newConnectionHandler = nil
            listener.cancel()
            connections.withLock { $0.forEach { $0.cancel() }; $0.removeAll() }
        }
    }

    @Test(arguments: [true, false])
    func downloadReportsProgressBeforeCompletion(knownLength: Bool) async throws {
        let server = try Server(knownLength: knownLength)
        defer { server.stop() }
        let url = try await server.start()
        let fractions = OSAllocatedUnfairLock(initialState: [Double]())
        let download = DownloadProgress(expectedBytes: Int64(Server.bytes)) { fraction in
            fractions.withLock { $0.append(fraction) }
        }
        let (file, response) = try await download.download(URLRequest(url: url))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let updates = fractions.withLock { $0 }
        #expect(updates.contains { $0 > 0 && $0 < 1 })
        #expect(updates == updates.sorted())
        #expect(updates.last == 1)
        // The delegate's original temporary file is deleted on callback return.
        #expect(try Data(contentsOf: file) == Data(repeating: 0x5A, count: Server.bytes))
    }

    @Test func cancellationStopsAnActiveDownload() async throws {
        let server = try Server(knownLength: true)
        defer { server.stop() }
        let url = try await server.start()
        let progress = AsyncStream<Void>.makeStream()
        let download = DownloadProgress(expectedBytes: Int64(Server.bytes)) { fraction in
            if fraction > 0 && fraction < 1 { progress.continuation.yield(()) }
        }
        let task = Task { try await download.download(URLRequest(url: url)) }
        defer { task.cancel(); progress.continuation.finish() }
        var iterator = progress.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellationBeforeStartingDoesNotWaitForNetwork() async {
        let download = DownloadProgress(expectedBytes: 100) { _ in Issue.record("Cancelled download reported progress") }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await download.download(URLRequest(url: URL(string: "http://127.0.0.1:1/model")!))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
