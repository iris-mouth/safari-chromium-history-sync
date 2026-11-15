import Foundation

public struct CollectionCandidates: Codable, Sendable {
    public let candidates: [HistoryCollectionSource]
    public let unavailableBrowsers: [String]
}

public enum CollectionProfiles {
    /// Discover profiles in the Agent, which has access to protected browser
    /// folders. Previously selected but unavailable sources remain selectable.
    public static func discover(home: URL, selected: [HistoryCollectionSource]) -> CollectionCandidates {
        var found = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
        var unavailable: [String] = []
        let safari = HistoryCollectionSource(id: "safari:default", browser: .safari, browserType: "Safari", profileName: "Default", path: home.appendingPathComponent("Library/Safari/History.db").path)
        found[safari.id] = safari
        for (id, label, suffix) in [("chrome", "Chrome", "Library/Application Support/Google/Chrome"), ("edge", "Edge", "Library/Application Support/Microsoft Edge")] {
            let root = home.appendingPathComponent(suffix, isDirectory: true)
            var inaccessible = false
            let directories: [String]
            do { directories = try FileManager.default.contentsOfDirectory(atPath: root.path) }
            catch {
                directories = []
                if !isMissing(error) { inaccessible = true }
            }
            let stateData: Data?
            do { stateData = try Data(contentsOf: root.appendingPathComponent("Local State")) }
            catch {
                stateData = nil
                if !isMissing(error) { inaccessible = true }
            }
            let localState = stateData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let cache = ((localState?["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]]) ?? [:]
            let names = Set(directories.filter { $0 == "Default" || $0.hasPrefix("Profile ") }).union(cache.keys)
            for name in names where !name.contains("/") && name != "." && name != ".." {
                let sourceID = "\(id):\(name)"
                let profile = (cache[name]?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
                let history = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("History")
                found[sourceID] = HistoryCollectionSource(id: sourceID, browser: .chromium, browserType: label, profileName: profile, path: history.path)
            }
            if inaccessible { unavailable.append(label) }
        }
        return CollectionCandidates(
            candidates: found.values.sorted { ($0.browserType, $0.profileName, $0.id) < ($1.browserType, $1.profileName, $1.id) },
            unavailableBrowsers: unavailable
        )
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
}
