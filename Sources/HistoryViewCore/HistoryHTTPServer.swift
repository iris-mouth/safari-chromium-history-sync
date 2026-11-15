import Darwin
import Foundation

public enum HistoryHTTPServerError: Error { case listen(Int32) }

/// Loopback-only GET server. Tailscale Serve supplies the required owner header;
/// the server never serves arbitrary files or provides mutation endpoints.
public final class HistoryHTTPServer: @unchecked Sendable {
    private let reader: HistoryReader
    private let assets: URL
    private let owner: String
    private let lock = NSLock()
    private var listener: Int32 = -1
    private let slots = DispatchSemaphore(value: 16)
    public private(set) var port: UInt16 = 0

    public init(reader: HistoryReader, assets: URL, owner: String) throws {
        guard !owner.isEmpty, owner.utf8.count <= 512, !owner.contains("\n"), !owner.contains("\r") else { throw HistoryReaderError.invalid("owner is required") }
        self.reader = reader; self.assets = assets; self.owner = owner
    }
    public func start(port: UInt16) throws {
        try lock.withLock {
            guard listener < 0 else { throw HistoryReaderError.unavailable }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw HistoryReaderError.unavailable }
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard result == 0 else { let code = errno; Darwin.close(fd); throw HistoryHTTPServerError.listen(code) }
            guard listen(fd, 32) == 0 else { let code = errno; Darwin.close(fd); throw HistoryHTTPServerError.listen(code) }
            var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let getResult = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            guard getResult == 0 else { Darwin.close(fd); throw HistoryReaderError.unavailable }
            self.port = UInt16(bigEndian: actual.sin_port); listener = fd
            DispatchQueue.global(qos: .utility).async { [self] in acceptLoop(fd) }
        }
    }
    public func stop() {
        lock.withLock {
            if listener >= 0 { shutdown(listener, SHUT_RDWR); Darwin.close(listener); listener = -1 }
        }
    }
    deinit { stop() }
    private func acceptLoop(_ fd: Int32) {
        while lock.withLock({ listener == fd }) {
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; break }
            if slots.wait(timeout: .now()) != .success { Darwin.close(client); continue }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { Darwin.close(client); slots.signal() }
                serve(client)
            }
        }
    }
    private func serve(_ fd: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0); var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        do {
            let request = try readRequest(fd)
            guard request.headers["tailscale-user-login"] == owner else { throw HTTPError(status: 403, detail: "本人のTailscaleアカウントから接続してください。") }
            let cancellation = HistoryReadCancellation()
            let observer = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
            let observerStopped = DispatchSemaphore(value: 0)
            observer.setCancelHandler { observerStopped.signal() }
            observer.setEventHandler {
                var byte: UInt8 = 0
                let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                if count == 0 || count > 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) { cancellation.cancel() }
            }
            observer.resume()
            defer { observer.cancel(); observerStopped.wait() }
            let response = try route(request.target, cancellation: cancellation)
            if !cancellation.isCancelledForHTTP { sendResponse(fd, response) }
        } catch let e as HTTPError { sendResponse(fd, .error(e.status, e.detail)) }
        catch HistoryReaderError.invalid(let detail) { sendResponse(fd, .error(422, detail)) }
        catch HistoryReaderError.notFound { sendResponse(fd, .error(404, "この履歴は参照できません。")) }
        catch { sendResponse(fd, .error(503, "履歴を読み取れません。")) }
    }
    private struct Request { let target: String; let headers: [String:String] }
    private func readRequest(_ fd: Int32) throws -> Request {
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard ProcessInfo.processInfo.systemUptime <= deadline else { throw HTTPError(status: 400, detail: "リクエストがタイムアウトしました。") }
            let n = recv(fd, &bytes, bytes.count, 0)
            guard n > 0 else { throw HTTPError(status: 400, detail: "不正なリクエストです。") }
            data.append(contentsOf: bytes[0..<n])
            guard data.count <= 32768 else { throw HTTPError(status: 400, detail: "リクエストが大きすぎます。") }
        }
        guard let string = String(data: data, encoding: .utf8), let headerEnd = string.range(of: "\r\n\r\n") else { throw HTTPError(status: 400, detail: "不正なリクエストです。") }
        let lines = string[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        guard let line = lines.first else { throw HTTPError(status: 400, detail: "不正なリクエストです。") }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0", parts[1].hasPrefix("/"), !parts[1].hasPrefix("//") else { throw HTTPError(status: 400, detail: "不正なリクエストです。") }
        var headers: [String:String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPError(status: 400, detail: "不正なヘッダーです。") }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, headers[name] == nil else { throw HTTPError(status: 400, detail: "不正なヘッダーです。") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Request(target: String(parts[1]), headers: headers)
    }
    private func route(_ target: String, cancellation: HistoryReadCancellation) throws -> Response {
        guard var components = URLComponents(string: "http://localhost" + target), components.fragment == nil else { throw HistoryReaderError.invalid("URLが不正です。") }
        // URLSearchParams uses form encoding: an unescaped plus denotes a space.
        if let query = components.percentEncodedQuery { components.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%20") }
        let path = components.path
        var params: [String:String] = [:]
        for item in components.queryItems ?? [] {
            guard params[item.name] == nil else { throw HistoryReaderError.invalid("入力条件が重複しています。") }
            params[item.name] = item.value ?? ""
        }
        if path == "/api/status" { return try jsonResponse(reader.status(cancellation: cancellation)) }
        if path == "/api/records" {
            guard let start = params["start"], let end = params["end"] else { throw HistoryReaderError.invalid("日付が必要です。") }
            let limit: Int
            if let raw = params["limit"] { guard let n = Int(raw) else { throw HistoryReaderError.invalid("件数が不正です。") }; limit = n } else { limit = 200 }
            let idsText = params["ids"] ?? ""
            guard idsText.count <= 20000 else { throw HistoryReaderError.invalid("履歴IDが多すぎます。") }
            let pieces = idsText.isEmpty ? [] : idsText.split(separator: ",", omittingEmptySubsequences: false)
            let ids = pieces.compactMap { Int64($0) }
            guard ids.count == pieces.count else { throw HistoryReaderError.invalid("履歴IDが不正です。") }
            let anchor: Int64?
            if let raw = params["anchor"] { guard let n = Int64(raw) else { throw HistoryReaderError.invalid("履歴IDが不正です。") }; anchor = n } else { anchor = nil }
            return try jsonResponse(reader.page(start: start, end: end, query: params["q"] ?? "", cursor: params["cursor"], limit: limit, ids: ids, anchor: anchor, cancellation: cancellation))
        }
        if path.hasPrefix("/api/records/") {
            guard let id = Int64(path.dropFirst("/api/records/".count)) else { throw HistoryReaderError.invalid("履歴IDが不正です。") }
            return try jsonResponse(reader.detail(id: id, cancellation: cancellation))
        }
        if path == "/" { return try staticFile(assets.appendingPathComponent("index.html"), type: "text/html; charset=utf-8") }
        if path.hasPrefix("/assets/") {
            let name = String(path.dropFirst("/assets/".count))
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains), !name.hasPrefix("."), !name.contains("..") else { throw HTTPError(status: 404, detail: "見つかりません。") }
            let type: String
            if name.hasSuffix(".js") { type = "text/javascript; charset=utf-8" }
            else if name.hasSuffix(".css") { type = "text/css; charset=utf-8" }
            else { throw HTTPError(status: 404, detail: "見つかりません。") }
            let dir = assets.appendingPathComponent("assets", isDirectory: true).resolvingSymlinksInPath()
            let file = dir.appendingPathComponent(name).resolvingSymlinksInPath()
            guard file.deletingLastPathComponent() == dir else { throw HTTPError(status: 404, detail: "見つかりません。") }
            return try staticFile(file, type: type)
        }
        throw HTTPError(status: 404, detail: "見つかりません。")
    }
    private func jsonResponse<T: Encodable>(_ value: T) throws -> Response {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(value)
        guard data.count <= 4_194_304 else { throw HTTPError(status: 503, detail: "応答が大きすぎます。条件を絞ってください。") }
        return .json(data)
    }
    private func staticFile(_ url: URL, type: String) throws -> Response {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
              size.intValue <= 5_000_000, let data = try? Data(contentsOf: url) else { throw HTTPError(status: 404, detail: "見つかりません。") }
        return Response(status: 200, type: type, body: data)
    }
    private struct HTTPError: Error { let status: Int; let detail: String }
    private struct Response {
        let status: Int; let type: String; let body: Data
        static func json(_ data: Data) -> Response { .init(status: 200, type: "application/json; charset=utf-8", body: data) }
        static func error(_ status: Int, _ detail: String) -> Response {
            .init(status: status, type: "application/json; charset=utf-8", body: (try? JSONSerialization.data(withJSONObject: ["detail":detail])) ?? Data())
        }
    }
    private func sendResponse(_ fd: Int32, _ response: Response) {
        let reason = [200:"OK",400:"Bad Request",403:"Forbidden",404:"Not Found",422:"Unprocessable Entity",503:"Service Unavailable"][response.status] ?? "Error"
        let header = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.type)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'\r\n\r\n"
        let data = Data(header.utf8) + response.body
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let n = send(fd, base.advanced(by: offset), buffer.count - offset, 0)
                if n <= 0 { break }; offset += n
            }
        }
    }
}
