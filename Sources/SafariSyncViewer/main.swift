import Foundation
import HistoryViewCore

let args = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}
guard let database = option("--database"), let assets = option("--assets"),
      let owner = option("--owner") else {
    FileHandle.standardError.write(Data("Usage: SafariSyncViewer --database PATH --assets PATH --owner TAILSCALE_LOGIN --port PORT\n".utf8))
    exit(64)
}
do {
    let server = try HistoryHTTPServer(reader: HistoryReader(databasePath: database), assets: URL(fileURLWithPath: assets), owner: owner)
    if let fd = option("--listen-fd").flatMap(Int32.init), fd >= 3 {
        try server.start(inheritedUnixListener: fd)
    } else if !Bundle.main.bundleURL.path.hasSuffix(".app"), let port = option("--port").flatMap(UInt16.init), port > 0 {
        // Command-line fixture server used by the synthetic browser tests.
        try server.start(port: port)
    } else { exit(64) }
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
