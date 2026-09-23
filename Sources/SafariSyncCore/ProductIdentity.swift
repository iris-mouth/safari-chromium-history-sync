import Foundation

public enum ProductIdentity {
    public static let productName = "Safari Chromium History Sync"
    public static let menuBarLabel = "History Sync"
    public static let agentBundleName = "Safari Chromium History Sync Agent.app"
    public static let agentExecutableName = "SafariSyncAgent"
    public static let applicationSupportDirectoryName = "Safari Chromium History Sync"

    public static let mainBundleIdentifier = "io.github.irismouth.safari-chromium-history-sync"
    public static let agentBundleIdentifier = "io.github.irismouth.safari-chromium-history-sync.agent"
    public static let packageIdentifier = "io.github.irismouth.safari-chromium-history-sync.pkg"
    public static let keychainService = "io.github.irismouth.safari-chromium-history-sync.agent-state"
    public static let nativeMessagingHost = "io.github.irismouth.safari_chromium_history_sync"
}

public enum AgentIssueCode {
    public static let runtimeUnsupported = "runtimeUnsupported"
    public static let historyIdentityChanged = "historyIdentityChanged"
    public static let historyAnchorInvalid = "historyAnchorInvalid"
    public static let safariAccessUnavailable = "safariAccessUnavailable"
    public static let keychainUnavailable = "keychainUnavailable"
    public static let stateUnreadable = "stateUnreadable"

    public static func forHistoryError(_ error: SafariHistoryError) -> String {
        switch error {
        case .incompatibleSchema:
            runtimeUnsupported
        case .historyIdentityChanged:
            historyIdentityChanged
        case .historyAnchorInvalid:
            historyAnchorInvalid
        case .databaseUnavailable, .sqlite:
            safariAccessUnavailable
        case .invalidURL:
            "INVALID_MESSAGE"
        }
    }
}

public enum RecoveryCommandPolicy {
    public static let resetSafariCursor = "resetSafariCursor"
    public static let resetAgentState = "resetAgentState"

    public static func allows(
        role: String,
        operation: String,
        runtimeState: String,
        issueCode: String?
    ) -> Bool {
        guard role == "menu", runtimeState == "blocked" else { return false }
        return switch (operation, issueCode) {
        case (resetSafariCursor, AgentIssueCode.historyIdentityChanged),
             (resetSafariCursor, AgentIssueCode.historyAnchorInvalid),
             (resetAgentState, AgentIssueCode.stateUnreadable):
            true
        default:
            false
        }
    }
}
