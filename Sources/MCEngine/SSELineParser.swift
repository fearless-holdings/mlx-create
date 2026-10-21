import Foundation

/// Parses one line of the `/v1/images/generations` SSE stream. Event shapes follow upstream `gen_sse.zig`:
/// `{"type":"progress","stage","step","total"}`, `{"type":"complete","data":[{"b64_json"}]}`,
/// and `{"type":"error","error":{"type","message"}}`. Unknown types, including preview frames, are ignored.
enum SSELineParser {
    enum Parsed: Equatable {
        case event(GenEvent)
        case failed(EngineError)
        case ignored
    }

    static func parse(line: String) -> Parsed {
        guard line.hasPrefix("data:") else { return .ignored }
        let payload = line.dropFirst("data:".count).drop(while: { $0 == " " })
        if payload == "[DONE]" { return .ignored }
        guard let data = payload.data(using: .utf8),
            let frame = try? JSONDecoder().decode(Frame.self, from: data)
        else {
            return .failed(.malformedResponse(detail: "unreadable SSE data line"))
        }
        switch frame.type {
        case "progress":
            guard let step = frame.step else {
                return .failed(.malformedResponse(detail: "progress event missing step"))
            }
            return .event(.progress(step: step, total: frame.total ?? 0, stage: frame.stage ?? ""))
        case "complete":
            guard let encoded = frame.data?.first?.b64_json,
                let png = Data(base64Encoded: encoded)
            else {
                return .failed(.malformedResponse(detail: "complete event missing image data"))
            }
            return .event(.completed(png: png))
        case "error":
            return .failed(
                EngineError.fromTyped(
                    type: frame.error?.type,
                    message: frame.error?.message ?? frame.message
                ))
        default:
            return .ignored
        }
    }

    /// Only the fields this client reads. Anything else, including `preview`, is dropped by decoding.
    private struct Frame: Decodable {
        struct Image: Decodable { let b64_json: String? }
        struct Failure: Decodable {
            let type: String?
            let message: String?
        }
        let type: String
        let step: Int?
        let total: Int?
        let stage: String?
        let data: [Image]?
        let error: Failure?
        let message: String?
    }
}
