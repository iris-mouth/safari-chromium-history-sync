import CryptoKit
import Darwin
import Foundation

public enum IPCError: Error {
    case keyUnavailable(OSStatus)
    case socket(String)
    case invalidFrame
    case authenticationFailed
}

public struct AuthenticatedRequest: Codable, Sendable {
    public let role: String
    public let nonce: String
    public let body: Data
    public let mac: Data
}

public enum SharedSecret {
    public static func authenticate(body: Data, role: String, secret: Data) -> AuthenticatedRequest {
        let nonce = UUID().uuidString.lowercased()
        let material = Data("\(role)\n\(nonce)\n".utf8) + body
        let mac = Data(HMAC<SHA256>.authenticationCode(for: material, using: SymmetricKey(data: secret)))
        return AuthenticatedRequest(role: role, nonce: nonce, body: body, mac: mac)
    }

    public static func verify(_ request: AuthenticatedRequest, secret: Data) -> Bool {
        let material = Data("\(request.role)\n\(request.nonce)\n".utf8) + request.body
        return HMAC<SHA256>.isValidAuthenticationCode(
            request.mac,
            authenticating: material,
            using: SymmetricKey(data: secret)
        )
    }
}

public enum IPCSecretStore {
    public static func load(from url: URL, createIfMissing: Bool) throws -> Data {
        if createIfMissing {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if descriptor >= 0 {
                let secret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
                defer { Darwin.close(descriptor) }
                let written = secret.withUnsafeBytes { bytes in
                    Darwin.write(descriptor, bytes.baseAddress!, bytes.count)
                }
                guard written == secret.count, fsync(descriptor) == 0 else {
                    unlink(url.path)
                    throw IPCError.socket("write IPC secret")
                }
            } else if errno != EEXIST {
                throw IPCError.socket("create IPC secret")
            }
        }

        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              (metadata.st_mode & 0o777) == 0o600 else {
            throw IPCError.socket("unsafe IPC secret")
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw IPCError.socket("open IPC secret") }
        defer { Darwin.close(descriptor) }
        var secret = Data(count: 32)
        let amount = secret.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress!, bytes.count)
        }
        guard amount == secret.count else { throw IPCError.socket("invalid IPC secret") }
        return secret
    }
}

public struct LocalIPCClient {
    public let socketPath: String
    public init(socketPath: String) { self.socketPath = socketPath }

    public func request(_ payload: Data) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IPCError.socket("socket") }
        defer { Darwin.close(descriptor) }
        var address = try unixAddress(path: socketPath)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw IPCError.socket("connect") }
        try writeFrame(payload, descriptor: descriptor)
        return try readFrame(descriptor: descriptor)
    }
}

public func unixAddress(path: String) throws -> sockaddr_un {
    guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
        throw IPCError.socket("path too long")
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: path.utf8.count + 1) { destination in
            _ = path.withCString { source in
                strncpy(destination, source, path.utf8.count + 1)
            }
        }
    }
    return address
}

public func readFrame(descriptor: Int32, maximum: Int = 1_048_576) throws -> Data {
    var length: UInt32 = 0
    guard readExactly(descriptor, into: &length, count: 4) else { throw IPCError.invalidFrame }
    let size = Int(UInt32(littleEndian: length))
    guard size > 0, size <= maximum else { throw IPCError.invalidFrame }
    var data = Data(count: size)
    let ok = data.withUnsafeMutableBytes { buffer in
        readExactly(descriptor, into: buffer.baseAddress!, count: size)
    }
    guard ok else { throw IPCError.invalidFrame }
    return data
}

public func writeFrame(_ data: Data, descriptor: Int32) throws {
    var length = UInt32(data.count).littleEndian
    guard writeExactly(descriptor, from: &length, count: 4) else { throw IPCError.socket("write") }
    let ok = data.withUnsafeBytes { buffer in
        writeExactly(descriptor, from: buffer.baseAddress!, count: data.count)
    }
    guard ok else { throw IPCError.socket("write") }
}

private func readExactly(_ descriptor: Int32, into pointer: UnsafeMutableRawPointer, count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let amount = Darwin.read(descriptor, pointer.advanced(by: offset), count - offset)
        if amount <= 0 { return false }
        offset += amount
    }
    return true
}

private func writeExactly(_ descriptor: Int32, from pointer: UnsafeRawPointer, count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let amount = Darwin.write(descriptor, pointer.advanced(by: offset), count - offset)
        if amount <= 0 { return false }
        offset += amount
    }
    return true
}
