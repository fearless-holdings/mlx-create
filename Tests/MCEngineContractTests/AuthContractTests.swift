import Darwin
import Foundation
import Testing

@testable import MCEngine

/// R5: `/health` is open, every authenticated route is closed without the key and with a wrong one, and the engine
/// answers on loopback only (`docs/lld/engine-contract.md` §4). `EngineClient` always attaches the key, so these probes
/// are raw requests.
@Suite(.serialized, .enabled(if: ContractEnvironment.enabled))
struct AuthContractTests {
    @Test func theEngineAnswersHealthWithoutAKeyAndEveryOtherRouteOnlyWithIt() async throws {
        try await ContractEngine.run { engine in
            try await runProbe(ContractProbe.authHealthOpen.rawValue, ledger: ContractRun.ledger) { check in
                let response = try await RawHTTP.send("GET", "health", to: engine.endpoint, key: nil)
                check.expect(response.status == 200, "GET /health without a key returned \(response.status)")
                let reported = try statusField(of: response.body)
                check.expect(reported == "ok", "GET /health without a key reported status \(reported ?? "none")")
            }

            try await runProbe(ContractProbe.authMissingKey401.rawValue, ledger: ContractRun.ledger) { check in
                let response = try await RawHTTP.send("GET", "v1/models", to: engine.endpoint, key: nil)
                check.expect(response.status == 401, "GET /v1/models without a key returned \(response.status)")
                let envelope = ContractErrorEnvelope.decode(response.body)
                check.expect(
                    envelope?.error.message?.isEmpty == false,
                    "the 401 body is not the error envelope the app parses: \(response.text)")
                switch EngineError.fromResponse(status: response.status, body: response.body) {
                case .unauthorized(let message):
                    check.expect(
                        message == envelope?.error.message,
                        "the app's unauthorized message is \(message ?? "none"), the envelope carries \(envelope?.error.message ?? "none")")
                case let mapped:
                    check.expect(false, "the app maps a keyless 401 to \(mapped), not .unauthorized")
                }
            }

            try await runProbe(ContractProbe.authWrongKey401.rawValue, ledger: ContractRun.ledger) { check in
                // A key the engine never issued: freshly generated the way the supervisor generates its own.
                let wrongKey = EngineLaunch.makeAPIKey()
                check.expect(wrongKey != engine.endpoint.apiKey, "the probe reused the engine's own key")
                let response = try await RawHTTP.send("GET", "v1/models", to: engine.endpoint, key: wrongKey)
                check.expect(response.status == 401, "GET /v1/models with a wrong key returned \(response.status)")
                switch EngineError.fromResponse(status: response.status, body: response.body) {
                case .unauthorized:
                    break
                case let mapped:
                    check.expect(false, "the app maps a wrong-key 401 to \(mapped), not .unauthorized")
                }
            }

            try await runProbe(ContractProbe.authRightKey200.rawValue, ledger: ContractRun.ledger) { check in
                let response = try await RawHTTP.send("GET", "v1/models", to: engine.endpoint, key: engine.endpoint.apiKey)
                check.expect(response.status == 200, "GET /v1/models with the key returned \(response.status)")
                let models = try? JSONDecoder().decode(ModelList.self, from: response.body)
                check.expect(models != nil, "the 200 body is not a model list: \(response.text.prefix(200))")
                check.expect(models?.data.isEmpty == false, "the engine listed no model")
            }

            try await runProbe(ContractProbe.authLoopbackOnly.rawValue, ledger: ContractRun.ledger) { check in
                guard let port = engine.endpoint.baseURL.port else {
                    throw ContractHarnessError.missing("a port in the engine endpoint")
                }
                let addresses = nonLoopbackIPv4Addresses()
                guard !addresses.isEmpty else {
                    throw ContractHarnessError.missing("a non-loopback IPv4 address on this Mac, so exposure is unobservable")
                }
                for address in addresses.prefix(3) {
                    let failure = connectError(to: address, port: UInt16(truncatingIfNeeded: port), timeout: 2)
                    check.expect(
                        failure != nil,
                        "the engine answered a TCP connection to \(address):\(port), which is not a loopback address")
                }
            }
        }
    }
}

/// `{"error":{"message":…,"type":…}}`, the envelope the app parses (`EngineError`). The app's own reader is private, so
/// this checks the shape of the body itself.
struct ContractErrorEnvelope: Decodable {
    struct Inner: Decodable {
        let message: String?
        let type: String?
    }

    let error: Inner

    static func decode(_ body: Data) -> ContractErrorEnvelope? {
        try? JSONDecoder().decode(ContractErrorEnvelope.self, from: body)
    }
}

/// `{"object":"list","data":[…]}`: the shape `EngineClient.models()` decodes.
private struct ModelList: Decodable {
    let data: [ModelEntry]
}

/// The `status` field of a `/health` body.
private func statusField(of body: Data) throws -> String? {
    let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    return object?["status"] as? String
}

/// The Mac's own non-loopback IPv4 addresses as dotted quads. Link-local (169.254/16) addresses host nothing.
private func nonLoopbackIPv4Addresses() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }
    var addresses: Set<String> = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
        let flags = Int32(bitPattern: entry.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getnameinfo(address, size, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let text = String(cString: host)
        guard !text.isEmpty, text != "0.0.0.0", !text.hasPrefix("169.254.") else { continue }
        addresses.insert(text)
    }
    return addresses.sorted()
}

/// Connects to `address:port` with a short timeout. Nil means the connection was established; otherwise the errno that
/// kept it from being, including `ETIMEDOUT` when nothing answered.
private func connectError(to address: String, port: UInt16, timeout: TimeInterval) -> Int32? {
    var target = sockaddr_in()
    target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    target.sin_family = sa_family_t(AF_INET)
    target.sin_port = port.bigEndian
    guard inet_pton(AF_INET, address, &target.sin_addr) == 1 else { return EINVAL }
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return errno }
    defer { close(descriptor) }
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return errno }

    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let started = withUnsafePointer(to: &target) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, size) }
    }
    if started == 0 { return nil }
    guard errno == EINPROGRESS else { return errno }

    var polled = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    let millis = Int32((timeout * 1000).rounded())
    let ready = poll(&polled, 1, millis)
    if ready == 0 { return ETIMEDOUT }
    guard ready > 0 else { return errno }
    var pending: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &pending, &length) == 0 else { return errno }
    return pending == 0 ? nil : pending
}
