import Foundation
import SafariSyncCore

let args = CommandLine.arguments
guard args.count == 3 else { exit(64) }
do {
    let collector = try HistoryCollector(databaseURL: URL(fileURLWithPath: args[2]))
    try collector.configure([HistoryCollectionSource(id: "benchmark", browser: .chromium,
        browserType: "Chrome", profileName: "Synthetic", path: args[1])])
    let start = ProcessInfo.processInfo.systemUptime
    try collector.collectAll()
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    let status = try collector.statuses()
    guard status.count == 1, status[0].state == "complete" else { exit(70) }
    print("READY \(elapsed) \(status[0].count)")
    fflush(stdout)
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "benchmark.collection"))
    timer.schedule(deadline: .now() + 30, repeating: 30)
    timer.setEventHandler { @Sendable in try? collector.collectAll() }
    timer.resume()
    dispatchMain()
} catch {
    FileHandle.standardError.write(Data("benchmark collector failed: \(error)\n".utf8))
    exit(70)
}
