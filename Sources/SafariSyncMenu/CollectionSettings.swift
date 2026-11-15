import SafariSyncCore

struct CollectionReply: Decodable {
    let extensionUpdateRequired: Bool?
    let enabled: Bool
    let sources: [HistoryCollectionSource]
    let pair: HistoryCollector.Pair?
    let pendingCount: Int64?
    let statuses: [HistoryCollectionStatus]
}
