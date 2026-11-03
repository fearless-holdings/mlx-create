import Foundation
import Network
import Testing

@testable import MCEngine

/// A real loopback HTTP listener. It reports when a request arrives and when the client closes the socket.
final class ClosureObservingServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "closure-observing-server")
    private let requestStream: AsyncStream<Void>
    private let requestContinuation: AsyncStream<Void>.Continuation
    private let closedStream: AsyncStream<Void>
    private let closedContinuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    nonisolated(unsafe) private var connections: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        (requestStream, requestContinuation) = AsyncStream.makeStream()
        (closedStream, closedContinuation) = AsyncStream.makeStream()
    }

    /// Starts listening and returns the bound port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForRequest() async {
        var iterator = requestStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func waitForClose() async {
        var iterator = closedStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            for connection in connections { connection.cancel() }
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(on: connection)
    }

    /// Reads until the peer closes. The stub never answers, so the client waits on the response headers.
    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                self?.requestContinuation.yield(())
            }
            if isComplete || error != nil {
                self?.closedContinuation.yield(())
                connection.cancel()
                return
            }
            self?.receive(on: connection)
        }
    }
}

@Suite("EngineClient cancellation and timeout")
struct EngineClientCancelTests {
    @Test("cancelling the consumer closes the socket so the engine sees the disconnect")
    func cancelClosesSocket() async throws {
        let server = try ClosureObservingServer()
        let port = try await server.start()
        defer { server.stop() }

        let endpoint = EngineEndpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: "test-key")
        let client = EngineClient(endpoint: { endpoint })

        let consumer = Task {
            for try await _ in client.generateImage(krea2Request) {}
        }

        await server.waitForRequest()
        consumer.cancel()

        let closed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await server.waitForClose()
                return true
            }
            group.addTask {
                // On the suspending clock, so a sleep of the Mac mid-run does not count toward the timeout.
                try? await Task.sleep(for: .seconds(5), clock: .suspending)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(closed, "the engine side never observed the closed connection")
        _ = await consumer.result
    }

    @Test("the byte-silence timeout is 24 hours on the configuration the client uses")
    func byteSilenceTimeout() {
        let configured = EngineClient.makeConfiguration(from: .ephemeral)
        #expect(configured.timeoutIntervalForRequest == 24 * 60 * 60)
        #expect(EngineClient.byteSilenceTimeout == 24 * 60 * 60)
    }
}
