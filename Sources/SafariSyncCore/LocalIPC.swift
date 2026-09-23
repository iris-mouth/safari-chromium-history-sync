import CryptoKit
import Darwin
import Foundation

public enum IPCError: Error {
    case keyUnavailable(OSStatus)
    case socket(String)
    case invalidFrame
    case authenticationFailed
    case unsafeDirectory
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
            var directoryMetadata = stat()
            let directoryPath = url.deletingLastPathComponent().path
            guard lstat(directoryPath, &directoryMetadata) == 0,
                  (directoryMetadata.st_mode & S_IFMT) == S_IFDIR,
                  directoryMetadata.st_uid == getuid(),
                  chmod(directoryPath, 0o700) == 0 else {
                throw IPCError.unsafeDirectory
            }
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

        guard privateDirectory(at: url.deletingLastPathComponent()) else {
            throw IPCError.unsafeDirectory
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
        configureSocketTimeouts(descriptor: descriptor)
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

public func configureSocketTimeouts(descriptor: Int32, seconds: Int = 2) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    withUnsafePointer(to: &timeout) { pointer in
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
    }
}

private func privateDirectory(at url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0
        && (metadata.st_mode & S_IFMT) == S_IFDIR
        && metadata.st_uid == getuid()
        && (metadata.st_mode & 0o777) == 0o700
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

public func readFrame(
    descriptor: Int32,
    maximum: Int = 1_048_576,
    timeoutSeconds: Int = 2
) throws -> Data {
    let deadline = DispatchTime.now().uptimeNanoseconds
        + UInt64(max(1, timeoutSeconds)) * 1_000_000_000
    var length: UInt32 = 0
    guard readExactly(descriptor, into: &length, count: 4, deadline: deadline) else {
        throw IPCError.invalidFrame
    }
    let size = Int(UInt32(littleEndian: length))
    guard size > 0, size <= maximum else { throw IPCError.invalidFrame }
    var data = Data(count: size)
    let ok = data.withUnsafeMutableBytes { buffer in
        readExactly(descriptor, into: buffer.baseAddress!, count: size, deadline: deadline)
    }
    guard ok else { throw IPCError.invalidFrame }
    return data
}

public func writeFrame(_ data: Data, descriptor: Int32, timeoutSeconds: Int = 2) throws {
    let deadline = DispatchTime.now().uptimeNanoseconds
        + UInt64(max(1, timeoutSeconds)) * 1_000_000_000
    var length = UInt32(data.count).littleEndian
    guard writeExactly(descriptor, from: &length, count: 4, deadline: deadline) else {
        throw IPCError.socket("write")
    }
    let ok = data.withUnsafeBytes { buffer in
        writeExactly(descriptor, from: buffer.baseAddress!, count: data.count, deadline: deadline)
    }
    guard ok else { throw IPCError.socket("write") }
}

private func readExactly(
    _ descriptor: Int32,
    into pointer: UnsafeMutableRawPointer,
    count: Int,
    deadline: UInt64
) -> Bool {
    var offset = 0
    while offset < count {
        guard waitForSocket(descriptor, events: Int16(POLLIN), deadline: deadline) else { return false }
        let amount = Darwin.recv(
            descriptor,
            pointer.advanced(by: offset),
            count - offset,
            Int32(MSG_DONTWAIT)
        )
        if amount < 0, errno == EINTR || errno == EAGAIN { continue }
        if amount <= 0 { return false }
        offset += amount
    }
    return true
}

private func writeExactly(
    _ descriptor: Int32,
    from pointer: UnsafeRawPointer,
    count: Int,
    deadline: UInt64
) -> Bool {
    var offset = 0
    while offset < count {
        guard waitForSocket(descriptor, events: Int16(POLLOUT), deadline: deadline) else { return false }
        let amount = Darwin.send(
            descriptor,
            pointer.advanced(by: offset),
            count - offset,
            Int32(MSG_DONTWAIT | MSG_NOSIGNAL)
        )
        if amount < 0, errno == EINTR || errno == EAGAIN { continue }
        if amount <= 0 { return false }
        offset += amount
    }
    return true
}

private func waitForSocket(_ descriptor: Int32, events: Int16, deadline: UInt64) -> Bool {
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return false }
        let milliseconds = max(1, min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
        var item = pollfd(fd: descriptor, events: events, revents: 0)
        let result = Darwin.poll(&item, 1, Int32(milliseconds))
        if result < 0, errno == EINTR { continue }
        guard result > 0,
              item.revents & (events | Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)) != 0 else {
            return false
        }
        return item.revents & events != 0
    }
}
