import Foundation
import HistoryViewCore

let args = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}
guard let database = option("--database"), let assets = option("--assets"),
      let owner = option("--owner"), let portString = option("--port"), let port = UInt16(portString), port > 0 else {
    FileHandle.standardError.write(Data("Usage: SafariSyncViewer --database PATH --assets PATH --owner TAILSCALE_LOGIN --port PORT\n".utf8))
    exit(64)
}
do {
    let server = try HistoryHTTPServer(reader: HistoryReader(databasePath: database), assets: URL(fileURLWithPath: assets), owner: owner)
    try server.start(port: port)
    if args.contains("--owned-stdin") {
        // Menu holds the write end; EOF also arrives if the Menu crashes.
        DispatchQueue.global(qos: .utility).async {
            _ = FileHandle.standardInput.readData(ofLength: 1)
            exit(0)
        }
    }
    dispatchMain()
} catch {
    FileHandle.standardError.write(Data("SafariSyncViewer: cannot start\n".utf8))
    exit(70)
}
