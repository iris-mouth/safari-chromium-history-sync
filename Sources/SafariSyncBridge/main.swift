import Foundation
import SafariSyncCore

let environment = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser
let socketPath = environment["SAFARI_SYNC_SOCKET_PATH"] ?? home
    .appendingPathComponent("Library/Application Support/Safari History Sync/agent.sock").path
let ipcSecretURL = URL(fileURLWithPath: environment["SAFARI_SYNC_STATE_DIR"] ?? home
    .appendingPathComponent("Library/Application Support/Safari History Sync").path)
    .appendingPathComponent("ipc.secret")

do {
    let secret = try IPCSecretStore.load(from: ipcSecretURL, createIfMissing: false)
    let client = LocalIPCClient(socketPath: socketPath)
    while true {
        let lengthData = FileHandle.standardInput.readData(ofLength: 4)
        if lengthData.isEmpty { break }
        guard lengthData.count == 4 else { throw IPCError.invalidFrame }
        let length = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        guard length > 0, length <= 1_048_576 else { throw IPCError.invalidFrame }
        let body = FileHandle.standardInput.readData(ofLength: Int(length))
        guard body.count == Int(length) else { throw IPCError.invalidFrame }
        let request = SharedSecret.authenticate(body: body, role: "bridge", secret: secret)
        let framed = try JSONEncoder().encode(request)
        let response = try client.request(framed)
        var responseLength = UInt32(response.count).littleEndian
        FileHandle.standardOutput.write(Data(bytes: &responseLength, count: 4))
        FileHandle.standardOutput.write(response)
    }
} catch {
    let payload = (try? JSONEncoder().encode(TypedError(code: "AGENT_UNAVAILABLE", retryable: true))) ?? Data()
    var responseLength = UInt32(payload.count).littleEndian
    FileHandle.standardOutput.write(Data(bytes: &responseLength, count: 4))
    FileHandle.standardOutput.write(payload)
    exit(70)
}
