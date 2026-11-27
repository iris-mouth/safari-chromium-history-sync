import Darwin
import Foundation

struct ViewerReadinessReply: Decodable, Equatable, Sendable {
    let request: UInt64
    let ready: Bool
}

enum ViewerReadinessStream {
    static func consume(_ reader: FileHandle, onReply: @Sendable (ViewerReadinessReply) async -> Void) async {
        defer { try? reader.close() }
        var bytes = [UInt8](repeating: 0, count: 512)
        var buffer = Data()
        while true {
            let count = Darwin.read(reader.fileDescriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let frame = buffer.prefix(upTo: newline)
                guard frame.count <= 512 else { return }
                if let reply = try? JSONDecoder().decode(ViewerReadinessReply.self, from: frame) {
                    await onReply(reply)
                }
                buffer.removeSubrange(...newline)
            }
            guard buffer.count <= 512 else { return }
        }
    }
}
