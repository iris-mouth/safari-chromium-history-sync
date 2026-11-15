import SafariSyncCore

struct CollectionReply: Decodable {
    let enabled: Bool
    let sources: [HistoryCollectionSource]
    let statuses: [HistoryCollectionStatus]
}
